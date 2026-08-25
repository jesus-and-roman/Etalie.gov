-- ============================================================
-- patch-tresorerie-contribuables.sql
-- À exécuter après patch-corrections-gel-police.sql. Idempotent.
--
-- CONTENU :
--  1. Corrections :
--     a) gouv_transferer_depuis_banque recréée + rechargement forcé du
--        cache de schéma PostgREST (NOTIFY pgrst). Si l'erreur persiste
--        après avoir exécuté ce fichier, allez dans Supabase > Database
--        > cliquez "Reload schema cache", ou patientez ~1 minute.
--     b) LE VRAI BUG des trésoreries négatives : le renflouement
--        automatique des banques nationales (posé dans un patch
--        précédent) se déclenchait AUSSI quand une banque était vidée
--        pour payer un salaire — donc chaque salaire payé "gratuitement"
--        re-puisait 50 000 R$ de plus dans la trésorerie publique, sans
--        jamais vraiment manquer d'argent (d'où : "même en manuel, la
--        personne reçoit son argent"). Le renflouement automatique ne
--        s'applique maintenant QUE pour les dépenses opérationnelles de
--        la presse monétaire (achat/entretien/impression/livraison),
--        jamais pour un paiement à un civil.
--  2. Le Roiyal (valeur, inflation, prix du gaz, coût carburant) ajouté
--     au Tableau de bord national.
--  3. Trésorerie des Contribuables (T1 traditionnelle / M1 moderne),
--     calcul en temps réel, contestation par le Congrès (fenêtre 89 jours,
--     tableau caché pendant la contestation), reset à 59 jours ou à
--     chaque rendement.
--  4. Système Entreprise (MVP) pour l'option M1 : création, approbation,
--     rôles (PDG/Co-PDG/employé), employés payés par l'entreprise (pas
--     le gouvernement), virement entrepreneur (0,15%, sans limite).
--
-- SIMPLIFICATIONS ASSUMÉES (scope énorme, à ajuster au besoin) :
--  - Pas de "diagramme" graphique des papiers d'impôt : juste un
--    tableau des dépôts successifs pour l'instant.
--  - Le "type d'entreprise" (indépendant / équipe familiale / … /
--    entreprise prospère) est recalculé automatiquement selon le
--    nombre de membres, pas modifiable manuellement.
-- ============================================================


-- ============================================================
-- 1) CORRECTIONS
-- ============================================================
DROP FUNCTION IF EXISTS gouv_transferer_depuis_banque(char, numeric, text);

create or replace function gouv_transferer_depuis_banque(
  p_banque_tag char(1),
  p_montant numeric,
  p_tresorerie_cible text default 'publique'
)
returns void language plpgsql security definer set search_path = public as $$
declare v_solde numeric;
begin
  if not est_admin_actuel() then
    raise exception 'Accès refusé : réservé au gouvernement.';
  end if;

  if p_montant <= 0 then
    raise exception 'Montant invalide.';
  end if;

  select tresorerie
  into v_solde
  from banques_nationales
  where tag = p_banque_tag
  for update;

  if v_solde is null then
    raise exception 'Banque invalide.';
  end if;

  if v_solde < p_montant then
    raise exception 'Trésorerie de la banque insuffisante.';
  end if;

  update banques_nationales
  set tresorerie = tresorerie - p_montant
  where tag = p_banque_tag;

  if p_tresorerie_cible = 'privee' then
    update tresor_public
    set solde_prive = solde_prive + p_montant
    where id = 1;
  else
    update tresor_public
    set solde = solde + p_montant
    where id = 1;
  end if;
end;
$$;

grant execute on function gouv_transferer_depuis_banque(char, numeric, text)
to authenticated;

-- Le renflouement automatique ignore désormais les débits faits pour payer
-- un civil (drapeau local à la transaction, jamais visible ailleurs).
create or replace function _renflouer_banque_nationale()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.tresorerie <= 0 and coalesce(current_setting('etalie.pas_de_renflouement', true), '') <> 'true' then
    perform gouv_puiser_interne(50000, 'publique');
    new.tresorerie := new.tresorerie + 50000;
  end if;
  return new;
end; $$;

