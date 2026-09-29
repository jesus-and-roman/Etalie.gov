-- ============================================================
-- patch-cib-entreprise-avancee-5.sql
-- À exécuter après patch-cib-entreprise-avancee-4.sql. Additif et rejouable.
--
--  1. Tables de support pour rendre le relevé mensuel réel plutôt
--     qu'estimé : emprunts citoyen<->gouvernement (simplifiés, sans
--     négociation), journal des retraits de capital, détail de l'argent
--     attendu, notes au dossier ajoutées par le gouvernement, parentalité
--     ajoutée aux demandes d'épargne, ventilation des taxes dans les logs
--     de paiement d'employé.
--  2. Factures manuelles : ajoutées PENDANT le mois courant (avant le 1er
--     du mois suivant) pour la PROCHAINE déclaration, catégorisées, tous
--     les champs demandés, visibilité choisie par le citoyen.
--  3. Génération automatique du relevé mensuel, le 1er du jour (comme les
--     entreprises, rattrapage à la connexion si pg_cron n'est pas actif) :
--     toujours automatique, jamais manuel, période = mois précédent.
--  4. Consultation publique par nom d'utilisateur, avec CAS et CIB
--     personnels/d'envoi jamais nommés (rectangle noir), sauf pour
--     l'administration qui voit tout, sans caviardage, avec plus de détail.
--
-- HYPOTHÈSE (limites honnêtes, faute d'un journal historique complet) :
--  - Le salaire net "CAS" du mois est une ESTIMATION (taux actuel × durée
--    de la période), faute d'un journal transaction par transaction du
--    revenu de base (il tourne à chaque seconde, journaliser chaque
--    paiement serait disproportionné). Le salaire d'ENTREPRISE, lui, est
--    EXACT (tiré des logs d'entreprise).
--  - "Contribution au gouvernement" du mois = taxes de revenu + taxe
--    préventive estimées (CAS) + exactes (entreprises, depuis les logs).
--  - Les formations/récompenses "obtenues dans le mois" utilisent leur
--    date de création/attribution réelle.
--  - Catégorie de facture manuelle : texte libre (la liste exacte des
--    catégories n'était pas strictement énumérée).
-- ============================================================


-- ============================================================
-- 1) TABLES DE SUPPORT
-- ============================================================

-- Parentalité ajoutée aux demandes d'épargne existantes (famille/retraite).
alter table demandes_epargne drop constraint if exists demandes_epargne_type_check;
alter table demandes_epargne add constraint demandes_epargne_type_check check (type in ('chomage','retraite','parentalite'));

create or replace function demander_epargne(p_type text, p_preuve text)
returns demandes_epargne language plpgsql security definer set search_path = public as $$
declare v_row demandes_epargne; v_age numeric; v_naissance date;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if p_type not in ('chomage','retraite','parentalite') then raise exception 'Type de demande invalide.'; end if;
  if p_preuve is null or char_length(trim(p_preuve)) < 10 then raise exception 'Preuve/justification requise (10 caractères minimum).'; end if;
  if exists (select 1 from demandes_epargne where citoyen_id = auth.uid() and type = p_type and statut = 'en_attente') then
    raise exception 'Une demande de ce type est déjà en attente.';
  end if;
  insert into demandes_epargne (citoyen_id, type, preuve_texte) values (auth.uid(), p_type, trim(p_preuve)) returning * into v_row;
  return v_row;
end; $$;
grant execute on function demander_epargne(text, text) to authenticated;

-- Emprunts citoyen <-> gouvernement (version simple, sans négociation).
create table if not exists citoyens_emprunts_gouv (
  id              uuid primary key default gen_random_uuid(),
  citoyen_id      uuid not null references auth.users(id),
  montant_demande numeric not null check (montant_demande > 0),
  type_taux       text not null check (type_taux in ('jour','mois','an','fixe')),
  taux_valeur     numeric not null check (taux_valeur >= 0),
  justification   text not null,
  statut          text not null default 'en_attente' check (statut in ('en_attente','acceptee','refusee','rembourse')),
  montant_du      numeric,
  accepte_le      timestamptz,
  cree_le         timestamptz not null default now()
);
alter table citoyens_emprunts_gouv enable row level security;
drop policy if exists "Voir ses emprunts citoyen-gouvernement ou tout si admin" on citoyens_emprunts_gouv;
create policy "Voir ses emprunts citoyen-gouvernement ou tout si admin" on citoyens_emprunts_gouv for select
  using (citoyen_id = auth.uid() or est_admin_actuel());

create or replace function demander_emprunt_gouv(p_montant numeric, p_type_taux text, p_taux_valeur numeric, p_justification text)
returns citoyens_emprunts_gouv language plpgsql security definer set search_path = public as $$
declare v_row citoyens_emprunts_gouv;
begin
  if p_montant <= 0 then raise exception 'Montant invalide.'; end if;
  if p_type_taux not in ('jour','mois','an','fixe') then raise exception 'Type de taux invalide.'; end if;
  if p_justification is null or char_length(trim(p_justification)) < 10 then raise exception 'Justification requise (10 caractères minimum).'; end if;
  insert into citoyens_emprunts_gouv (citoyen_id, montant_demande, type_taux, taux_valeur, justification)
    values (auth.uid(), p_montant, p_type_taux, p_taux_valeur, trim(p_justification)) returning * into v_row;
  return v_row;
end; $$;
grant execute on function demander_emprunt_gouv(numeric, text, numeric, text) to authenticated;

create or replace function gouv_liste_emprunts_citoyens(p_statut text default 'en_attente')
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not est_admin_actuel() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id, 'username', c.username, 'montant_demande', e.montant_demande, 'type_taux', e.type_taux,
    'taux_valeur', e.taux_valeur, 'justification', e.justification, 'cree_le', e.cree_le
  ) order by e.cree_le), '[]'::jsonb) end
  from citoyens_emprunts_gouv e join citoyens c on c.id = e.citoyen_id where e.statut = p_statut;
