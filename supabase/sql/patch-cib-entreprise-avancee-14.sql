-- ============================================================
-- patch-cib-entreprise-avancee-14.sql
-- À exécuter après patch-cib-entreprise-avancee-13.sql. Additif et rejouable.
--
-- MARCHÉ PUBLIC + PROGRAMME ALBATROS.
--
-- HYPOTHÈSES / CHOIX (scope énorme, à ajuster) :
--  - Deux codes de Taxe Précise étaient réutilisés pour deux catégories
--    différentes dans le message (TP-TV pour vapoteuses ET automobiles ;
--    TP-TPC pour paris/casinos ET produits compliqués à recycler).
--    Renommés sans collision : vapoteuses = TP-TV, automobiles = TP-AUTO,
--    paris/casinos = TP-PC, produits compliqués à recycler = TP-REC.
--  - Le taux de la taxe d'importation des animaux exotiques (TD-TIAE)
--    n'était pas chiffré : posé à 10 %, à corriger si besoin.
--  - TAP/TAN sont calculées sur la province DU VENDEUR (point de vente),
--    comme un bien vendu "dans" cette province — l'énoncé ne précisait
--    pas de quel côté. Les deux taxes vont dans la trésorerie publique
--    (tresor_public.solde) : il n'existe pas encore de trésorerie par
--    province pour y verser la TAP séparément.
--  - Programme Albatros n'est pas une "entreprise" au sens du site (pas
--    d'employés/capital) : c'est un simple libellé pour la part que
--    touche le gouvernement, créditée directement à tresor_public.solde.
--  - Dans l'exemple donné (100 R$ sur 8 mois), les pourcentages donnés en
--    toutes lettres (17,6 % gouvernement / 2,4 % vendeur) ne correspondent
--    pas aux montants chiffrés dans le MÊME exemple (2,64 R$ = 17,6 % de
--    15 R$, mais 12,36 R$ = 82,4 % de 15 R$, pas 2,4 %). J'ai suivi les
--    montants chiffrés (82,4 % au vendeur) plutôt que le "2,4 %" qui
--    semble être une coquille.
--  - Les taxes (TP/TAP/TAN) sont payées comptant immédiatement, qu'Albatros
--    soit choisi ou non ; seul le PRIX DE L'OBJET est étalé par Albatros.
--  - Le suivi de livraison posé ici reste SIMPLE (vendeur marque expédié,
--    acheteur marque reçu/contesté) : le système complet de bureaux de
--    poste (livreurs, gestionnaires, analystes, distance, affiliation
--    temporaire) n'est PAS construit dans ce patch — c'est un sous-système
--    à part entière, pour un prochain message.
-- ============================================================


-- ============================================================
-- 1) CATÉGORIES DE TAXE PRÉCISE (TP)
-- ============================================================
create table if not exists marche_categories (
  code  text primary key,
  nom   text not null,
  taux  numeric not null
);
insert into marche_categories (code, nom, taux) values
  ('TP-TT', 'Tabac', 25), ('TP-AL', 'Alcool', 15), ('TP-TV', 'Vapoteuses', 20),
  ('TP-PC', 'Paris et casinos', 15), ('TP-TD', 'Drogues', 20), ('TP-AUTO', 'Automobiles', 2),
  ('TP-PCP', 'Produits chimiques et polluants', 15), ('TP-REC', 'Produits compliqués à recycler', 4),
  ('TP-ARM', 'Armes', 10), ('TP-TAC', 'Animaux de compagnie (liste officielle)', 5),
  ('TP-TAE', 'Animaux exotiques (hors liste)', 20), ('TP-AUTRE', 'Autres (TP non applicable)', 0)
on conflict (code) do update set nom = excluded.nom, taux = excluded.taux;
alter table marche_categories enable row level security;
drop policy if exists "Lecture publique des catégories du marché" on marche_categories;
create policy "Lecture publique des catégories du marché" on marche_categories for select using (true);

create or replace function liste_categories_marche()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', code, 'nom', nom, 'taux', taux) order by nom), '[]'::jsonb) from marche_categories;
$$;
grant execute on function liste_categories_marche() to authenticated, anon;