create or replace function gouv_payer_civil(
  p_citoyen_id uuid, p_montant numeric,
  p_treasorerie_preferee text default 'publique', p_province text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_banque_tag char(1); v_solde_banque numeric; v_obtenu_banque numeric := 0;
  v_solde numeric; v_solde_prive numeric; v_home numeric; v_other numeric;
  v_pris_home numeric; v_pris_other numeric; v_obtenu_nat numeric := 0;
  v_reste numeric; v_total_obtenu numeric; v_manque numeric;
begin
  if p_montant is null or p_montant <= 0 then
    return jsonb_build_object('obtenu', 0, 'manque', 0);
  end if;
  v_reste := p_montant;

  if p_province is not null then
    select banque_tag into v_banque_tag from province_residence_banque where province = p_province;
    if v_banque_tag is not null then
      select tresorerie into v_solde_banque from banques_nationales where tag = v_banque_tag for update;
      if v_solde_banque is not null and v_solde_banque > 0 then
        v_obtenu_banque := least(v_reste, v_solde_banque);
        perform set_config('etalie.pas_de_renflouement', 'true', true);
        update banques_nationales set tresorerie = tresorerie - v_obtenu_banque where tag = v_banque_tag;
        perform set_config('etalie.pas_de_renflouement', 'false', true);
        v_reste := v_reste - v_obtenu_banque;
      end if;
    end if;
  end if;

  if v_reste > 0 then
    select solde, solde_prive into v_solde, v_solde_prive from tresor_public where id = 1 for update;
    if p_treasorerie_preferee = 'privee' then v_home := v_solde_prive; v_other := v_solde;
    else v_home := v_solde; v_other := v_solde_prive; end if;

    v_pris_home := least(v_reste, greatest(0, v_home));
    v_pris_other := least(v_reste - v_pris_home, greatest(0, v_other));
    v_obtenu_nat := v_pris_home + v_pris_other;

    if p_treasorerie_preferee = 'privee' then
      update tresor_public set solde_prive = solde_prive - v_pris_home, solde = solde - v_pris_other where id = 1;
    else
      update tresor_public set solde = solde - v_pris_home, solde_prive = solde_prive - v_pris_other where id = 1;
    end if;
    v_reste := v_reste - v_obtenu_nat;
  end if;

  v_total_obtenu := p_montant - v_reste;
  v_manque := v_reste;

  if v_total_obtenu > 0 then
    update citoyens set tresorerie = tresorerie + v_total_obtenu where id = p_citoyen_id;
  end if;
  if v_manque > 0 then
    update citoyens set argent_attendu = argent_attendu + v_manque where id = p_citoyen_id;
    insert into argent_attendu_log (citoyen_id, montant_initial, montant_restant) values (p_citoyen_id, v_manque, v_manque);
  end if;

  return jsonb_build_object('obtenu', v_total_obtenu, 'manque', v_manque);
end; $$;
revoke all on function gouv_payer_civil(uuid, numeric, text, text) from public;

create or replace function gouv_payer_salaire_ou_differer(
  p_citoyen_id uuid, p_brut numeric, p_province text, p_pct_tr numeric, p_pct_te numeric
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_tr numeric; v_te numeric; v_cho numeric; v_ret numeric; v_par numeric; v_net numeric;
  v_banque_tag char(1); v_solde_banque numeric := 0; v_solde numeric; v_solde_prive numeric;
  v_disponible numeric; v_pris_banque numeric; v_pris_pub numeric; v_pris_priv numeric;
begin
  if p_brut is null or p_brut <= 0 then return jsonb_build_object('paye_immediatement', true, 'net', 0, 'brut', 0); end if;

  v_tr := p_brut * (p_pct_tr/100.0);
  v_te := p_brut * (p_pct_te/100.0);
  v_cho := p_brut * 0.0275;
  v_ret := p_brut * 0.0675;
  v_par := p_brut * 0.0025;
  v_net := p_brut - v_tr - v_te - v_cho - v_ret - v_par;

  if p_province is not null then
    select banque_tag into v_banque_tag from province_residence_banque where province = p_province;
    if v_banque_tag is not null then
      select tresorerie into v_solde_banque from banques_nationales where tag = v_banque_tag for update;
    end if;
  end if;
  select solde, solde_prive into v_solde, v_solde_prive from tresor_public where id = 1 for update;

  v_disponible := greatest(0, v_solde_banque) + greatest(0, v_solde) + greatest(0, v_solde_prive);

  if v_disponible < v_net then
    insert into argent_attendu_log (citoyen_id, type, montant_initial, montant_brut, montant_restant, pct_tr, pct_te, pct_chomage, pct_retraite, pct_parentalite)
      values (p_citoyen_id, 'salaire', p_brut, p_brut, p_brut, p_pct_tr, p_pct_te, 2.75, 6.75, 0.25);
    update citoyens set argent_attendu = argent_attendu + p_brut where id = p_citoyen_id;
    return jsonb_build_object('paye_immediatement', false, 'brut_differe', p_brut);
  end if;

  v_pris_banque := least(v_net, greatest(0, v_solde_banque));
  v_pris_pub := least(v_net - v_pris_banque, greatest(0, v_solde));
  v_pris_priv := v_net - v_pris_banque - v_pris_pub;

  if v_banque_tag is not null and v_pris_banque > 0 then
    perform set_config('etalie.pas_de_renflouement', 'true', true);
    update banques_nationales set tresorerie = tresorerie - v_pris_banque where tag = v_banque_tag;
    perform set_config('etalie.pas_de_renflouement', 'false', true);
  end if;
  update tresor_public set solde = solde - v_pris_pub, solde_prive = solde_prive - v_pris_priv where id = 1;

  update citoyens set
    tresorerie = tresorerie + v_net,
    compte_chomage = compte_chomage + v_cho,
    compte_retraite = compte_retraite + v_ret,
    compte_parentalite = compte_parentalite + v_par,
    taxes_gouv_60j = taxes_gouv_60j + v_tr,
    taxe_preventive_60j = taxe_preventive_60j + v_te
    where id = p_citoyen_id;
  update tresor_public set solde = solde + v_tr + v_te, taxes_totales_periode = taxes_totales_periode + v_tr + v_te where id = 1;

  return jsonb_build_object('paye_immediatement', true, 'net', v_net, 'brut', p_brut);
end; $$;
revoke all on function gouv_payer_salaire_ou_differer(uuid, numeric, text, numeric, numeric) from public;

-- Force PostgREST à relire le schéma (corrige les erreurs
-- "Could not find the function ... in the schema cache").
notify pgrst, 'reload schema';


-- ============================================================
-- 2) LE ROIYAL DANS LE TABLEAU DE BORD NATIONAL
-- ============================================================
create or replace function tableau_de_bord_national()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_pib numeric; v_ref numeric; v_date timestamptz; v_variation numeric; v_taxes numeric;
  v_roiyal numeric; v_inflation numeric; v_prix_essence numeric;
begin
  perform _rafraichir_pib_historique();
  v_pib := pib_actuel();
  select pib_reference, date_reference into v_ref, v_date from pib_historique where id = 1;
  v_variation := case when v_ref = 0 then 0 else round(((v_pib - v_ref)/v_ref)*100, 4) end;
  select taxes_totales_periode into v_taxes from tresor_public where id = 1;

  select valeur_r into v_roiyal from roiyal_etat where id = 1;
  v_inflation := 100 - coalesce(v_roiyal, 100);
  v_prix_essence := 4.2 * (100 / coalesce(v_roiyal, 100));

  return jsonb_build_object(
    'pib_actuel', v_pib, 'pib_reference', v_ref, 'date_reference', v_date, 'variation_pct', v_variation,
    'palamoss_pct', palamoss_pourcentage(), 'taxes_totales_periode', v_taxes,
    'dette_nationale', dette_nationale_argent_attendu(),
    'roiyal_valeur', v_roiyal, 'roiyal_inflation', v_inflation,
    'prix_essence', v_prix_essence, 'cout_carburant_km', round(v_prix_essence/15.0, 6)
  );
end; $$;
grant execute on function tableau_de_bord_national() to authenticated, anon;


-- ============================================================
-- 3) TRÉSORERIE DES CONTRIBUABLES (T1 / M1)
-- ============================================================
create table if not exists tresorerie_contribuables (
  id                 int primary key default 1 check (id = 1),
  option_calcul      text not null default 'T1' check (option_calcul in ('T1','M1')),
  montant_conteste   numeric,
  en_contestation    boolean not null default false,
  date_reference     timestamptz not null default now(),
  derniere_contestation timestamptz
);
insert into tresorerie_contribuables (id) values (1) on conflict (id) do nothing;
alter table tresorerie_contribuables enable row level security;
drop policy if exists "Lecture publique tresorerie contribuables" on tresorerie_contribuables;
create policy "Lecture publique tresorerie contribuables" on tresorerie_contribuables for select using (true);