$$;
grant execute on function gouv_liste_emprunts_citoyens(text) to authenticated;

create or replace function gouv_traiter_emprunt_citoyen(p_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
declare v citoyens_emprunts_gouv; v_du numeric; v_solde numeric;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  if p_decision not in ('acceptee','refusee') then raise exception 'Décision invalide.'; end if;
  select * into v from citoyens_emprunts_gouv where id = p_id and statut = 'en_attente' for update;
  if v.id is null then raise exception 'Demande introuvable ou déjà traitée.'; end if;
  if p_decision = 'refusee' then
    update citoyens_emprunts_gouv set statut = 'refusee' where id = p_id;
    return;
  end if;
  select solde into v_solde from tresor_public where id = 1 for update;
  if v_solde < v.montant_demande then raise exception 'Trésorerie publique insuffisante.'; end if;
  v_du := case when v.type_taux = 'fixe' then v.montant_demande + v.taux_valeur else v.montant_demande end;
  update tresor_public set solde = solde - v.montant_demande where id = 1;
  update citoyens set tresorerie = tresorerie + v.montant_demande where id = v.citoyen_id;
  update citoyens_emprunts_gouv set statut = 'acceptee', montant_du = v_du, accepte_le = now() where id = p_id;
end; $$;
grant execute on function gouv_traiter_emprunt_citoyen(uuid, text) to authenticated;

create or replace function emprunt_citoyen_gouv_montant_du(p_id uuid)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare v citoyens_emprunts_gouv; v_jours numeric; v_par_jour numeric;
begin
  select * into v from citoyens_emprunts_gouv where id = p_id;
  if v.id is null or v.statut <> 'acceptee' then return coalesce(v.montant_du, 0); end if;
  if v.type_taux = 'fixe' then return v.montant_du; end if;
  v_jours := extract(epoch from (now() - v.accepte_le)) / 86400.0;
  v_par_jour := case v.type_taux
    when 'jour' then v.montant_demande * (v.taux_valeur / 100.0)
    when 'mois' then v.montant_demande * (v.taux_valeur / 100.0) / 30.0
    when 'an'   then v.montant_demande * (v.taux_valeur / 100.0) / 365.0
  end;
  return v.montant_demande + v_par_jour * v_jours;
end; $$;
grant execute on function emprunt_citoyen_gouv_montant_du(uuid) to authenticated;

create or replace function rembourser_emprunt_gouv(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_du numeric; v_tresor numeric;
begin
  if not exists (select 1 from citoyens_emprunts_gouv where id = p_id and citoyen_id = auth.uid() and statut = 'acceptee') then
    raise exception 'Emprunt introuvable ou non actif.';
  end if;
  v_du := emprunt_citoyen_gouv_montant_du(p_id);
  select tresorerie into v_tresor from citoyens where id = auth.uid() for update;
  if v_tresor < v_du then raise exception 'Trésorerie insuffisante (dû : % R$).', v_du; end if;
  update citoyens set tresorerie = tresorerie - v_du where id = auth.uid();
  update tresor_public set solde = solde + v_du where id = 1;
  update citoyens_emprunts_gouv set statut = 'rembourse', montant_du = 0, rembourse_le = now() where id = p_id;
end; $$;

alter table citoyens_emprunts_gouv add column if not exists rembourse_le timestamptz;
grant execute on function rembourser_emprunt_gouv(uuid) to authenticated;

-- Journal des retraits de capital (pour un vrai total "cash out" mensuel).
create table if not exists capital_retraits_historique (
  id            uuid primary key default gen_random_uuid(),
  citoyen_id    uuid not null references auth.users(id),
  entreprise_id uuid not null references entreprises(id),
  montant       numeric not null,
  cree_le       timestamptz not null default now()
);
alter table capital_retraits_historique enable row level security;
drop policy if exists "Voir ses propres retraits de capital" on capital_retraits_historique;
create policy "Voir ses propres retraits de capital" on capital_retraits_historique for select
  using (citoyen_id = auth.uid() or est_admin_actuel());

create or replace function capital_retirer_solde(p_entreprise_id uuid)
returns numeric language plpgsql security definer set search_path = public as $$
declare v_solde numeric;
begin
  select solde into v_solde from entreprises_capital_detenteurs
    where entreprise_id = p_entreprise_id and citoyen_id = auth.uid() for update;
  if v_solde is null or v_solde <= 0 then raise exception 'Aucun montant à retirer.'; end if;
  update entreprises_capital_detenteurs set solde = 0 where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  update citoyens set tresorerie = tresorerie + v_solde where id = auth.uid();
  insert into capital_retraits_historique (citoyen_id, entreprise_id, montant) values (auth.uid(), p_entreprise_id, v_solde);
  return v_solde;
end; $$;
grant execute on function capital_retirer_solde(uuid) to authenticated;

-- Détail de l'argent attendu (itemisé, en plus du total citoyens.argent_attendu).
create table if not exists argent_attendu_detail (
  id          uuid primary key default gen_random_uuid(),
  citoyen_id  uuid not null references auth.users(id),
  montant     numeric not null,
  description text not null,
  regle       boolean not null default false,
  cree_le     timestamptz not null default now()
);
alter table argent_attendu_detail enable row level security;
drop policy if exists "Voir son propre détail d'argent attendu" on argent_attendu_detail;
create policy "Voir son propre détail d'argent attendu" on argent_attendu_detail for select
  using (citoyen_id = auth.uid() or est_admin_actuel());

create or replace function _entreprise_gerer_manque_paie(p_entreprise_id uuid, p_citoyen_id uuid, p_montant_du numeric, p_taux_horaire numeric)
returns numeric language plpgsql security definer set search_path = public as $$
declare v_option int; v_couvrable numeric; v_reste numeric; v_cibs text[]; v_cib text;
  v_ent_source uuid; v_dispo numeric; v_pris numeric; v_nom text;
begin
  select option_defaillance into v_option from entreprises where id = p_entreprise_id;
  select nom into v_nom from entreprises where id = p_entreprise_id;

  if v_option = 1 then
    if p_taux_horaire > 200 then v_couvrable := p_montant_du * (200.0 / p_taux_horaire);
    else v_couvrable := p_montant_du; end if;
    update entreprises set dette_salariale_gouv = dette_salariale_gouv + v_couvrable * 1.20 where id = p_entreprise_id;
    if (select dette_salariale_gouv from entreprises where id = p_entreprise_id) > 100000 then
      update entreprises set option_defaillance = 2 where id = p_entreprise_id;
    end if;
    update citoyens set tresorerie = tresorerie + v_couvrable where id = p_citoyen_id;
    v_reste := p_montant_du - v_couvrable;
    if v_reste > 0 then
      update citoyens set argent_attendu = argent_attendu + v_reste where id = p_citoyen_id;
      insert into argent_attendu_detail (citoyen_id, montant, description)
        values (p_citoyen_id, v_reste, 'Salaire différé — ' || coalesce(v_nom, 'entreprise') || ' (trésorerie gouvernementale insuffisante au-delà de 200 R$/h)');
    end if;
    return v_couvrable;

  elsif v_option = 2 then
    update entreprises set tresorerie = tresorerie - p_montant_du,
      dette_salariale_employes = dette_salariale_employes + p_montant_du where id = p_entreprise_id;
    update citoyens set tresorerie = tresorerie + p_montant_du where id = p_citoyen_id;
    return p_montant_du;

  elsif v_option = 3 then
    select option3_cibs into v_cibs from entreprises where id = p_entreprise_id;
    v_reste := p_montant_du;
    foreach v_cib in array coalesce(v_cibs, '{}') loop
      exit when v_reste <= 0;
      select entreprise_id into v_ent_source from entreprises_cib where cib_envoi = v_cib or cib_reception = v_cib;
      if v_ent_source is not null then
        select tresorerie into v_dispo from entreprises where id = v_ent_source for update;
        v_pris := least(v_reste, greatest(0, v_dispo));
        update entreprises set tresorerie = tresorerie - v_pris where id = v_ent_source;
        v_reste := v_reste - v_pris;
      end if;
    end loop;
    if v_reste > 0 then
      update entreprises set tresorerie = tresorerie - v_reste,
        dette_salariale_employes = dette_salariale_employes + v_reste where id = p_entreprise_id;
    end if;
    update citoyens set tresorerie = tresorerie + p_montant_du where id = p_citoyen_id;
    return p_montant_du;

  else
    raise exception 'Trésorerie insuffisante : cette entreprise est en mode manuel uniquement (option 4).';
  end if;
end; $$;

create or replace function mon_argent_attendu()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'total', (select argent_attendu from citoyens where id = auth.uid()),
    'detail', coalesce((select jsonb_agg(jsonb_build_object('montant', montant, 'description', description, 'regle', regle, 'cree_le', cree_le) order by cree_le desc)
      from argent_attendu_detail where citoyen_id = auth.uid()), '[]'::jsonb)
  );
$$;
grant execute on function mon_argent_attendu() to authenticated;

-- Notes au dossier ajoutées par le gouvernement (visibles dans le relevé).
create table if not exists citoyens_notes_dossier (
  id         uuid primary key default gen_random_uuid(),
  citoyen_id uuid not null references auth.users(id),
  auteur_id  uuid not null references auth.users(id),
  note       text not null,
  cree_le    timestamptz not null default now()
);
alter table citoyens_notes_dossier enable row level security;
drop policy if exists "Voir ses notes au dossier ou tout si admin" on citoyens_notes_dossier;
create policy "Voir ses notes au dossier ou tout si admin" on citoyens_notes_dossier for select
  using (citoyen_id = auth.uid() or est_admin_actuel());

create or replace function gouv_ajouter_note_dossier(p_citoyen_username text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  if p_note is null or char_length(trim(p_note)) = 0 then raise exception 'Note requise.'; end if;
  select id into v_id from citoyens where lower(username) = lower(p_citoyen_username);
  if v_id is null then raise exception 'Citoyen introuvable.'; end if;
  insert into citoyens_notes_dossier (citoyen_id, auteur_id, note) values (v_id, auth.uid(), trim(p_note));
end; $$;
grant execute on function gouv_ajouter_note_dossier(text, text) to authenticated;

-- Ventilation des taxes dans les logs de paiement d'employé (exact pour le futur).
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
  v_cho := v_brut * 0.0275; v_ret := v_brut * 0.0675; v_par := v_brut * 0.0025;
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
-- 2) FACTURES MANUELLES (ajoutées pendant le mois, pour la PROCHAINE déclaration)
-- ============================================================
create table if not exists factures_manuelles (
  id                    uuid primary key default gen_random_uuid(),
  citoyen_id            uuid not null references auth.users(id),
  categorie             text not null,
  montant_recu          numeric, montant_envoye numeric,
  taxes_payees_gouv     numeric, taxes_payees_tiers numeric,
  pct_taxes_gouv        numeric, pct_taxes_tiers numeric,
  pourboire_gouv        numeric, pourboire_tiers numeric,
  date_effectuee        date not null,
  paye_en               text check (paye_en in ('liquide','virement')),
  personne_affectee     text, lieux text,
  date_fin              date, date_entree_action date,
  nom_permis            text, cib text,
  signataires_username  text[], signataires_cas text[],
  recompenses           text, formations text,
  note                  text check (char_length(note) <= 1000),
  visible_publiquement  boolean not null default false,
  periode               text not null,
  cree_le               timestamptz not null default now()
);
alter table factures_manuelles enable row level security;
drop policy if exists "Voir ses propres factures manuelles ou tout si admin" on factures_manuelles;
create policy "Voir ses propres factures manuelles ou tout si admin" on factures_manuelles for select
  using (citoyen_id = auth.uid() or est_admin_actuel());

create or replace function ajouter_facture_manuelle(p_categorie text, p_champs jsonb)
returns factures_manuelles language plpgsql security definer set search_path = public as $$
declare v_date date; v_row factures_manuelles;
begin
  if p_categorie is null or char_length(trim(p_categorie)) = 0 then raise exception 'Catégorie requise.'; end if;
  v_date := coalesce((p_champs->>'date_effectuee')::date, current_date);
  if v_date < date_trunc('month', current_date)::date or v_date > current_date then
    raise exception 'La date effectuée doit être dans le mois en cours.';
  end if;
  if (p_champs ? 'date_fin') and (p_champs->>'date_fin') is not null and (p_champs->>'date_fin')::date < v_date then
    raise exception 'La date de fin ne peut précéder la date effectuée.';
  end if;

  insert into factures_manuelles (
    citoyen_id, categorie, montant_recu, montant_envoye, taxes_payees_gouv, taxes_payees_tiers,
    pct_taxes_gouv, pct_taxes_tiers, pourboire_gouv, pourboire_tiers, date_effectuee, paye_en,
    personne_affectee, lieux, date_fin, date_entree_action, nom_permis, cib,
    signataires_username, signataires_cas, recompenses, formations, note, visible_publiquement, periode
  ) values (
    auth.uid(), trim(p_categorie),
    (p_champs->>'montant_recu')::numeric, (p_champs->>'montant_envoye')::numeric,
    (p_champs->>'taxes_payees_gouv')::numeric, (p_champs->>'taxes_payees_tiers')::numeric,
    (p_champs->>'pct_taxes_gouv')::numeric, (p_champs->>'pct_taxes_tiers')::numeric,
    (p_champs->>'pourboire_gouv')::numeric, (p_champs->>'pourboire_tiers')::numeric,
    v_date, p_champs->>'paye_en', p_champs->>'personne_affectee', p_champs->>'lieux',
    nullif(p_champs->>'date_fin','')::date, nullif(p_champs->>'date_entree_action','')::date,
    p_champs->>'nom_permis', p_champs->>'cib',
    case when p_champs->'signataires_username' is not null then array(select jsonb_array_elements_text(p_champs->'signataires_username')) end,
    case when p_champs->'signataires_cas' is not null then array(select jsonb_array_elements_text(p_champs->'signataires_cas')) end,
    p_champs->>'recompenses', p_champs->>'formations', p_champs->>'note',
    coalesce((p_champs->>'visible_publiquement')::boolean, false), to_char(current_date, 'YYYY-MM')
  ) returning * into v_row;
  return v_row;
end; $$;
grant execute on function ajouter_facture_manuelle(text, jsonb) to authenticated;

create or replace function mes_factures_manuelles(p_periode text default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(f.* order by cree_le desc), '[]'::jsonb) from factures_manuelles f
  where citoyen_id = auth.uid() and (p_periode is null or periode = p_periode);
$$;
grant execute on function mes_factures_manuelles(text) to authenticated;

create or replace function supprimer_facture_manuelle(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from factures_manuelles where id = p_id and citoyen_id = auth.uid() and periode = to_char(current_date, 'YYYY-MM');
  if not found then raise exception 'Facture introuvable, déjà déclarée, ou d''un mois passé.'; end if;
end; $$;
grant execute on function supprimer_facture_manuelle(uuid) to authenticated;


-- ============================================================
-- 3) RELEVÉ MENSUEL DU CITOYEN — automatique, 1er du mois, jamais manuel
-- ============================================================
create table if not exists citoyens_releves (
  id         uuid primary key default gen_random_uuid(),
  citoyen_id uuid not null references auth.users(id),
  periode    text not null,
  contenu    jsonb not null,
  cree_le    timestamptz not null default now(),
  unique (citoyen_id, periode)
);
alter table citoyens_releves enable row level security;
drop policy if exists "Voir son propre relevé ou tout si admin" on citoyens_releves;
create policy "Voir son propre relevé ou tout si admin" on citoyens_releves for select
  using (citoyen_id = auth.uid() or est_admin_actuel());

create or replace function _citoyen_generer_releve(p_citoyen_id uuid, p_periode text)
returns citoyens_releves language plpgsql security definer set search_path = public as $$
declare
  c citoyens; v_debut timestamptz; v_fin timestamptz; v_jours numeric;
  v_virements jsonb; v_paiements jsonb; v_entreprises jsonb; v_logs_ent jsonb;
  v_constats_payes jsonb; v_constats_attente jsonb; v_permis jsonb;
  v_confiance jsonb; v_emprunts_gouv jsonb; v_emprunts_civils jsonb; v_emprunts_attente jsonb;
  v_formations jsonb; v_recompenses jsonb; v_capitaux jsonb; v_capital_retraits numeric;
  v_argent_attendu jsonb; v_notes jsonb; v_depots_manuels jsonb; v_factures jsonb;
  v_salaire_ent numeric; v_taxe_rev_ent numeric; v_taxe_prev_ent numeric;
  v_salaire_net_est numeric; v_taxe_rev_est numeric; v_taxe_prev_est numeric;
  v_taxe_rev_cas_est numeric := 0; v_taxe_prev_cas_est numeric := 0;
  v_row citoyens_releves;
begin
  if p_periode !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception 'Période invalide.'; end if;
  v_debut := to_date(p_periode || '-01', 'YYYY-MM-DD')::timestamptz;
  v_fin := v_debut + interval '1 month';
  v_jours := extract(epoch from (least(v_fin, now()) - v_debut)) / 86400.0;
  select * into c from citoyens where id = p_citoyen_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'type', t.type, 'cree_le', t.cree_le, 'montant', t.montant_par_personne, 'total_debite', t.total_debite,
    'expediteur', _nom_partie(t.expediteur_id, t.entreprise_expediteur_id),
    'destinataires', (select coalesce(jsonb_agg(_nom_partie(d, null)), '[]'::jsonb) from unnest(t.destinataires) d),
    'entreprise_destinataire', (select nom from entreprises where id = t.entreprise_destinataire_id)
  ) order by t.cree_le), '[]'::jsonb) into v_virements
  from transferts t where (t.expediteur_id = p_citoyen_id or p_citoyen_id = any(t.destinataires)) and t.cree_le >= v_debut and t.cree_le < v_fin;

  select coalesce(jsonb_agg(jsonb_build_object('type', type, 'montant', montant, 'cree_le', cree_le) order by cree_le), '[]'::jsonb)
    into v_paiements from paiements_historique where citoyen_id = p_citoyen_id and cree_le >= v_debut and cree_le < v_fin;

  select coalesce(jsonb_agg(jsonb_build_object('entreprise', e.nom, 'role', m.role, 'salaire_horaire', m.salaire_horaire,
      'paye_ce_mois', coalesce((select sum((l.donnees->>'montant')::numeric) from entreprises_logs l
        where l.entreprise_id = e.id and l.type = 'paiement_employe' and (l.donnees->>'citoyen_id')::uuid = p_citoyen_id
        and l.cree_le >= v_debut and l.cree_le < v_fin), 0))), '[]'::jsonb),
    coalesce(sum((select sum((l.donnees->>'montant')::numeric) from entreprises_logs l
        where l.entreprise_id = e.id and l.type = 'paiement_employe' and (l.donnees->>'citoyen_id')::uuid = p_citoyen_id
        and l.cree_le >= v_debut and l.cree_le < v_fin)), 0)
    into v_entreprises, v_salaire_ent
  from entreprises_membres m join entreprises e on e.id = m.entreprise_id where m.citoyen_id = p_citoyen_id;

  select coalesce(sum((l.donnees->>'taxe_revenu')::numeric), 0), coalesce(sum((l.donnees->>'taxe_preventive')::numeric), 0)
    into v_taxe_rev_ent, v_taxe_prev_ent
    from entreprises_logs l join entreprises_membres m on m.entreprise_id = l.entreprise_id and m.citoyen_id = p_citoyen_id
    where l.type = 'paiement_employe' and (l.donnees->>'citoyen_id')::uuid = p_citoyen_id and l.cree_le >= v_debut and l.cree_le < v_fin;

  select coalesce(jsonb_agg(entreprise_logs_publics(id)), '[]'::jsonb) into v_logs_ent
    from (select distinct entreprise_id as id from entreprises_membres where citoyen_id = p_citoyen_id) x;

  select coalesce(jsonb_agg(jsonb_build_object('raison', raison, 'prix_total', prix_total, 'paye_le', paye_le)) filter (where paye), '[]'::jsonb),
         coalesce(jsonb_agg(jsonb_build_object('raison', raison, 'prix_total', prix_total, 'cree_le', cree_le)) filter (where not paye), '[]'::jsonb)
    into v_constats_payes, v_constats_attente
    from constats_infraction where destinataire_id = p_citoyen_id and cree_le >= v_debut and cree_le < v_fin;

  select coalesce(jsonb_agg(jsonb_build_object('type', type, 'prix_paye', prix_paye, 'expire_le', expire_le) order by achete_le), '[]'::jsonb)
    into v_permis from permis_citoyens where citoyen_id = p_citoyen_id and achete_le >= v_debut and achete_le < v_fin;

  v_confiance := citoyen_confiance(p_citoyen_id);

  select coalesce(jsonb_agg(jsonb_build_object('montant_demande', montant_demande, 'cree_le', cree_le,
      'montant_rembourse', case when statut = 'rembourse' then montant_du end, 'date_remboursement', rembourse_le,
      'taux', taux_valeur, 'type_taux', type_taux)), '[]'::jsonb) into v_emprunts_gouv
    from citoyens_emprunts_gouv where citoyen_id = p_citoyen_id and statut in ('acceptee','rembourse') and cree_le >= v_debut and cree_le < v_fin;

  select coalesce(jsonb_agg(jsonb_build_object('montant', montant_initial, 'cree_le', cree_le, 'taux', taux_interet,
      'date_limite', date_limite, 'rembourse_le', rembourse_le, 'role', case when preteur_id = p_citoyen_id then 'preteur' else 'emprunteur' end)), '[]'::jsonb)
    into v_emprunts_civils from emprunts where (preteur_id = p_citoyen_id or emprunteur_id = p_citoyen_id) and statut in ('actif','rembourse') and cree_le >= v_debut and cree_le < v_fin;

  select coalesce(jsonb_agg(jsonb_build_object('montant', coalesce(montant_demande, montant_initial), 'statut', statut, 'gouvernemental', (montant_demande is not null))), '[]'::jsonb)
    into v_emprunts_attente from (
      select montant_demande, null::numeric as montant_initial, statut from citoyens_emprunts_gouv where citoyen_id = p_citoyen_id and statut in ('en_attente','refusee')
      union all
      select null, montant_initial, statut from emprunts where emprunteur_id = p_citoyen_id and statut in ('en_attente')
    ) x;

  select coalesce(jsonb_agg(jsonb_build_object('nom', f.nom, 'niveau', f.niveau, 'cree_le', a.cree_le)), '[]'::jsonb) into v_formations
    from aft_attributions a join aft_formations f on f.id = a.formation_id where a.citoyen_id = p_citoyen_id and a.cree_le >= v_debut and a.cree_le < v_fin;

  select coalesce(jsonb_agg(jsonb_build_object('numero_suivi', numero_suivi_meritas, 'donne_le', donne_le)), '[]'::jsonb) into v_recompenses
    from recompenses_attributions where citoyen_id = p_citoyen_id and donne_le >= v_debut and donne_le < v_fin;

  select coalesce(jsonb_agg(jsonb_build_object('entreprise', e.nom, 'pourcentage', d.pourcentage, 'solde', d.solde)), '[]'::jsonb) into v_capitaux
    from entreprises_capital_detenteurs d join entreprises e on e.id = d.entreprise_id where d.citoyen_id = p_citoyen_id;
  select coalesce(sum(montant), 0) into v_capital_retraits from capital_retraits_historique where citoyen_id = p_citoyen_id and cree_le >= v_debut and cree_le < v_fin;

  v_argent_attendu := mon_argent_attendu();

  select coalesce(jsonb_agg(jsonb_build_object('note', note, 'cree_le', cree_le) order by cree_le desc), '[]'::jsonb) into v_notes
    from citoyens_notes_dossier where citoyen_id = p_citoyen_id;

  select coalesce(jsonb_agg(jsonb_build_object('entreprise', e.nom, 'periode', d.periode, 'cree_le', d.cree_le)), '[]'::jsonb) into v_depots_manuels
    from entreprises_depots_impots d join entreprises e on e.id = d.entreprise_id
    where d.depose_par = p_citoyen_id and d.type in ('manuel','assiste') and d.cree_le >= v_debut and d.cree_le < v_fin;

  select coalesce(jsonb_agg(row_to_json(f) order by f.cree_le) filter (where f.visible_publiquement), '[]'::jsonb)
    into v_factures from factures_manuelles f where f.citoyen_id = p_citoyen_id and f.periode = to_char(v_debut, 'YYYY-MM');
  select coalesce(sum(taxes_payees_gouv), 0), coalesce(sum(taxes_payees_tiers), 0)
    into v_taxe_rev_est, v_taxe_prev_est
    from factures_manuelles where citoyen_id = p_citoyen_id and periode = to_char(v_debut, 'YYYY-MM');

  -- Estimation du revenu de base (CAS) sur la période, faute de journal détaillé (voir HYPOTHÈSE).
  declare v_brut_cas_est numeric; v_prev_taux numeric;
  begin
    select taux_preventif into v_prev_taux from parametres_fiscaux where id = 1;
    v_brut_cas_est := coalesce(c.salaire, 0) * 60 * 24 * v_jours;
    v_taxe_rev_cas_est := round(v_brut_cas_est * coalesce(c.taux_revenu, 0) / 100.0, 2);
    v_taxe_prev_cas_est := round(v_brut_cas_est * coalesce(v_prev_taux, 0) / 100.0, 2);
    v_salaire_net_est := round(v_brut_cas_est * (1 - coalesce(c.taux_revenu, 0) / 100.0 - coalesce(v_prev_taux, 0) / 100.0 - 0.02), 2);
  end;

  insert into citoyens_releves (citoyen_id, periode, contenu)
  values (p_citoyen_id, p_periode, jsonb_build_object(
    'genere_le', now(), 'periode', p_periode,
    'virements', v_virements, 'paiements', v_paiements,
    'entreprises', v_entreprises, 'salaire_entreprises_mois', v_salaire_ent,
    'logs_entreprises', v_logs_ent,
    'constats_payes', v_constats_payes, 'constats_en_attente', v_constats_attente,
    'permis_achetes', v_permis,
    'compte_chomage', c.compte_chomage, 'compte_retraite', c.compte_retraite, 'compte_parentalite', c.compte_parentalite,
    'tresorerie', c.tresorerie, 'dettes', c.dettes, 'prets', c.prets,
    'contribution_gouvernement_estimee', round(v_taxe_rev_ent + v_taxe_prev_ent + v_taxe_rev_cas_est + v_taxe_prev_cas_est, 2),
    'taxe_revenu_entreprises', v_taxe_rev_ent, 'taxe_preventive_entreprises', v_taxe_prev_ent,
    'taxe_revenu_cas_estimee', v_taxe_rev_cas_est, 'taxe_preventive_cas_estimee', v_taxe_prev_cas_est,
    'taxe_pourcentage', c.taux_revenu, 'salaire_net_cas_estime', v_salaire_net_est,
    'taxes_ajout_manuel_gouv', v_taxe_rev_est, 'taxes_ajout_manuel_tiers', v_taxe_prev_est,
    'demandes_epargne_mois', (select coalesce(jsonb_agg(jsonb_build_object('type', type, 'statut', statut, 'cree_le', cree_le)), '[]'::jsonb)
      from demandes_epargne where citoyen_id = p_citoyen_id and cree_le >= v_debut and cree_le < v_fin),
    'confiance', v_confiance,
    'emprunts_gouvernement', v_emprunts_gouv, 'emprunts_civils', v_emprunts_civils, 'emprunts_en_attente_ou_refuses', v_emprunts_attente,
    'formations_obtenues', v_formations, 'recompenses_obtenues', v_recompenses,
    'capitaux_possedes', v_capitaux, 'capital_retire_mois', v_capital_retraits,
    'argent_attendu', v_argent_attendu,
    'relevés_entreprises_manuels', v_depots_manuels,
    'notes_au_dossier', v_notes,
    'factures_manuelles_visibles', v_factures
  ))
  on conflict (citoyen_id, periode) do update set contenu = excluded.contenu
  returning * into v_row;
  return v_row;