-- ============================================================
-- 2) ANNONCES DU MARCHÉ PUBLIC
-- ============================================================
create table if not exists marche_annonces (
  id                       uuid primary key default gen_random_uuid(),
  vendeur_id               uuid not null references auth.users(id),
  titre                    text not null,
  quantite_totale          int not null check (quantite_totale > 0),
  quantite_disponible      int not null,
  prix_unitaire            numeric not null check (prix_unitaire > 0),
  description              text,
  contact_info             text,
  screenshot_vendeur_chemin text,
  screenshot_objet_chemin   text,
  categorie_tp             text not null references marche_categories(code) default 'TP-AUTRE',
  importe                  boolean not null default false,
  mode_livraison           text not null check (mode_livraison in ('livraison','a_chercher')),
  portee_livraison         text check (portee_livraison in ('internationale','nationale','regionale','districtale','municipale')),
  adresse_recuperation     text,
  livraison_duree_estimee  text,
  livraison_par            text check (livraison_par in ('tiers','bureau_poste')),
  bureau_poste_code_temp   text,
  bureau_poste_code_expire timestamptz,
  livraison_payee_vendeur  boolean not null default false,
  albatros                 boolean not null default false,
  albatros_mois            int check (albatros_mois in (4,8,12,24)),
  province_vente           text not null references provinces_taxation(province),
  statut                   text not null default 'active' check (statut in ('active','retiree')),
  cree_le                  timestamptz not null default now(),
  check (
    (mode_livraison = 'a_chercher' and adresse_recuperation is not null)
    or (mode_livraison = 'livraison' and portee_livraison is not null and livraison_par is not null)
  )
);
alter table marche_annonces enable row level security;
drop policy if exists "Lecture publique des annonces actives, ou siennes" on marche_annonces;
create policy "Lecture publique des annonces actives, ou siennes" on marche_annonces for select
  using (statut = 'active' or vendeur_id = auth.uid() or est_admin_actuel());

create or replace function marche_publier_annonce(p_champs jsonb)
returns marche_annonces language plpgsql security definer set search_path = public as $$
declare v_row marche_annonces; v_qte int;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  v_qte := (p_champs->>'quantite_totale')::int;
  if v_qte is null or v_qte <= 0 then raise exception 'Quantité invalide.'; end if;
  if (p_champs->>'albatros')::boolean and (p_champs->>'albatros_mois')::int not in (4,8,12,24) then
    raise exception 'Durée Albatros invalide (4, 8, 12 ou 24 mois).';
  end if;

  insert into marche_annonces (
    vendeur_id, titre, quantite_totale, quantite_disponible, prix_unitaire, description, contact_info,
    screenshot_vendeur_chemin, screenshot_objet_chemin, categorie_tp, importe, mode_livraison, portee_livraison,
    adresse_recuperation, livraison_duree_estimee, livraison_par, bureau_poste_code_temp, bureau_poste_code_expire,
    livraison_payee_vendeur, albatros, albatros_mois, province_vente
  ) values (
    auth.uid(), p_champs->>'titre', v_qte, v_qte, (p_champs->>'prix_unitaire')::numeric, p_champs->>'description', p_champs->>'contact_info',
    p_champs->>'screenshot_vendeur_chemin', p_champs->>'screenshot_objet_chemin', coalesce(p_champs->>'categorie_tp', 'TP-AUTRE'),
    coalesce((p_champs->>'importe')::boolean, false), p_champs->>'mode_livraison', p_champs->>'portee_livraison',
    p_champs->>'adresse_recuperation', p_champs->>'livraison_duree_estimee', p_champs->>'livraison_par',
    p_champs->>'bureau_poste_code_temp', nullif(p_champs->>'bureau_poste_code_expire','')::timestamptz,
    coalesce((p_champs->>'livraison_payee_vendeur')::boolean, false), coalesce((p_champs->>'albatros')::boolean, false),
    (p_champs->>'albatros_mois')::int, p_champs->>'province_vente'
  ) returning * into v_row;
  return v_row;
end; $$;
grant execute on function marche_publier_annonce(jsonb) to authenticated;