create table if not exists contestations_contribuables (
  id            uuid primary key default gen_random_uuid(),
  demandeur_id  uuid not null references auth.users(id),
  raison        text not null,
  statut        text not null default 'en_attente' check (statut in ('en_attente','acceptee','refusee')),
  nouveau_montant numeric,
  cree_le       timestamptz not null default now(),
  traite_le     timestamptz
);
alter table contestations_contribuables enable row level security;
drop policy if exists "Lecture publique des contestations" on contestations_contribuables;
create policy "Lecture publique des contestations" on contestations_contribuables for select using (true);

create or replace function gouv_definir_option_contribuables(p_option text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if p_option not in ('T1','M1') then raise exception 'Option invalide.'; end if;
  update tresorerie_contribuables set option_calcul = p_option where id = 1;
end; $$;
grant execute on function gouv_definir_option_contribuables(text) to authenticated;

-- X (34%, travailleurs ou entrepreneurs) / Y (66%, trésorerie publique).
-- X est figé si contesté par le Congrès, sinon recalculé en temps réel.
create or replace function contribuables_x_y()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_taxes numeric; v_row public.tresorerie_contribuables; v_x numeric; v_y numeric;
begin
  select * into v_row from tresorerie_contribuables where id = 1;
  select taxes_totales_periode into v_taxes from tresor_public where id = 1;
  v_y := round(coalesce(v_taxes,0) * 0.66, 2);
  if v_row.montant_conteste is not null then
    v_x := v_row.montant_conteste;
  else
    v_x := round(coalesce(v_taxes,0) * 0.34, 2);
  end if;
  if v_row.en_contestation then
    return jsonb_build_object('en_contestation', true, 'option', v_row.option_calcul);
  end if;
  return jsonb_build_object('x', v_x, 'y', v_y, 'option', v_row.option_calcul, 'en_contestation', false);
end; $$;
grant execute on function contribuables_x_y() to authenticated, anon;

-- Réinitialise (X libre à nouveau, période relancée) : à appeler à chaque
-- rendement des contribuables ou automatiquement tous les 59 jours.
create or replace function _rafraichir_tresorerie_contribuables()
returns void language plpgsql security definer set search_path = public as $$
begin
  update tresorerie_contribuables set montant_conteste = null, date_reference = now()
    where id = 1 and date_reference <= now() - interval '59 days' and not en_contestation;
end; $$;

-- Contestation (fenêtre de 89 jours entre deux contestations).
create or replace function demander_contestation_contribuables(p_raison text)
returns public.contestations_contribuables language plpgsql security definer set search_path = public as $$
declare v_row public.tresorerie_contribuables; v_c public.contestations_contribuables;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  select * into v_row from tresorerie_contribuables where id = 1;
  if v_row.derniere_contestation is not null and v_row.derniere_contestation > now() - interval '89 days' then
    raise exception 'Une contestation ne peut être demandée qu''une fois tous les 89 jours (prochaine possible le %).',
      (v_row.derniere_contestation + interval '89 days')::date;
  end if;
  insert into contestations_contribuables (demandeur_id, raison) values (auth.uid(), p_raison) returning * into v_c;
  return v_c;
end; $$;
grant execute on function demander_contestation_contribuables(text) to authenticated;

create or replace function gouv_traiter_contestation_contribuables(p_id uuid, p_decision text, p_nouveau_montant numeric default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if p_decision not in ('acceptee','refusee') then raise exception 'Décision invalide.'; end if;

  update contestations_contribuables set statut = p_decision, nouveau_montant = p_nouveau_montant, traite_le = now()
    where id = p_id and statut = 'en_attente';

  if p_decision = 'acceptee' then
    if p_nouveau_montant is null then raise exception 'Indiquez le nouveau montant décidé par le Congrès.'; end if;
    update tresorerie_contribuables set montant_conteste = p_nouveau_montant, en_contestation = false, derniere_contestation = now()
      where id = 1;
  else
    update tresorerie_contribuables set en_contestation = false where id = 1;
  end if;
end; $$;
grant execute on function gouv_traiter_contestation_contribuables(uuid, text, numeric) to authenticated;

-- Ouvre officiellement la période de contestation (masque le tableau à tous).
create or replace function gouv_ouvrir_contestation_contribuables()
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  update tresorerie_contribuables set en_contestation = true where id = 1;
end; $$;
grant execute on function gouv_ouvrir_contestation_contribuables() to authenticated;


-- ------------------------------------------------------------
-- ENTREPRISES (pour l'option M1)
-- ------------------------------------------------------------
create table if not exists entreprises (
  id                     uuid primary key default gen_random_uuid(),
  code                   text not null unique,
  nom                    text not null,
  depenses_an_dernier    numeric, numero_papier_impot_depenses text,
  achats_an_dernier      numeric, numero_papier_impot_achats text,
  type_vente             text, mode_vente text,
  boutique_principale    text, boutiques_secondaires text,
  sieges                 text not null,
  fondateur_id           uuid not null references auth.users(id),
  fondateur_cas          text,
  statut                 text not null default 'en_attente' check (statut in ('en_attente','acceptee','refusee')),
  tresorerie             numeric not null default 0,
  cree_le                timestamptz not null default now()
);
alter table entreprises enable row level security;
drop policy if exists "Lecture publique des entreprises acceptées" on entreprises;
create policy "Lecture publique des entreprises acceptées" on entreprises
  for select using (statut = 'acceptee' or fondateur_id = auth.uid() or est_admin_actuel());

create table if not exists entreprises_membres (
  id              uuid primary key default gen_random_uuid(),
  entreprise_id   uuid not null references entreprises(id),
  citoyen_id      uuid not null references auth.users(id),
  role            text not null check (role in ('pdg','co_pdg','employe')),
  salaire_horaire numeric,
  cree_le         timestamptz not null default now(),
  unique (entreprise_id, citoyen_id)
);
alter table entreprises_membres enable row level security;
drop policy if exists "Lecture publique des membres d'entreprise" on entreprises_membres;
create policy "Lecture publique des membres d'entreprise" on entreprises_membres for select using (true);

create table if not exists entreprises_depots_impots (
  id              uuid primary key default gen_random_uuid(),
  entreprise_id   uuid not null references entreprises(id),
  periode         text not null,
  benefices       numeric not null default 0,
  depenses        numeric not null default 0,
  note            text,
  depose_par      uuid not null references auth.users(id),
  cree_le         timestamptz not null default now()
);
alter table entreprises_depots_impots enable row level security;
drop policy if exists "Lecture publique des dépôts d'impôts" on entreprises_depots_impots;
create policy "Lecture publique des dépôts d'impôts" on entreprises_depots_impots
  for select using (exists (select 1 from entreprises_membres m where m.entreprise_id = entreprises_depots_impots.entreprise_id and m.citoyen_id = auth.uid()) or est_admin_actuel());

create or replace function _type_entreprise(p_nb int)
returns text language sql immutable as $$
  select case
    when p_nb <= 1 then 'Indépendant'
    when p_nb <= 5 then 'Équipe familiale'
    when p_nb <= 20 then 'Petite équipe'
    when p_nb <= 50 then 'Équipe moyenne'
    when p_nb <= 100 then 'Grosse équipe'
    when p_nb <= 1000 then 'Grande équipe'
    when p_nb <= 5001 then 'Grande entreprise'
    when p_nb <= 15000 then 'Entreprise nationale'
    else 'Entreprise prospère'
  end;
$$;

create or replace function entreprise_demander(
  p_nom text, p_depenses numeric, p_num_papier_depenses text, p_achats numeric, p_num_papier_achats text,
  p_type_vente text, p_mode_vente text, p_boutique_principale text, p_boutiques_secondaires text,
  p_sieges text, p_fondateur_cas text, p_employes jsonb default '[]'::jsonb
) returns public.entreprises language plpgsql security definer set search_path = public as $$
declare v_row public.entreprises; v_emp jsonb; v_emp_id uuid;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if p_nom is null or char_length(trim(p_nom)) = 0 then raise exception 'Nom d''entreprise requis.'; end if;
  if p_sieges is null or char_length(trim(p_sieges)) = 0 then raise exception 'Au moins un siège physique est requis.'; end if;

  insert into entreprises (code, nom, depenses_an_dernier, numero_papier_impot_depenses, achats_an_dernier,
    numero_papier_impot_achats, type_vente, mode_vente, boutique_principale, boutiques_secondaires, sieges,
    fondateur_id, fondateur_cas)
  values ('E-' || _generer_code_alnum(8), p_nom, p_depenses, p_num_papier_depenses, p_achats, p_num_papier_achats,
    p_type_vente, p_mode_vente, p_boutique_principale, p_boutiques_secondaires, p_sieges, auth.uid(), p_fondateur_cas)
  returning * into v_row;

  for v_emp in select * from jsonb_array_elements(coalesce(p_employes,'[]'::jsonb)) loop
    select id into v_emp_id from citoyens where code_social_encrypte = (v_emp->>'cas');
    if v_emp_id is not null then
      insert into entreprises_membres (entreprise_id, citoyen_id, role) values (v_row.id, v_emp_id, 'employe')
        on conflict do nothing;
    end if;
  end loop;

  return v_row;
end; $$;
grant execute on function entreprise_demander(text,numeric,text,numeric,text,text,text,text,text,text,text,jsonb) to authenticated;

create or replace function gouv_liste_demandes_entreprises(p_statut text default 'en_attente')
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not est_admin_actuel() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id, 'code', e.code, 'nom', e.nom, 'fondateur_username', c.username, 'sieges', e.sieges,
    'type_vente', e.type_vente, 'mode_vente', e.mode_vente, 'cree_le', e.cree_le
  ) order by e.cree_le), '[]'::jsonb) end
  from entreprises e join citoyens c on c.id = e.fondateur_id where e.statut = p_statut;
