-- ============================================================
-- patch-cib-entreprise-avancee-15.sql
-- À exécuter après patch-cib-entreprise-avancee-14.sql. Additif et rejouable.
-- ============================================================


-- ============================================================
-- 1) CORRECTIF : suppression d'entreprise (violation de clé étrangère)
-- ============================================================
alter table entreprises_membres drop constraint if exists entreprises_membres_entreprise_id_fkey;
alter table entreprises_membres add constraint entreprises_membres_entreprise_id_fkey
  foreign key (entreprise_id) references entreprises(id) on delete cascade;

alter table entreprises_roles drop constraint if exists entreprises_roles_entreprise_id_fkey;
alter table entreprises_roles add constraint entreprises_roles_entreprise_id_fkey
  foreign key (entreprise_id) references entreprises(id) on delete cascade;

alter table entreprises_membres_heures drop constraint if exists entreprises_membres_heures_entreprise_id_fkey;
alter table entreprises_membres_heures add constraint entreprises_membres_heures_entreprise_id_fkey
  foreign key (entreprise_id) references entreprises(id) on delete cascade;

alter table entreprises_membres_cib drop constraint if exists entreprises_membres_cib_entreprise_id_fkey;
alter table entreprises_membres_cib add constraint entreprises_membres_cib_entreprise_id_fkey
  foreign key (entreprise_id) references entreprises(id) on delete cascade;

alter table entreprises_logs drop constraint if exists entreprises_logs_entreprise_id_fkey;
alter table entreprises_logs add constraint entreprises_logs_entreprise_id_fkey
  foreign key (entreprise_id) references entreprises(id) on delete cascade;

alter table entreprises_depots_impots drop constraint if exists entreprises_depots_impots_entreprise_id_fkey;
alter table entreprises_depots_impots add constraint entreprises_depots_impots_entreprise_id_fkey
  foreign key (entreprise_id) references entreprises(id) on delete cascade;

alter table entreprises_cib drop constraint if exists entreprises_cib_entreprise_id_fkey;
alter table entreprises_cib add constraint entreprises_cib_entreprise_id_fkey
  foreign key (entreprise_id) references entreprises(id) on delete cascade;

alter table entreprises_capital_detenteurs drop constraint if exists entreprises_capital_detenteurs_entreprise_id_fkey;
alter table entreprises_capital_detenteurs add constraint entreprises_capital_detenteurs_entreprise_id_fkey
  foreign key (entreprise_id) references entreprises(id) on delete cascade;

alter table capital_offres_tiers drop constraint if exists capital_offres_tiers_entreprise_id_fkey;
alter table capital_offres_tiers add constraint capital_offres_tiers_entreprise_id_fkey
  foreign key (entreprise_id) references entreprises(id) on delete cascade;

alter table entreprises_emprunts_gouv drop constraint if exists entreprises_emprunts_gouv_entreprise_id_fkey;
alter table entreprises_emprunts_gouv add constraint entreprises_emprunts_gouv_entreprise_id_fkey
  foreign key (entreprise_id) references entreprises(id) on delete cascade;

alter table capital_offres_gouvernement drop constraint if exists capital_offres_gouvernement_entreprise_id_fkey;
alter table capital_offres_gouvernement add constraint capital_offres_gouvernement_entreprise_id_fkey
  foreign key (entreprise_id) references entreprises(id) on delete cascade;

-- Bloque la suppression s'il reste des dettes ou des heures impayées, comme demandé.
create or replace function entreprise_supprimer(p_entreprise_id uuid, p_nom text, p_mdp text)
returns void language plpgsql security definer set search_path = public as $$
declare v_role text; v_nom_reel text; v_e entreprises;
begin
  select role into v_role from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_role is distinct from 'pdg' then raise exception 'Réservé au PDG.'; end if;
  select * into v_e from entreprises where id = p_entreprise_id;
  if v_e.id is null then raise exception 'Entreprise introuvable.'; end if;
  if lower(trim(p_nom)) <> lower(v_e.nom) then raise exception 'Le nom de l''entreprise ne correspond pas.'; end if;
  if not _verifier_mdp(p_mdp) then raise exception 'Mot de passe incorrect.'; end if;

  if coalesce(v_e.dette_salariale_gouv, 0) > 0 or coalesce(v_e.dette_salariale_employes, 0) > 0 then
    raise exception 'Impossible : il reste des dettes salariales (gouvernement : % R$, employés : % R$).', v_e.dette_salariale_gouv, v_e.dette_salariale_employes;
  end if;
  if exists (select 1 from entreprises_membres_heures where entreprise_id = p_entreprise_id and heures > 0) then
    raise exception 'Impossible : il reste des heures accumulées impayées.';
  end if;
  if exists (select 1 from entreprises_emprunts_gouv where entreprise_id = p_entreprise_id and statut = 'acceptee') then
    raise exception 'Impossible : il reste un emprunt gouvernemental actif à rembourser.';
  end if;

  delete from entreprises where id = p_entreprise_id;