create or replace function marche_retirer_annonce(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update marche_annonces set statut = 'retiree' where id = p_id and vendeur_id = auth.uid();
  if not found then raise exception 'Annonce introuvable.'; end if;
end; $$;
grant execute on function marche_retirer_annonce(uuid) to authenticated;

create or replace function marche_liste_annonces(p_recherche text default null, p_categorie text default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', a.id, 'titre', a.titre, 'prix_unitaire', a.prix_unitaire, 'quantite_disponible', a.quantite_disponible,
    'categorie_tp', a.categorie_tp, 'vendeur', c.username, 'albatros', a.albatros, 'mode_livraison', a.mode_livraison,
    'confiance_vendeur', (citoyen_confiance(a.vendeur_id)->>'score')::numeric
  ) order by a.cree_le desc), '[]'::jsonb)
  from marche_annonces a join citoyens c on c.id = a.vendeur_id
  where a.statut = 'active' and a.quantite_disponible > 0
    and (p_recherche is null or a.titre ilike '%' || p_recherche || '%')
    and (p_categorie is null or a.categorie_tp = p_categorie);
$$;
grant execute on function marche_liste_annonces(text, text) to authenticated, anon;

create or replace function marche_detail_annonce(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a marche_annonces; v_vendeur jsonb;
begin
  select * into a from marche_annonces where id = p_id;
  if a.id is null then raise exception 'Annonce introuvable.'; end if;
  select jsonb_build_object('username', username, 'confiance', citoyen_confiance(a.vendeur_id), 'note', vendeur_note_moyenne(a.vendeur_id))
    into v_vendeur from citoyens where id = a.vendeur_id;
  return to_jsonb(a) || jsonb_build_object('vendeur_info', v_vendeur);
end; $$;
grant execute on function marche_detail_annonce(uuid) to authenticated, anon;


-- ============================================================
-- 3) ACHAT + FACTURE (TP / TAP / TAN) + PROGRAMME ALBATROS
-- ============================================================
create table if not exists marche_achats (
  id                 uuid primary key default gen_random_uuid(),
  annonce_id         uuid not null references marche_annonces(id),
  acheteur_id        uuid not null references auth.users(id),
  vendeur_id         uuid not null references auth.users(id),
  titre              text not null,
  quantite           int not null,
  prix_unitaire      numeric not null,
  montant_objet      numeric not null,
  taxe_tp            numeric not null default 0,
  taxe_tap           numeric not null default 0,
  taxe_tan           numeric not null default 0,
  montant_total      numeric not null,
  mode_paiement      text not null check (mode_paiement in ('comptant','albatros')),
  statut_livraison   text not null default 'en_preparation' check (statut_livraison in ('en_preparation','expedie','recu','conteste')),
  contestation_motif text,
  note_rapidite      numeric, note_aide numeric, note_gentillesse numeric,
  cree_le            timestamptz not null default now()
);
alter table marche_achats enable row level security;
drop policy if exists "Voir ses achats (acheteur ou vendeur) ou tout si admin" on marche_achats;
create policy "Voir ses achats (acheteur ou vendeur) ou tout si admin" on marche_achats for select
  using (acheteur_id = auth.uid() or vendeur_id = auth.uid() or est_admin_actuel());

create table if not exists albatros_factures (
  id              uuid primary key default gen_random_uuid(),
  achat_id        uuid not null references marche_achats(id) on delete cascade,
  mois_total      int not null,
  montant_mensuel numeric not null,
  mois_payes      int not null default 0,
  prochain_du     timestamptz not null default now(),
  statut          text not null default 'active' check (statut in ('active','complete')),
  cree_le         timestamptz not null default now()
);
alter table albatros_factures enable row level security;
drop policy if exists "Voir ses factures Albatros (acheteur ou vendeur)" on albatros_factures;
create policy "Voir ses factures Albatros (acheteur ou vendeur)" on albatros_factures for select
  using (exists (select 1 from marche_achats m where m.id = albatros_factures.achat_id and (m.acheteur_id = auth.uid() or m.vendeur_id = auth.uid())) or est_admin_actuel());

create or replace function marche_acheter(p_annonce_id uuid, p_quantite int, p_mode_paiement text)
returns marche_achats language plpgsql security definer set search_path = public as $$
declare a marche_annonces; v_cat marche_categories; v_montant_objet numeric; v_taxe_tp numeric; v_taxe_tap numeric;
  v_taxe_tan numeric; v_montant_taxes numeric; v_montant_objet_majore numeric; v_total_du_maintenant numeric;
  v_dispo numeric; v_row marche_achats; v_tan numeric;