$$;
grant execute on function gouv_liste_demandes_entreprises(text) to authenticated;

create or replace function gouv_traiter_demande_entreprise(p_entreprise_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
declare v_row public.entreprises;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if p_decision not in ('acceptee','refusee') then raise exception 'Décision invalide.'; end if;
  update entreprises set statut = p_decision where id = p_entreprise_id and statut = 'en_attente' returning * into v_row;
  if v_row is null then raise exception 'Demande introuvable ou déjà traitée.'; end if;
  if p_decision = 'acceptee' then
    insert into entreprises_membres (entreprise_id, citoyen_id, role) values (v_row.id, v_row.fondateur_id, 'pdg')
      on conflict (entreprise_id, citoyen_id) do update set role = 'pdg';
  end if;
end; $$;
grant execute on function gouv_traiter_demande_entreprise(uuid, text) to authenticated;

create or replace function mes_entreprises()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id, 'code', e.code, 'nom', e.nom, 'role', m.role, 'tresorerie', e.tresorerie,
    'type', _type_entreprise((select count(*)::int from entreprises_membres m2 where m2.entreprise_id = e.id))
  )), '[]'::jsonb)
  from entreprises_membres m join entreprises e on e.id = m.entreprise_id
  where m.citoyen_id = auth.uid() and e.statut = 'acceptee';