end; $$;
grant execute on function entreprise_supprimer(uuid, text, text) to authenticated;


-- ============================================================
-- 2) FAMILLES AUTOCHTONES + TAXE DES RÉCOLTES (TR, 4,95 %)
-- ============================================================
alter table citoyens add column if not exists autochtone boolean not null default false;
alter table citoyens add column if not exists autochtone_famille text;

-- Normalise "Union de X" / "Union d'X" -> "X" pour comparer avec les listes courtes.
create or replace function _province_courte(p_province text)
returns text language sql immutable as $$
  select trim(regexp_replace(coalesce(p_province, ''), '^Union (de|d'') ', '', 'i'));
$$;

create or replace function s_enregistrer_autochtone(p_nom_famille text)
returns void language plpgsql security definer set search_path = public as $$
declare v_province text;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  select province_residence into v_province from citoyens where id = auth.uid();
  if _province_courte(v_province) not in ('Tonawa','Bushard Bay','Pruxe','Milela','Gibaltage') then
    raise exception 'Seuls les citoyens résidant à Tonawa, Bushard Bay, Pruxe, Milela ou Gibaltage peuvent s''enregistrer.';
  end if;
  if p_nom_famille is null or char_length(trim(p_nom_famille)) = 0 then raise exception 'Nom de famille requis.'; end if;
  update citoyens set autochtone = true, autochtone_famille = trim(p_nom_famille) where id = auth.uid();
end; $$;
grant execute on function s_enregistrer_autochtone(text) to authenticated;

create or replace function mon_statut_autochtone()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('autochtone', autochtone, 'famille', autochtone_famille) from citoyens where id = auth.uid();
$$;
grant execute on function mon_statut_autochtone() to authenticated;

-- Ajout de la Taxe des Récoltes (4,95 %) dans le calcul du marché public, à la trésorerie PRIVÉE du gouvernement.
alter table marche_achats add column if not exists taxe_tr numeric not null default 0;