begin
  if p_mode_paiement not in ('comptant','albatros') then raise exception 'Mode de paiement invalide.'; end if;
  select * into a from marche_annonces where id = p_annonce_id and statut = 'active' for update;
  if a.id is null then raise exception 'Annonce introuvable ou retirée.'; end if;
  if p_quantite <= 0 or p_quantite > a.quantite_disponible then raise exception 'Quantité indisponible (reste : %).', a.quantite_disponible; end if;
  if a.vendeur_id = auth.uid() then raise exception 'Impossible d''acheter sa propre annonce.'; end if;
  if p_mode_paiement = 'albatros' and not a.albatros then raise exception 'Le paiement Albatros n''est pas proposé pour cette annonce.'; end if;

  select * into v_cat from marche_categories where code = a.categorie_tp;
  v_montant_objet := a.prix_unitaire * p_quantite;
  v_taxe_tp := round(v_montant_objet * v_cat.taux / 100.0, 2);
  if a.categorie_tp = 'TP-TAE' and a.importe then v_taxe_tp := v_taxe_tp + round(v_montant_objet * 0.10, 2); end if;

  if v_cat.taux > 0 then
    v_taxe_tap := 0; v_taxe_tan := 0;
  else
    select taux_tap into v_taxe_tap from provinces_taxation where province = a.province_vente;
    v_taxe_tap := round(v_montant_objet * v_taxe_tap / 100.0, 2);
    v_tan := taux_tan_province(a.province_vente);
    v_taxe_tan := round(v_montant_objet * v_tan / 100.0, 2);
  end if;
  v_montant_taxes := v_taxe_tp + v_taxe_tap + v_taxe_tan;

  v_dispo := _ma_tresorerie();

  if p_mode_paiement = 'albatros' then
    v_montant_objet_majore := round(v_montant_objet * 1.20, 2);
    v_total_du_maintenant := v_montant_taxes; -- les taxes sont payées comptant, l'objet est étalé
    if v_dispo < v_total_du_maintenant then raise exception 'Trésorerie insuffisante pour les taxes (% R$).', v_total_du_maintenant; end if;
    perform _debiter_ma_tresorerie(v_total_du_maintenant);
    update tresor_public set solde = solde + v_montant_taxes where id = 1;

    insert into marche_achats (annonce_id, acheteur_id, vendeur_id, titre, quantite, prix_unitaire, montant_objet,
      taxe_tp, taxe_tap, taxe_tan, montant_total, mode_paiement)
    values (p_annonce_id, auth.uid(), a.vendeur_id, a.titre, p_quantite, a.prix_unitaire, v_montant_objet,
      v_taxe_tp, v_taxe_tap, v_taxe_tan, v_montant_objet_majore + v_montant_taxes, 'albatros')
    returning * into v_row;

    insert into albatros_factures (achat_id, mois_total, montant_mensuel)
      values (v_row.id, a.albatros_mois, round(v_montant_objet_majore / a.albatros_mois, 2));
  else
    v_total_du_maintenant := v_montant_objet + v_montant_taxes;
    if v_dispo < v_total_du_maintenant then raise exception 'Trésorerie insuffisante (total : % R$).', v_total_du_maintenant; end if;
    perform _debiter_ma_tresorerie(v_total_du_maintenant);
    update citoyens set tresorerie = tresorerie + v_montant_objet where id = a.vendeur_id;
    update tresor_public set solde = solde + v_montant_taxes where id = 1;

    insert into marche_achats (annonce_id, acheteur_id, vendeur_id, titre, quantite, prix_unitaire, montant_objet,
      taxe_tp, taxe_tap, taxe_tan, montant_total, mode_paiement)
    values (p_annonce_id, auth.uid(), a.vendeur_id, a.titre, p_quantite, a.prix_unitaire, v_montant_objet,
      v_taxe_tp, v_taxe_tap, v_taxe_tan, v_total_du_maintenant, 'comptant')
    returning * into v_row;
  end if;

  update marche_annonces set quantite_disponible = quantite_disponible - p_quantite where id = p_annonce_id;
  return v_row;
end; $$;
grant execute on function marche_acheter(uuid, int, text) to authenticated;