$$;
grant execute on function mes_entreprises() to authenticated;

create or replace function entreprise_detail(p_entreprise_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_e public.entreprises; v_mon_role text; v_membres jsonb; v_depots jsonb;
begin
  select * into v_e from entreprises where id = p_entreprise_id;
  if v_e is null then raise exception 'Entreprise introuvable.'; end if;
  select role into v_mon_role from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_mon_role is null and not est_admin_actuel() then raise exception 'Accès refusé.'; end if;

  select coalesce(jsonb_agg(jsonb_build_object('username', c.username, 'nom_complet', c.prenom||' '||c.nom, 'role', m.role, 'salaire_horaire', m.salaire_horaire, 'citoyen_id', m.citoyen_id)), '[]'::jsonb)
    into v_membres from entreprises_membres m join citoyens c on c.id = m.citoyen_id where m.entreprise_id = p_entreprise_id;
  select coalesce(jsonb_agg(jsonb_build_object('periode', periode, 'benefices', benefices, 'depenses', depenses, 'note', note, 'cree_le', cree_le) order by cree_le desc), '[]'::jsonb)
    into v_depots from entreprises_depots_impots where entreprise_id = p_entreprise_id;

  return jsonb_build_object(
    'id', v_e.id, 'code', v_e.code, 'nom', v_e.nom, 'tresorerie', v_e.tresorerie, 'sieges', v_e.sieges,
    'type', _type_entreprise(jsonb_array_length(v_membres)), 'mon_role', v_mon_role, 'membres', v_membres, 'depots_impots', v_depots
  );
end; $$;
grant execute on function entreprise_detail(uuid) to authenticated;

create or replace function entreprise_ajouter_employe(p_entreprise_id uuid, p_cas text, p_salaire_horaire numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_mon_role text; v_id uuid;
begin
  select role into v_mon_role from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_mon_role not in ('pdg','co_pdg') then raise exception 'Accès refusé : réservé au PDG ou aux Co-PDG.'; end if;
  if p_salaire_horaire < 18 then raise exception 'Le salaire doit être au moins le salaire minimum (18 R$/heure).'; end if;
  select id into v_id from citoyens where code_social_encrypte = p_cas;
  if v_id is null then raise exception 'Code d''assurance social introuvable.'; end if;
  insert into entreprises_membres (entreprise_id, citoyen_id, role, salaire_horaire) values (p_entreprise_id, v_id, 'employe', p_salaire_horaire)
    on conflict (entreprise_id, citoyen_id) do update set salaire_horaire = p_salaire_horaire;
end; $$;
grant execute on function entreprise_ajouter_employe(uuid, text, numeric) to authenticated;

create or replace function entreprise_definir_role(p_entreprise_id uuid, p_citoyen_id uuid, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare v_mon_role text;
begin
  select role into v_mon_role from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_mon_role <> 'pdg' then raise exception 'Accès refusé : réservé au PDG.'; end if;
  if p_role not in ('pdg','co_pdg','employe') then raise exception 'Rôle invalide.'; end if;
  if p_role = 'pdg' then
    update entreprises_membres set role = 'co_pdg' where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  end if;
  update entreprises_membres set role = p_role where entreprise_id = p_entreprise_id and citoyen_id = p_citoyen_id;
end; $$;
grant execute on function entreprise_definir_role(uuid, uuid, text) to authenticated;

-- Paie un employé depuis la trésorerie de l'ENTREPRISE (pas le gouvernement) ;
-- les taxes normales (TR/préventive) sont quand même comptées au gouvernement.
create or replace function entreprise_payer_employe(p_entreprise_id uuid, p_citoyen_id uuid, p_heures numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_mon_role text; v_salaire numeric; v_brut numeric; v_taux_revenu numeric; v_taux_prev numeric;
  v_tr numeric; v_te numeric; v_cho numeric; v_ret numeric; v_par numeric; v_net numeric; v_tresor numeric;
begin
  select role into v_mon_role from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_mon_role not in ('pdg','co_pdg') then raise exception 'Accès refusé : réservé au PDG ou aux Co-PDG.'; end if;
  select salaire_horaire into v_salaire from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = p_citoyen_id;
  if v_salaire is null then raise exception 'Employé introuvable dans cette entreprise.'; end if;
  select tresorerie into v_tresor from entreprises where id = p_entreprise_id for update;

  v_brut := v_salaire * p_heures;
  if v_tresor < v_brut then raise exception 'Trésorerie de l''entreprise insuffisante.'; end if;

  select taux_revenu into v_taux_revenu from citoyens where id = p_citoyen_id;
  select taux_preventif into v_taux_prev from parametres_fiscaux where id = 1;
  v_tr := v_brut * (v_taux_revenu/100.0); v_te := v_brut * (v_taux_prev/100.0);
  v_cho := v_brut * 0.0275; v_ret := v_brut * 0.0675; v_par := v_brut * 0.0025;
  v_net := v_brut - v_tr - v_te - v_cho - v_ret - v_par;

  update entreprises set tresorerie = tresorerie - v_brut where id = p_entreprise_id;
  update citoyens set tresorerie = tresorerie + v_net, compte_chomage = compte_chomage + v_cho,
    compte_retraite = compte_retraite + v_ret, compte_parentalite = compte_parentalite + v_par,
    taxes_gouv_60j = taxes_gouv_60j + v_tr, taxe_preventive_60j = taxe_preventive_60j + v_te
    where id = p_citoyen_id;
  update tresor_public set solde = solde + v_tr + v_te, taxes_totales_periode = taxes_totales_periode + v_tr + v_te where id = 1;
end; $$;
grant execute on function entreprise_payer_employe(uuid, uuid, numeric) to authenticated;

create or replace function entreprise_deposer_impot(p_entreprise_id uuid, p_periode text, p_benefices numeric, p_depenses numeric, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare v_mon_role text;
begin
  select role into v_mon_role from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_mon_role is null then raise exception 'Accès refusé.'; end if;
  insert into entreprises_depots_impots (entreprise_id, periode, benefices, depenses, note, depose_par)
    values (p_entreprise_id, p_periode, p_benefices, p_depenses, p_note, auth.uid());
end; $$;
grant execute on function entreprise_deposer_impot(uuid, text, numeric, numeric, text) to authenticated;

-- Virement entrepreneur : 0,15%, sans limite. Crédite la TRÉSORERIE DE
-- L'ENTREPRISE d'expédition, pas le PDG personnellement.
create or replace function virement_entrepreneur(p_entreprise_id uuid, p_destinataire_username text, p_montant numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_mon_role text; v_dest_id uuid; v_expediteur citoyens; v_taxe numeric; v_total numeric;
begin
  select role into v_mon_role from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_mon_role not in ('pdg','co_pdg') then raise exception 'Accès refusé : réservé au PDG ou aux Co-PDG.'; end if;
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select id into v_dest_id from citoyens where lower(username) = lower(p_destinataire_username);
  if v_dest_id is null then raise exception 'Destinataire introuvable.'; end if;

  select * into v_expediteur from citoyens where id = auth.uid();
  v_taxe := p_montant * 0.0015;
  v_total := p_montant + v_taxe;
  if v_expediteur.tresorerie < v_total then raise exception 'Trésorerie personnelle insuffisante (total avec taxe: %).', v_total; end if;

  update citoyens set tresorerie = tresorerie - v_total where id = auth.uid();
  update entreprises set tresorerie = tresorerie + p_montant where id = p_entreprise_id;
  update tresor_public set solde_prive = solde_prive + v_taxe where id = 1;
end; $$;
grant execute on function virement_entrepreneur(uuid, text, numeric) to authenticated;


-- ============================================================
-- 4) RENDEMENT DES CONTRIBUABLES — nouveau moteur T1 / M1
-- ============================================================
create or replace function admin_traiter_rendement_contribuables()
returns text language plpgsql security definer set search_path = public as $$
declare
  v_option text; v_xy jsonb; v_x numeric; v_id uuid; v_salaire numeric; v_b numeric;
  v_max_par_personne numeric; v_montant numeric; v_nb_entreprises int; v_montant_par_entreprise numeric;
  v_nb_employes_total int; v_taux_par_employe numeric; v_entreprise record;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  select * into v_xy from contribuables_x_y();
  if (v_xy->>'en_contestation')::boolean then raise exception 'Une contestation est en cours : impossible de distribuer.'; end if;
  select option_calcul into v_option from tresorerie_contribuables where id = 1;
  v_x := (v_xy->>'x')::numeric;

  if v_option = 'T1' then
    v_max_par_personne := least(5000, v_x / 31912445.0);
    for v_id, v_salaire, v_b in
      select id, salaire, (taxes_gouv_60j + taxe_preventive_60j) from citoyens
    loop
      if coalesce(v_salaire,0) >= 0.01 and coalesce(v_b,0) >= 500 then
        v_montant := least(v_max_par_personne, v_b);
        if v_montant > 0 then
          perform gouv_payer_civil(v_id, v_montant, 'publique');
        end if;
      end if;
    end loop;
  else
    select count(*) into v_nb_entreprises from entreprises where statut = 'acceptee';
    if v_nb_entreprises = 0 then raise exception 'Aucune entreprise acceptée : rien à distribuer en option M1.'; end if;
    select count(*) into v_nb_employes_total from entreprises_membres m join entreprises e on e.id = m.entreprise_id where e.statut = 'acceptee';
    v_taux_par_employe := case when v_nb_employes_total = 0 then 0 else v_x / v_nb_employes_total end;
    v_montant_par_entreprise := v_x / v_nb_entreprises;

    for v_entreprise in select e.id, count(m.id) as nb_employes from entreprises e
      left join entreprises_membres m on m.entreprise_id = e.id where e.statut = 'acceptee' group by e.id
    loop
      v_montant := least(v_montant_par_entreprise, v_taux_par_employe * greatest(1, v_entreprise.nb_employes));
      update entreprises set tresorerie = tresorerie + v_montant where id = v_entreprise.id;
      update tresor_public set solde = solde - v_montant where id = 1;
    end loop;
  end if;

  update tresor_public set taxes_totales_periode = 0 where id = 1;
  update tresorerie_contribuables set montant_conteste = null, date_reference = now() where id = 1;
  update pib_historique set pib_reference = pib_actuel(), date_reference = now() where id = 1;
  perform gouv_distribuer_argent_attendu();
  return 'Rendement des contribuables (' || v_option || ') distribué.';
end; $$;
grant execute on function admin_traiter_rendement_contribuables() to authenticated;

-- ============================================================
-- FIN
-- ============================================================