create or replace function marche_acheter(p_annonce_id uuid, p_quantite int, p_mode_paiement text)
returns marche_achats language plpgsql security definer set search_path = public as $$
declare a marche_annonces; v_cat marche_categories; v_montant_objet numeric; v_taxe_tp numeric; v_taxe_tap numeric;
  v_taxe_tan numeric; v_taxe_tr numeric; v_montant_taxes numeric; v_montant_objet_majore numeric; v_total_du_maintenant numeric;
  v_dispo numeric; v_row marche_achats; v_tan numeric; v_autochtone boolean; v_vendeur_tresorerie_id uuid;
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

  select autochtone into v_autochtone from citoyens where id = auth.uid();
  v_taxe_tr := case when v_autochtone then round(v_montant_objet * 0.0495, 2) else 0 end;

  v_montant_taxes := v_taxe_tp + v_taxe_tap + v_taxe_tan + v_taxe_tr;
  v_dispo := _ma_tresorerie();
  v_vendeur_tresorerie_id := coalesce(a.entreprise_vendeuse_id, a.vendeur_id); -- voir section 5 pour entreprise_vendeuse_id

  if p_mode_paiement = 'albatros' then
    v_montant_objet_majore := round(v_montant_objet * 1.20, 2);
    v_total_du_maintenant := v_montant_taxes;
    if v_dispo < v_total_du_maintenant then raise exception 'Trésorerie insuffisante pour les taxes (% R$).', v_total_du_maintenant; end if;
    perform _debiter_ma_tresorerie(v_total_du_maintenant);
    update tresor_public set solde = solde + v_taxe_tp + v_taxe_tap + v_taxe_tan, solde_prive = solde_prive + v_taxe_tr where id = 1;

    insert into marche_achats (annonce_id, acheteur_id, vendeur_id, titre, quantite, prix_unitaire, montant_objet,
      taxe_tp, taxe_tap, taxe_tan, taxe_tr, montant_total, mode_paiement)
    values (p_annonce_id, auth.uid(), a.vendeur_id, a.titre, p_quantite, a.prix_unitaire, v_montant_objet,
      v_taxe_tp, v_taxe_tap, v_taxe_tan, v_taxe_tr, v_montant_objet_majore + v_montant_taxes, 'albatros')
    returning * into v_row;

    insert into albatros_factures (achat_id, mois_total, montant_mensuel)
      values (v_row.id, a.albatros_mois, round(v_montant_objet_majore / a.albatros_mois, 2));
  else
    v_total_du_maintenant := v_montant_objet + v_montant_taxes;
    if v_dispo < v_total_du_maintenant then raise exception 'Trésorerie insuffisante (total : % R$).', v_total_du_maintenant; end if;
    perform _debiter_ma_tresorerie(v_total_du_maintenant);
    if a.entreprise_vendeuse_id is not null then
      update entreprises set tresorerie = tresorerie + v_montant_objet where id = a.entreprise_vendeuse_id;
    else
      update citoyens set tresorerie = tresorerie + v_montant_objet where id = a.vendeur_id;
    end if;
    update tresor_public set solde = solde + v_taxe_tp + v_taxe_tap + v_taxe_tan, solde_prive = solde_prive + v_taxe_tr where id = 1;

    insert into marche_achats (annonce_id, acheteur_id, vendeur_id, titre, quantite, prix_unitaire, montant_objet,
      taxe_tp, taxe_tap, taxe_tan, taxe_tr, montant_total, mode_paiement)
    values (p_annonce_id, auth.uid(), a.vendeur_id, a.titre, p_quantite, a.prix_unitaire, v_montant_objet,
      v_taxe_tp, v_taxe_tap, v_taxe_tan, v_taxe_tr, v_total_du_maintenant, 'comptant')
    returning * into v_row;
  end if;

  update marche_annonces set quantite_disponible = quantite_disponible - p_quantite where id = p_annonce_id;
  return v_row;
end; $$;
grant execute on function marche_acheter(uuid, int, text) to authenticated;