-- Versement mensuel Albatros : 17,6 % au gouvernement, 82,4 % au vendeur
-- (voir HYPOTHÈSE en tête de fichier sur l'écart avec le texte "2,4 %").
create or replace function payer_versement_albatros(p_facture_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare f albatros_factures; m marche_achats; v_dispo numeric; v_part_gouv numeric; v_part_vendeur numeric;
begin
  select * into f from albatros_factures where id = p_facture_id and statut = 'active' for update;
  if f.id is null then raise exception 'Facture introuvable ou déjà complétée.'; end if;
  select * into m from marche_achats where id = f.achat_id;
  if m.acheteur_id <> auth.uid() then raise exception 'Réservé à l''acheteur.'; end if;
  if f.prochain_du > now() then raise exception 'Le prochain versement n''est pas encore dû (le %).', f.prochain_du; end if;

  v_dispo := _ma_tresorerie();
  if v_dispo < f.montant_mensuel then raise exception 'Trésorerie insuffisante (%  R$ requis).', f.montant_mensuel; end if;
  perform _debiter_ma_tresorerie(f.montant_mensuel);

  v_part_gouv := round(f.montant_mensuel * 0.176, 2);
  v_part_vendeur := f.montant_mensuel - v_part_gouv;
  update tresor_public set solde = solde + v_part_gouv where id = 1;
  update citoyens set tresorerie = tresorerie + v_part_vendeur where id = m.vendeur_id;

  update albatros_factures set mois_payes = mois_payes + 1,
    prochain_du = prochain_du + interval '1 month',
    statut = case when mois_payes + 1 >= mois_total then 'complete' else 'active' end
    where id = p_facture_id;
end; $$;
grant execute on function payer_versement_albatros(uuid) to authenticated;

create or replace function mes_achats_marche()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id, 'titre', m.titre, 'quantite', m.quantite, 'montant_total', m.montant_total, 'mode_paiement', m.mode_paiement,
    'statut_livraison', m.statut_livraison, 'vendeur', c.username, 'cree_le', m.cree_le,
    'facture_albatros', (select jsonb_build_object('mois_total', mois_total, 'montant_mensuel', montant_mensuel, 'mois_payes', mois_payes, 'prochain_du', prochain_du, 'statut', statut, 'id', id)
      from albatros_factures where achat_id = m.id)
  ) order by m.cree_le desc), '[]'::jsonb)
  from marche_achats m join citoyens c on c.id = m.vendeur_id where m.acheteur_id = auth.uid();
$$;
grant execute on function mes_achats_marche() to authenticated;

create or replace function mes_ventes_marche()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id, 'titre', m.titre, 'quantite', m.quantite, 'montant_total', m.montant_total, 'mode_paiement', m.mode_paiement,
    'statut_livraison', m.statut_livraison, 'acheteur', c.username, 'cree_le', m.cree_le
  ) order by m.cree_le desc), '[]'::jsonb)
  from marche_achats m join citoyens c on c.id = m.acheteur_id where m.vendeur_id = auth.uid();
$$;
grant execute on function mes_ventes_marche() to authenticated;