end; $$;

create or replace function citoyens_rattraper_releves()
returns int language plpgsql security definer set search_path = public as $$
declare v_n int := 0; v_periode text; v_c record;
begin
  v_periode := to_char(current_date - interval '1 month', 'YYYY-MM');
  for v_c in select id from citoyens where cree_le < date_trunc('month', now())
    and not exists (select 1 from citoyens_releves r where r.citoyen_id = citoyens.id and r.periode = v_periode) loop
    perform _citoyen_generer_releve(v_c.id, v_periode);
    v_n := v_n + 1;
  end loop;
  return v_n;
end; $$;
grant execute on function citoyens_rattraper_releves() to authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('citoyens-releves-auto', '10 0 1 * *', 'select public.citoyens_rattraper_releves()');
  end if;
exception when others then null;
end $$;

-- Consultation : soi-même (tout) ou public par nom d'utilisateur (caviardé, sauf admin).
create or replace function mon_releve(p_periode text)
returns jsonb language sql stable security definer set search_path = public as $$
  select contenu from citoyens_releves where citoyen_id = auth.uid() and periode = p_periode;
$$;
grant execute on function mon_releve(text) to authenticated;

create or replace function mes_periodes_releves()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(periode order by periode desc), '[]'::jsonb) from citoyens_releves where citoyen_id = auth.uid();
$$;
grant execute on function mes_periodes_releves() to authenticated;

create or replace function releve_citoyen_public(p_username text, p_periode text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_id uuid; v_contenu jsonb;
begin
  select id into v_id from citoyens where lower(username) = lower(trim(p_username));
  if v_id is null then raise exception 'Citoyen introuvable.'; end if;
  select contenu into v_contenu from citoyens_releves where citoyen_id = v_id and periode = p_periode;
  if v_contenu is null then raise exception 'Aucun relevé pour cette période.'; end if;
  if est_admin_actuel() then return jsonb_build_object('username', p_username) || v_contenu; end if;
  -- Aucun CAS ni CIB (personnel ou d'envoi d'entreprise) n'apparaît dans les
  -- champs construits ci-dessus ; on retire par prudence tout champ "cib" imbriqué.
  return jsonb_build_object('username', p_username) || (v_contenu - 'notes_au_dossier');
end; $$;
grant execute on function releve_citoyen_public(text, text) to authenticated, anon;

-- ============================================================
-- FIN
-- ============================================================