-- ============================================================
-- 3) NOTES MODIFIABLES (vendeur) + CONFIANCE : constat contesté-accepté compte quand même
-- ============================================================
create or replace function marche_modifier_evaluation(p_achat_id uuid, p_rapidite numeric, p_aide numeric, p_gentillesse numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_rapidite not in (0.5,1,1.5,2,2.5,3,3.5,4,4.5,5) or p_aide not in (0.5,1,1.5,2,2.5,3,3.5,4,4.5,5) or p_gentillesse not in (0.5,1,1.5,2,2.5,3,3.5,4,4.5,5) then
    raise exception 'Notes invalides (0,5 à 5 par demi-étoile).';
  end if;
  update marche_achats set note_rapidite = p_rapidite, note_aide = p_aide, note_gentillesse = p_gentillesse
    where id = p_achat_id and acheteur_id = auth.uid() and statut_livraison = 'recu';
  if not found then raise exception 'Achat introuvable ou pas encore marqué reçu.'; end if;
end; $$;
grant execute on function marche_modifier_evaluation(uuid, numeric, numeric, numeric) to authenticated;

-- Un constat annulé par contestation acceptée ne compte plus comme "impayé", mais
-- coûte quand même un peu de confiance (avoir été visé par un constat, même annulé après coup).
create or replace function citoyen_confiance(p_citoyen_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c citoyens; v_jours numeric; v_anciennete numeric; v_dette_pen numeric; v_constats int;
  v_constats_pen numeric; v_constats_annules int; v_constats_annules_pen numeric; v_formations int; v_formations_bonus numeric; v_recompenses int;
  v_recompenses_bonus numeric; v_signalements int; v_signalements_pen numeric; v_score numeric;
  v_note jsonb; v_note_bonus numeric := 0;
begin
  select * into c from citoyens where id = p_citoyen_id;
  if c.id is null then raise exception 'Citoyen introuvable.'; end if;

  v_jours := extract(epoch from (now() - c.cree_le)) / 86400.0;
  v_anciennete := least(v_jours * 0.1, 30);
  v_dette_pen := least(coalesce(c.dettes, 0) / 1000.0 * 2, 25);

  select count(*) into v_constats from constats_infraction where destinataire_id = p_citoyen_id and coalesce(paye, false) = false and coalesce(annule, false) = false;
  v_constats_pen := v_constats * 3;
  select count(*) into v_constats_annules from constats_infraction where destinataire_id = p_citoyen_id and coalesce(annule, false) = true;
  v_constats_annules_pen := v_constats_annules * 1;

  select count(*) into v_formations from aft_attributions where citoyen_id = p_citoyen_id;
  v_formations_bonus := least(v_formations * 1, 10);

  select count(*) into v_recompenses from recompenses_attributions where citoyen_id = p_citoyen_id;
  v_recompenses_bonus := least(v_recompenses * 1, 10);

  select count(*) into v_signalements from signalements_finance where cible_id = p_citoyen_id and statut <> 'rejete';
  v_signalements_pen := v_signalements * 5;

  v_note := vendeur_note_moyenne(p_citoyen_id);
  if (v_note->>'note') is not null then v_note_bonus := ((v_note->>'note')::numeric - 3) * 2; end if;

  v_score := greatest(0, least(100, 50 + v_anciennete - v_dette_pen - v_constats_pen - v_constats_annules_pen + v_formations_bonus + v_recompenses_bonus - v_signalements_pen + v_note_bonus));

  return jsonb_build_object(
    'score', round(v_score, 2),
    'termes', jsonb_build_object(
      'base', 50, 'jours_compte', round(v_jours), 'anciennete', round(v_anciennete, 2),
      'dettes', c.dettes, 'penalite_dettes', round(v_dette_pen, 2),
      'constats_impayes', v_constats, 'penalite_constats', round(v_constats_pen, 2),
      'constats_annules', v_constats_annules, 'penalite_constats_annules', round(v_constats_annules_pen, 2),
      'formations', v_formations, 'bonus_formations', round(v_formations_bonus, 2),
      'recompenses', v_recompenses, 'bonus_recompenses', round(v_recompenses_bonus, 2),
      'signalements', v_signalements, 'penalite_signalements', round(v_signalements_pen, 2),
      'note_vendeur', v_note->>'note', 'effet_note_vendeur', round(v_note_bonus, 2)
    )
  );
end; $$;
grant execute on function citoyen_confiance(uuid) to authenticated;


-- ============================================================
-- 4) BANQUES : dissociation d'une banque publique, 1 seule à la fois
-- ============================================================
create or replace function banque_quitter_publique(p_banque_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_solde numeric;
begin
  if not exists (select 1 from banques_privees where id = p_banque_id and publique) then raise exception 'Cette banque n''est pas publique.'; end if;
  select solde into v_solde from banques_comptes where banque_id = p_banque_id and citoyen_id = auth.uid();
  if v_solde is null then raise exception 'Vous n''êtes pas membre de cette banque.'; end if;
  update citoyens set tresorerie = tresorerie + v_solde where id = auth.uid();
  delete from banques_comptes where banque_id = p_banque_id and citoyen_id = auth.uid();
end; $$;
grant execute on function banque_quitter_publique(uuid) to authenticated;

create or replace function demander_adhesion_banque(p_banque_id uuid, p_motif text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from banques_privees where id = p_banque_id and publique) then raise exception 'Cette banque n''est pas publique.'; end if;
  if exists (select 1 from banques_comptes bc join banques_privees b on b.id = bc.banque_id where bc.citoyen_id = auth.uid() and b.publique) then
    raise exception 'Vous êtes déjà membre d''une banque publique (maximum : une seule).';
  end if;
  if p_motif is null or char_length(trim(p_motif)) < 10 then raise exception 'Justification requise (10 caractères minimum).'; end if;
  if exists (select 1 from banques_demandes_adhesion where banque_id = p_banque_id and citoyen_id = auth.uid() and statut = 'en_attente') then
    raise exception 'Une demande est déjà en attente.';
  end if;
  insert into banques_demandes_adhesion (banque_id, citoyen_id, motif) values (p_banque_id, auth.uid(), trim(p_motif));
end; $$;
grant execute on function demander_adhesion_banque(uuid, text) to authenticated;

create or replace function banque_traiter_adhesion(p_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
declare v_banque uuid; v_citoyen uuid;
begin
  select banque_id, citoyen_id into v_banque, v_citoyen from banques_demandes_adhesion where id = p_id and statut = 'en_attente';
  if v_banque is null then raise exception 'Demande introuvable ou déjà traitée.'; end if;
  if not _est_gestionnaire_banque(v_banque) then raise exception 'Réservé au propriétaire ou au conseiller de la banque.'; end if;
  if p_decision not in ('acceptee','refusee') then raise exception 'Décision invalide.'; end if;
  if p_decision = 'acceptee' and exists (select 1 from banques_comptes bc join banques_privees b on b.id = bc.banque_id where bc.citoyen_id = v_citoyen and b.publique) then
    raise exception 'Ce citoyen est déjà membre d''une autre banque publique.';
  end if;
  update banques_demandes_adhesion set statut = p_decision where id = p_id;
  if p_decision = 'acceptee' then
    insert into banques_comptes (banque_id, citoyen_id) values (v_banque, v_citoyen) on conflict (banque_id, citoyen_id) do nothing;
  end if;
end; $$;
grant execute on function banque_traiter_adhesion(uuid, text) to authenticated;


-- ============================================================
-- 5) MARCHÉ PUBLIC : vendre au nom d'une entreprise (PDG/Co-PDG) ou soi-même
-- ============================================================
alter table marche_annonces add column if not exists entreprise_vendeuse_id uuid references entreprises(id);

create or replace function marche_publier_annonce(p_champs jsonb)
returns marche_annonces language plpgsql security definer set search_path = public as $$
declare v_row marche_annonces; v_qte int; v_ent_id uuid; v_role text;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  v_qte := (p_champs->>'quantite_totale')::int;
  if v_qte is null or v_qte <= 0 then raise exception 'Quantité invalide.'; end if;
  if (p_champs->>'albatros')::boolean and (p_champs->>'albatros_mois')::int not in (4,8,12,24) then
    raise exception 'Durée Albatros invalide (4, 8, 12 ou 24 mois).';
  end if;

  v_ent_id := nullif(p_champs->>'entreprise_vendeuse_id', '')::uuid;
  if v_ent_id is not null then
    select role into v_role from entreprises_membres where entreprise_id = v_ent_id and citoyen_id = auth.uid();
    if v_role not in ('pdg','co_pdg') then raise exception 'Seul le PDG ou un Co-PDG peut vendre au nom de cette entreprise.'; end if;
  end if;

  insert into marche_annonces (
    vendeur_id, entreprise_vendeuse_id, titre, quantite_totale, quantite_disponible, prix_unitaire, description, contact_info,
    screenshot_vendeur_chemin, screenshot_objet_chemin, categorie_tp, importe, mode_livraison, portee_livraison,
    adresse_recuperation, livraison_duree_estimee, livraison_par, bureau_poste_code_temp, bureau_poste_code_expire,
    livraison_payee_vendeur, albatros, albatros_mois, province_vente
  ) values (
    auth.uid(), v_ent_id, p_champs->>'titre', v_qte, v_qte, (p_champs->>'prix_unitaire')::numeric, p_champs->>'description', p_champs->>'contact_info',
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

create or replace function mes_entreprises_vendeuses()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'nom', e.nom) order by e.nom), '[]'::jsonb)
  from entreprises_membres m join entreprises e on e.id = m.entreprise_id where m.citoyen_id = auth.uid() and m.role in ('pdg','co_pdg');