-- ============================================================
-- 4) SUIVI DE LIVRAISON SIMPLE + ÉVALUATION DU VENDEUR
-- ============================================================
create or replace function marche_marquer_expedie(p_achat_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update marche_achats set statut_livraison = 'expedie' where id = p_achat_id and vendeur_id = auth.uid() and statut_livraison = 'en_preparation';
  if not found then raise exception 'Achat introuvable ou déjà expédié.'; end if;
end; $$;
grant execute on function marche_marquer_expedie(uuid) to authenticated;

create or replace function marche_marquer_recu(p_achat_id uuid, p_rapidite numeric, p_aide numeric, p_gentillesse numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_rapidite not in (0.5,1,1.5,2,2.5,3,3.5,4,4.5,5) or p_aide not in (0.5,1,1.5,2,2.5,3,3.5,4,4.5,5) or p_gentillesse not in (0.5,1,1.5,2,2.5,3,3.5,4,4.5,5) then
    raise exception 'Notes invalides (0,5 à 5 par demi-étoile).';
  end if;
  update marche_achats set statut_livraison = 'recu', note_rapidite = p_rapidite, note_aide = p_aide, note_gentillesse = p_gentillesse
    where id = p_achat_id and acheteur_id = auth.uid() and statut_livraison in ('en_preparation','expedie');
  if not found then raise exception 'Achat introuvable ou déjà traité.'; end if;
end; $$;
grant execute on function marche_marquer_recu(uuid, numeric, numeric, numeric) to authenticated;

create or replace function marche_contester_achat(p_achat_id uuid, p_motif text, p_preuve_chemin text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_motif is null or char_length(trim(p_motif)) < 10 then raise exception 'Justification requise (10 caractères minimum).'; end if;
  update marche_achats set statut_livraison = 'conteste', contestation_motif = trim(p_motif)
    where id = p_achat_id and acheteur_id = auth.uid() and statut_livraison in ('en_preparation','expedie');
  if not found then raise exception 'Achat introuvable ou déjà traité.'; end if;
end; $$;
grant execute on function marche_contester_achat(uuid, text, text) to authenticated;

-- Note finale du vendeur : aide 45 %, gentillesse 35 %, rapidité 20 %.
create or replace function vendeur_note_moyenne(p_vendeur_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when count(*) = 0 then jsonb_build_object('note', null, 'nb_avis', 0) else jsonb_build_object(
    'note', round(avg(note_aide) * 0.45 + avg(note_gentillesse) * 0.35 + avg(note_rapidite) * 0.20, 2),
    'nb_avis', count(*)
  ) end
  from marche_achats where vendeur_id = p_vendeur_id and note_aide is not null;
$$;
grant execute on function vendeur_note_moyenne(uuid) to authenticated, anon;

-- Ajoute la note du vendeur comme terme du pourcentage de confiance.
create or replace function citoyen_confiance(p_citoyen_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c citoyens; v_jours numeric; v_anciennete numeric; v_dette_pen numeric; v_constats int;
  v_constats_pen numeric; v_formations int; v_formations_bonus numeric; v_recompenses int;
  v_recompenses_bonus numeric; v_signalements int; v_signalements_pen numeric; v_score numeric;
  v_note jsonb; v_note_bonus numeric := 0;
begin
  select * into c from citoyens where id = p_citoyen_id;
  if c.id is null then raise exception 'Citoyen introuvable.'; end if;

  v_jours := extract(epoch from (now() - c.cree_le)) / 86400.0;
  v_anciennete := least(v_jours * 0.1, 30);
  v_dette_pen := least(coalesce(c.dettes, 0) / 1000.0 * 2, 25);

  select count(*) into v_constats from constats_infraction where destinataire_id = p_citoyen_id and coalesce(paye, false) = false;
  v_constats_pen := v_constats * 3;

  select count(*) into v_formations from aft_attributions where citoyen_id = p_citoyen_id;
  v_formations_bonus := least(v_formations * 1, 10);

  select count(*) into v_recompenses from recompenses_attributions where citoyen_id = p_citoyen_id;
  v_recompenses_bonus := least(v_recompenses * 1, 10);

  select count(*) into v_signalements from signalements_finance where cible_id = p_citoyen_id and statut <> 'rejete';
  v_signalements_pen := v_signalements * 5;

  v_note := vendeur_note_moyenne(p_citoyen_id);
  if (v_note->>'note') is not null then v_note_bonus := ((v_note->>'note')::numeric - 3) * 2; end if;

  v_score := greatest(0, least(100, 50 + v_anciennete - v_dette_pen - v_constats_pen + v_formations_bonus + v_recompenses_bonus - v_signalements_pen + v_note_bonus));

  return jsonb_build_object(
    'score', round(v_score, 2),
    'termes', jsonb_build_object(
      'base', 50, 'jours_compte', round(v_jours), 'anciennete', round(v_anciennete, 2),
      'dettes', c.dettes, 'penalite_dettes', round(v_dette_pen, 2),
      'constats_impayes', v_constats, 'penalite_constats', round(v_constats_pen, 2),
      'formations', v_formations, 'bonus_formations', round(v_formations_bonus, 2),
      'recompenses', v_recompenses, 'bonus_recompenses', round(v_recompenses_bonus, 2),
      'signalements', v_signalements, 'penalite_signalements', round(v_signalements_pen, 2),
      'note_vendeur', v_note->>'note', 'effet_note_vendeur', round(v_note_bonus, 2)
    )
  );
end; $$;
grant execute on function citoyen_confiance(uuid) to authenticated;

-- ============================================================
-- FIN
-- ============================================================