$$;
grant execute on function mes_entreprises_vendeuses() to authenticated;


-- ============================================================
-- 6) RÉAFFECTATION PARENTALITÉ -> RETRAITE À 3950 R$
-- ============================================================
-- Quand le compte parentalité atteint 3950 R$, la cotisation qui irait
-- normalement dans ce compte va plutôt dans le compte retraite (en plus
-- de la cotisation retraite normale), tant que le compte reste à 3950 R$
-- ou plus. Dès qu'il redescend en dessous (p. ex. après un retrait), la
-- cotisation reprend sa route normale vers la parentalité.
create or replace function _repartir_cotisations(p_citoyen_id uuid, p_brut numeric, out p_cho numeric, out p_ret numeric, out p_par numeric)
language plpgsql stable security definer set search_path = public as $$
declare v_compte_parentalite numeric;
begin
  select compte_parentalite into v_compte_parentalite from citoyens where id = p_citoyen_id;
  p_cho := p_brut * 0.0275;
  if coalesce(v_compte_parentalite, 0) >= 3950 then
    p_ret := p_brut * 0.0675 + p_brut * 0.0025; -- cotisation retraite normale + celle de la parentalité réaffectée
    p_par := 0;
  else
    p_ret := p_brut * 0.0675;
    p_par := p_brut * 0.0025;
  end if;
end; $$;

create or replace function entreprise_payer_employe(p_entreprise_id uuid, p_citoyen_id uuid, p_taux numeric, p_heures numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_dispo numeric; v_brut numeric; v_taux_revenu numeric; v_taux_prev numeric;
  v_tr numeric; v_te numeric; v_cho numeric; v_ret numeric; v_par numeric; v_net numeric; v_tresor numeric;
begin
  perform _exige_droit(p_entreprise_id, 'payer_employe');
  if p_heures <= 0 then raise exception 'Le nombre d''heures doit être positif.'; end if;

  select heures into v_dispo from entreprises_membres_heures
    where entreprise_id = p_entreprise_id and citoyen_id = p_citoyen_id and taux = p_taux for update;
  if v_dispo is null or v_dispo < p_heures then
    raise exception 'Heures accumulées insuffisantes à ce taux (disponible : % h).', coalesce(v_dispo, 0);
  end if;

  v_brut := p_taux * p_heures;
  select taux_revenu into v_taux_revenu from citoyens where id = p_citoyen_id;
  select taux_preventif into v_taux_prev from parametres_fiscaux where id = 1;
  v_tr := v_brut * (v_taux_revenu / 100.0); v_te := v_brut * (v_taux_prev / 100.0);
  select p_cho, p_ret, p_par into v_cho, v_ret, v_par from _repartir_cotisations(p_citoyen_id, v_brut);
  v_net := v_brut - v_tr - v_te - v_cho - v_ret - v_par;

  select tresorerie into v_tresor from entreprises where id = p_entreprise_id for update;
  if v_tresor >= v_brut then
    update entreprises set tresorerie = tresorerie - v_brut where id = p_entreprise_id;
    update citoyens set tresorerie = tresorerie + v_net, compte_chomage = compte_chomage + v_cho,
      compte_retraite = compte_retraite + v_ret, compte_parentalite = compte_parentalite + v_par,
      taxes_gouv_60j = taxes_gouv_60j + v_tr, taxe_preventive_60j = taxe_preventive_60j + v_te
      where id = p_citoyen_id;
    update tresor_public set solde = solde + v_tr + v_te, taxes_totales_periode = taxes_totales_periode + v_tr + v_te where id = 1;
  else
    perform _entreprise_gerer_manque_paie(p_entreprise_id, p_citoyen_id, v_net, p_taux);
  end if;

  update entreprises_membres_heures set heures = heures - p_heures
    where entreprise_id = p_entreprise_id and citoyen_id = p_citoyen_id and taux = p_taux;

  perform _entreprise_log(p_entreprise_id, 'paiement_employe',
    jsonb_build_object('citoyen_id', p_citoyen_id, 'montant', v_net, 'heures', p_heures, 'taux', p_taux,
      'brut', v_brut, 'taxe_revenu', v_tr, 'taxe_preventive', v_te, 'cotisations', v_cho + v_ret + v_par));
end; $$;
grant execute on function entreprise_payer_employe(uuid, uuid, numeric, numeric) to authenticated;

-- ============================================================
-- FIN
-- ============================================================
