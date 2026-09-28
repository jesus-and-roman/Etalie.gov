-- ============================================================
-- patch-cib-entreprise-avancee-2.sql
-- À exécuter APRÈS patch-cib-entreprise-avancee.sql. Additif et rejouable.
--
--  1. CIB PRIVÉS : les CIB des entreprises et des employés quittent les
--     tables lisibles publiquement (entreprises / entreprises_membres,
--     dont la lecture était ouverte à tous) et vont dans des tables
--     SANS aucune politique de lecture, accessibles seulement par des
--     fonctions. Migration des données existantes + CIB aléatoire pour
--     toutes les entreprises qui n'en avaient pas. Un CIB n'est généré
--     que s'il n'est pris par aucun utilisateur ni aucune entreprise.
--  2. Voir le CIB d'un employé : PDG seulement, mot de passe du PDG
--     vérifié CÔTÉ SERVEUR (5 échecs max / 10 min).
--  3. Demandes de changement de CIB (fuite) pour citoyens et entreprises.
--  4. Emprunts au gouvernement avec négociation (rectification /
--     contre-demande, dans les deux sens, jusqu'à accord ou refus).
--  5. Capital : vente au gouvernement (négociable), marché public avec
--     descriptions (3000 car. entreprise, 500 car. tiers), partage des
--     entrées d'argent au prorata du capital, retrait vers la trésorerie
--     personnelle, "mes capitaux".
--  6. Rapports d'impôts : période = MOIS PRÉCÉDENT, à déposer le 1er ;
--     le 2, rapport automatique pour ceux qui ne l'ont pas fait (pg_cron
--     si disponible, sinon rattrapage à la connexion de n'importe quel
--     citoyen). Nouveau mode "assisté par les logs" (champs préremplis).
--  7. Logs consultables (publics) ; infos personnelles corrigées
--     (salaire brut = CAS + toutes les entreprises, taxes, net).
--
-- HYPOTHÈSES :
--  - Le partage au prorata du capital s'applique à TOUT ce qui augmente
--    la trésorerie (trigger), SAUF : emprunts au gouvernement, vente de
--    capital (au gouvernement, au public) — ce n'est pas du profit.
--  - Capital de tiers : vendu par tranches de 0,1 %, prix fixé PAR 0,1 %.
--    Capital de l'entreprise : prix fixé PAR 0,01 %.
--  - Le gouvernement paie emprunts et rachats de capital avec la
--    trésorerie publique (tresor_public.solde) ; refus si insuffisante.
--  - Le CIB d'un citoyen vient de num_CAS.txt (synchronisé à la connexion
--    par enregistrer_mon_cib) ; un changement approuvé devient la valeur
--    de référence en base et remplace celle du fichier.
--  - pgcrypto : la vérification du mot de passe utilise extensions.crypt
--    (schéma standard de Supabase).
-- ============================================================


-- ============================================================
-- 0) VÉRIFICATION DU MOT DE PASSE (serveur) + drapeau de partage
-- ============================================================
create table if not exists tentatives_mdp (
  id uuid primary key default gen_random_uuid(),
  citoyen_id uuid not null,
  cree_le timestamptz not null default now()
);
alter table tentatives_mdp enable row level security;  -- aucune politique : inaccessible

create or replace function _verifier_mdp(p_mdp text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_ok boolean;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if (select count(*) from tentatives_mdp where citoyen_id = auth.uid() and cree_le > now() - interval '10 minutes') >= 5 then
    raise exception 'Trop de tentatives échouées : réessayez dans 10 minutes.';
  end if;
  select (u.encrypted_password = extensions.crypt(p_mdp, u.encrypted_password)) into v_ok
    from auth.users u where u.id = auth.uid();
  if not coalesce(v_ok, false) then
    insert into tentatives_mdp (citoyen_id) values (auth.uid());
    return false;
  end if;
  return true;
end; $$;

create or replace function _sans_partage(p_actif boolean)
returns void language plpgsql as $$
begin
  perform set_config('app.sans_partage_capital', case when p_actif then '1' else '0' end, true);
end; $$;


-- ============================================================
-- 1) CIB PRIVÉS — tables secrètes + migration
-- ============================================================
create table if not exists entreprises_cib (
  entreprise_id uuid primary key references entreprises(id) on delete cascade,
  cib_impots    text not null unique,
  cib_reception text not null unique,
  cib_envoi     text not null unique
);
alter table entreprises_cib enable row level security;   -- aucune politique

create table if not exists entreprises_membres_cib (
  entreprise_id uuid not null references entreprises(id) on delete cascade,
  citoyen_id    uuid not null references auth.users(id) on delete cascade,
  cib           text not null,
  primary key (entreprise_id, citoyen_id)
);
alter table entreprises_membres_cib enable row level security;   -- aucune politique

-- CIB personnels des citoyens (fichier CAS + changements approuvés) et
-- CIB déjà attribués (y compris anciens/fuités) : jamais réutilisés.
create table if not exists cib_reserves (
  cib              text primary key,
  code_encrypte    text,
  origine          text not null default 'fichier_cas',
  actif            boolean not null default true,
  remplace_fichier boolean not null default false,
  cree_le          timestamptz not null default now()
);
create index if not exists cib_reserves_code_idx on cib_reserves (code_encrypte);
alter table cib_reserves enable row level security;   -- aucune politique

create or replace function _cib_existe(p_cib text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from cib_reserves where cib = p_cib)
      or exists (select 1 from entreprises_cib where p_cib in (cib_impots, cib_reception, cib_envoi));
$$;

-- Vérifie qu'aucun utilisateur ni aucune entreprise n'a déjà ce CIB.
create or replace function _generer_cib()
returns text language plpgsql security definer set search_path = public as $$
declare v_code text;
begin
  loop
    v_code := '0R-0' || lpad(floor(random() * 100000000000)::text, 11, '0');
    exit when not _cib_existe(v_code);
  end loop;
  return v_code;
end; $$;

create or replace function _creer_cib_entreprise(p_entreprise_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into entreprises_cib (entreprise_id, cib_impots, cib_reception, cib_envoi)
    values (p_entreprise_id, _generer_cib(), _generer_cib(), _generer_cib())
    on conflict (entreprise_id) do nothing;
end; $$;

-- Migration : copie des anciennes colonnes, CIB aléatoires pour le reste,
-- puis suppression des colonnes lisibles publiquement.
do $$
declare v_e record;
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'entreprises' and column_name = 'cib_impots') then
    execute $q$insert into entreprises_cib (entreprise_id, cib_impots, cib_reception, cib_envoi)
      select id, cib_impots, cib_reception, cib_envoi from entreprises
      where cib_impots is not null and cib_reception is not null and cib_envoi is not null
      on conflict (entreprise_id) do nothing$q$;
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'entreprises_membres' and column_name = 'cib') then
    execute $q$insert into entreprises_membres_cib (entreprise_id, citoyen_id, cib)
      select entreprise_id, citoyen_id, cib from entreprises_membres where cib is not null
      on conflict do nothing$q$;
  end if;
  -- Entreprises créées avant l'ajout du CIB (ou avec un jeu incomplet)
  for v_e in select id from entreprises e where not exists (select 1 from entreprises_cib c where c.entreprise_id = e.id) loop
    perform _creer_cib_entreprise(v_e.id);
  end loop;
end $$;

alter table entreprises drop column if exists cib_impots;
alter table entreprises drop column if exists cib_reception;
alter table entreprises drop column if exists cib_envoi;
alter table entreprises_membres drop column if exists cib;

-- Synchronise le CIB du fichier CAS pour le citoyen connecté ; renvoie
-- le CIB effectif (un changement approuvé l'emporte sur le fichier).
create or replace function enregistrer_mon_cib(p_cib_fichier text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_code text; v_actuel text; v_force text;
begin
  select code_social_encrypte into v_code from citoyens where id = auth.uid();
  if v_code is null then raise exception 'Non authentifié.'; end if;

  select cib into v_force from cib_reserves where code_encrypte = v_code and actif and remplace_fichier limit 1;
  if v_force is not null then return v_force; end if;

  select cib into v_actuel from cib_reserves where code_encrypte = v_code and actif limit 1;
  if p_cib_fichier is null or p_cib_fichier !~ '^0R-0[0-9]+$' then return v_actuel; end if;
  if v_actuel = p_cib_fichier then return v_actuel; end if;

  if exists (select 1 from entreprises_cib where p_cib_fichier in (cib_impots, cib_reception, cib_envoi))
     or exists (select 1 from cib_reserves where cib = p_cib_fichier and code_encrypte is distinct from v_code) then
    raise exception 'Ce CIB est déjà attribué : contactez le gouvernement.';
  end if;
  if v_actuel is not null then update cib_reserves set actif = false where cib = v_actuel; end if;
  insert into cib_reserves (cib, code_encrypte, origine) values (p_cib_fichier, v_code, 'fichier_cas')
    on conflict (cib) do update set actif = true;
  return p_cib_fichier;
end; $$;
grant execute on function enregistrer_mon_cib(text) to authenticated;

create or replace function _valider_cib_employe(p_citoyen_id uuid, p_cib text)
returns void language plpgsql security definer set search_path = public as $$
declare v_code text; v_attendu text;
begin
  if p_cib !~ '^0R-0[0-9]+$' then raise exception 'Format de CIB invalide (0R-0 suivi de chiffres).'; end if;
  select code_social_encrypte into v_code from citoyens where id = p_citoyen_id;
  select cib into v_attendu from cib_reserves where code_encrypte = v_code and actif order by remplace_fichier desc limit 1;
  if v_attendu is not null and v_attendu <> p_cib then
    raise exception 'Ce CIB ne correspond pas à cet employé.';
  end if;
end; $$;

create or replace function entreprise_ajouter_employe(p_entreprise_id uuid, p_cas text, p_salaire_horaire numeric, p_cib text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_cib text;
begin
  perform _exige_droit(p_entreprise_id, 'ajouter_employe');
  if p_salaire_horaire < 18 then raise exception 'Le salaire doit être au moins le salaire minimum (18 R$/heure).'; end if;
  select id into v_id from citoyens where code_social_encrypte = p_cas;
  if v_id is null then raise exception 'Code d''assurance social introuvable.'; end if;
  v_cib := nullif(trim(coalesce(p_cib, '')), '');
  if v_cib is not null then perform _valider_cib_employe(v_id, v_cib); end if;
  insert into entreprises_membres (entreprise_id, citoyen_id, role, salaire_horaire)
    values (p_entreprise_id, v_id, 'employe', p_salaire_horaire)
    on conflict (entreprise_id, citoyen_id) do update set salaire_horaire = p_salaire_horaire;
  if v_cib is not null then
    insert into entreprises_membres_cib (entreprise_id, citoyen_id, cib) values (p_entreprise_id, v_id, v_cib)
      on conflict (entreprise_id, citoyen_id) do update set cib = excluded.cib;
  end if;
end; $$;
grant execute on function entreprise_ajouter_employe(uuid, text, numeric, text) to authenticated;

create or replace function entreprise_definir_cib_membre(p_entreprise_id uuid, p_citoyen_id uuid, p_cib text)
returns void language plpgsql security definer set search_path = public as $$
declare v_cib text;
begin
  perform _exige_droit(p_entreprise_id, 'ajouter_employe');
  if not exists (select 1 from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = p_citoyen_id) then
    raise exception 'Membre introuvable.';
  end if;
  v_cib := nullif(trim(coalesce(p_cib, '')), '');
  if v_cib is null then
    delete from entreprises_membres_cib where entreprise_id = p_entreprise_id and citoyen_id = p_citoyen_id;
  else
    perform _valider_cib_employe(p_citoyen_id, v_cib);
    insert into entreprises_membres_cib (entreprise_id, citoyen_id, cib) values (p_entreprise_id, p_citoyen_id, v_cib)
      on conflict (entreprise_id, citoyen_id) do update set cib = excluded.cib;
  end if;
end; $$;
grant execute on function entreprise_definir_cib_membre(uuid, uuid, text) to authenticated;

-- Révélation du CIB d'un employé : PDG + mot de passe du PDG (serveur).
create or replace function entreprise_voir_cib_membre(p_entreprise_id uuid, p_citoyen_id uuid, p_mdp text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_role text; v_cib text;
begin
  select role into v_role from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_role is distinct from 'pdg' then raise exception 'Réservé au PDG.'; end if;
  if not _verifier_mdp(p_mdp) then return jsonb_build_object('ok', false); end if;
  select cib into v_cib from entreprises_membres_cib where entreprise_id = p_entreprise_id and citoyen_id = p_citoyen_id;
  return jsonb_build_object('ok', true, 'cib', v_cib);
end; $$;
grant execute on function entreprise_voir_cib_membre(uuid, uuid, text) to authenticated;

create or replace function entreprise_mes_cib(p_entreprise_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_c entreprises_cib; v_role text; v_res jsonb := '{}'::jsonb;
begin
  select * into v_c from entreprises_cib where entreprise_id = p_entreprise_id;
  if v_c.entreprise_id is null then raise exception 'Entreprise introuvable.'; end if;
  select role into v_role from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_role is null and not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  if _entreprise_a_droit(p_entreprise_id, 'voir_cib_impots') then v_res := v_res || jsonb_build_object('cib_impots', v_c.cib_impots); end if;
  if _entreprise_a_droit(p_entreprise_id, 'voir_cib_reception') then v_res := v_res || jsonb_build_object('cib_reception', v_c.cib_reception); end if;
  if _entreprise_a_droit(p_entreprise_id, 'voir_cib_envoi') then v_res := v_res || jsonb_build_object('cib_envoi', v_c.cib_envoi); end if;
  return v_res;
end; $$;
grant execute on function entreprise_mes_cib(uuid) to authenticated;

create or replace function entreprise_demander(
  p_nom text, p_depenses numeric, p_achats numeric,
  p_type_vente text, p_mode_vente text, p_boutique_principale text, p_boutiques_secondaires text,
  p_sieges text, p_fondateur_cas text, p_employes jsonb default '[]'::jsonb
) returns public.entreprises language plpgsql security definer set search_path = public as $$
declare v_row public.entreprises; v_emp jsonb; v_emp_id uuid;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if p_nom is null or char_length(trim(p_nom)) = 0 then raise exception 'Nom d''entreprise requis.'; end if;
  if p_sieges is null or char_length(trim(p_sieges)) = 0 then raise exception 'Au moins un siège physique est requis.'; end if;

  insert into entreprises (code, nom, depenses_an_dernier, achats_an_dernier, type_vente, mode_vente,
    boutique_principale, boutiques_secondaires, sieges, fondateur_id, fondateur_cas)
  values ('E-' || _generer_code_alnum(8), p_nom, p_depenses, p_achats, p_type_vente, p_mode_vente,
    p_boutique_principale, p_boutiques_secondaires, p_sieges, auth.uid(), p_fondateur_cas)
  returning * into v_row;
  perform _creer_cib_entreprise(v_row.id);

  for v_emp in select * from jsonb_array_elements(coalesce(p_employes, '[]'::jsonb)) loop
    select id into v_emp_id from citoyens where code_social_encrypte = (v_emp->>'cas');
    if v_emp_id is not null then
      insert into entreprises_membres (entreprise_id, citoyen_id, role) values (v_row.id, v_emp_id, 'employe')
        on conflict do nothing;
    end if;
  end loop;
  return v_row;
end; $$;
grant execute on function entreprise_demander(text,numeric,numeric,text,text,text,text,text,text,jsonb) to authenticated;

create or replace function virement_vers_entreprise(p_cib text, p_montant numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_ent_id uuid; v_tresor numeric;
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select c.entreprise_id into v_ent_id from entreprises_cib c join entreprises e on e.id = c.entreprise_id
    where c.cib_reception = p_cib and e.statut = 'acceptee';
  if v_ent_id is null then raise exception 'CIB de réception introuvable.'; end if;
  select tresorerie into v_tresor from citoyens where id = auth.uid() for update;
  if v_tresor < p_montant then raise exception 'Trésorerie insuffisante.'; end if;

  update citoyens set tresorerie = tresorerie - p_montant where id = auth.uid();
  update entreprises set tresorerie = tresorerie + p_montant where id = v_ent_id;
  perform _entreprise_regler_dette_employes(v_ent_id);
  perform _entreprise_log(v_ent_id, 'ajout_fonds', jsonb_build_object('citoyen_id', auth.uid(), 'montant', p_montant));
end; $$;
grant execute on function virement_vers_entreprise(text, numeric) to authenticated;

create or replace function entreprise_virement_vers_entreprise(p_entreprise_id uuid, p_cib_dest text, p_montant numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_dest_id uuid; v_nom_dest text; v_tresor numeric;
begin
  perform _exige_droit(p_entreprise_id, 'virement_inter_entreprise');
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select e.id, e.nom into v_dest_id, v_nom_dest from entreprises_cib c join entreprises e on e.id = c.entreprise_id
    where c.cib_reception = p_cib_dest and e.statut = 'acceptee';
  if v_dest_id is null then raise exception 'CIB de réception introuvable.'; end if;
  if v_dest_id = p_entreprise_id then raise exception 'Impossible de se virer à soi-même.'; end if;

  select tresorerie into v_tresor from entreprises where id = p_entreprise_id for update;
  if v_tresor < p_montant then raise exception 'Trésorerie insuffisante.'; end if;
  update entreprises set tresorerie = tresorerie - p_montant where id = p_entreprise_id;
  update entreprises set tresorerie = tresorerie + p_montant where id = v_dest_id;
  perform _entreprise_regler_dette_employes(v_dest_id);
  perform _entreprise_log(p_entreprise_id, 'virement_entreprise',
    jsonb_build_object('entreprise_dest_nom', v_nom_dest, 'entreprise_dest_id', v_dest_id, 'montant', p_montant));
end; $$;
grant execute on function entreprise_virement_vers_entreprise(uuid, text, numeric) to authenticated;

-- Option 3 de défaillance : source identifiée par CIB (envoi ou réception).
create or replace function _entreprise_gerer_manque_paie(p_entreprise_id uuid, p_citoyen_id uuid, p_montant_du numeric, p_taux_horaire numeric)
returns numeric language plpgsql security definer set search_path = public as $$
declare v_option int; v_couvrable numeric; v_reste numeric; v_cibs text[]; v_cib text;
  v_ent_source uuid; v_dispo numeric; v_pris numeric;
begin
  select option_defaillance into v_option from entreprises where id = p_entreprise_id;

  if v_option = 1 then
    if p_taux_horaire > 200 then v_couvrable := p_montant_du * (200.0 / p_taux_horaire);
    else v_couvrable := p_montant_du; end if;
    update entreprises set dette_salariale_gouv = dette_salariale_gouv + v_couvrable * 1.20 where id = p_entreprise_id;
    if (select dette_salariale_gouv from entreprises where id = p_entreprise_id) > 100000 then
      update entreprises set option_defaillance = 2 where id = p_entreprise_id;
    end if;
    update citoyens set tresorerie = tresorerie + v_couvrable where id = p_citoyen_id;
    v_reste := p_montant_du - v_couvrable;
    if v_reste > 0 then update citoyens set argent_attendu = argent_attendu + v_reste where id = p_citoyen_id; end if;
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


-- ============================================================
-- 2) DEMANDES DE CHANGEMENT DE CIB (fuite)
-- ============================================================
create table if not exists demandes_changement_cib (
  id            uuid primary key default gen_random_uuid(),
  demandeur_id  uuid not null references auth.users(id),
  cible         text not null check (cible in ('citoyen','entreprise')),
  entreprise_id uuid references entreprises(id),
  champ         text check (champ in ('impots','reception','envoi')),
  motif         text not null,
  statut        text not null default 'en_attente' check (statut in ('en_attente','acceptee','refusee')),
  cree_le       timestamptz not null default now(),
  traite_le     timestamptz
);
alter table demandes_changement_cib enable row level security;
drop policy if exists "Voir ses demandes de changement de CIB" on demandes_changement_cib;
create policy "Voir ses demandes de changement de CIB" on demandes_changement_cib for select
  using (demandeur_id = auth.uid() or est_admin_actuel());

create or replace function demander_changement_cib_citoyen(p_motif text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_motif is null or char_length(trim(p_motif)) < 10 then raise exception 'Expliquez la situation (10 caractères minimum).'; end if;
  if exists (select 1 from demandes_changement_cib where demandeur_id = auth.uid() and cible = 'citoyen' and statut = 'en_attente') then
    raise exception 'Une demande est déjà en attente.';
  end if;
  insert into demandes_changement_cib (demandeur_id, cible, motif) values (auth.uid(), 'citoyen', trim(p_motif));
end; $$;
grant execute on function demander_changement_cib_citoyen(text) to authenticated;

create or replace function demander_changement_cib_entreprise(p_entreprise_id uuid, p_champ text, p_motif text)
returns void language plpgsql security definer set search_path = public as $$
declare v_role text;
begin
  select role into v_role from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_role is distinct from 'pdg' then raise exception 'Réservé au PDG.'; end if;
  if p_champ not in ('impots','reception','envoi') then raise exception 'CIB inconnu.'; end if;
  if p_motif is null or char_length(trim(p_motif)) < 10 then raise exception 'Expliquez la situation (10 caractères minimum).'; end if;
  if exists (select 1 from demandes_changement_cib where entreprise_id = p_entreprise_id and champ = p_champ and statut = 'en_attente') then
    raise exception 'Une demande est déjà en attente pour ce CIB.';
  end if;
  insert into demandes_changement_cib (demandeur_id, cible, entreprise_id, champ, motif)
    values (auth.uid(), 'entreprise', p_entreprise_id, p_champ, trim(p_motif));
end; $$;
grant execute on function demander_changement_cib_entreprise(uuid, text, text) to authenticated;

create or replace function mes_demandes_changement_cib()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'cible', d.cible, 'entreprise', e.nom, 'champ', d.champ,
    'motif', d.motif, 'statut', d.statut, 'cree_le', d.cree_le) order by d.cree_le desc), '[]'::jsonb)
  from demandes_changement_cib d left join entreprises e on e.id = d.entreprise_id where d.demandeur_id = auth.uid();
$$;
grant execute on function mes_demandes_changement_cib() to authenticated;

create or replace function gouv_liste_demandes_cib()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not est_admin_actuel() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
    'id', d.id, 'cible', d.cible, 'entreprise', e.nom, 'champ', d.champ, 'motif', d.motif,
    'demandeur', c.username, 'cree_le', d.cree_le) order by d.cree_le), '[]'::jsonb) end
  from demandes_changement_cib d join citoyens c on c.id = d.demandeur_id
  left join entreprises e on e.id = d.entreprise_id where d.statut = 'en_attente';
$$;
grant execute on function gouv_liste_demandes_cib() to authenticated;

create or replace function gouv_traiter_demande_cib(p_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
declare d demandes_changement_cib; v_old text; v_new text; v_code text;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if p_decision not in ('acceptee','refusee') then raise exception 'Décision invalide.'; end if;
  select * into d from demandes_changement_cib where id = p_id and statut = 'en_attente' for update;
  if d.id is null then raise exception 'Demande introuvable ou déjà traitée.'; end if;

  if p_decision = 'acceptee' then
    v_new := _generer_cib();
    if d.cible = 'entreprise' then
      select case d.champ when 'impots' then cib_impots when 'reception' then cib_reception else cib_envoi end
        into v_old from entreprises_cib where entreprise_id = d.entreprise_id;
      update entreprises_cib set
        cib_impots = case when d.champ = 'impots' then v_new else cib_impots end,
        cib_reception = case when d.champ = 'reception' then v_new else cib_reception end,
        cib_envoi = case when d.champ = 'envoi' then v_new else cib_envoi end
        where entreprise_id = d.entreprise_id;
      insert into cib_reserves (cib, origine, actif) values (v_old, 'ancien_entreprise', false) on conflict do nothing;
    else
      select code_social_encrypte into v_code from citoyens where id = d.demandeur_id;
      update cib_reserves set actif = false where code_encrypte = v_code and actif;
      insert into cib_reserves (cib, code_encrypte, origine, actif, remplace_fichier)
        values (v_new, v_code, 'changement_approuve', true, true);
      -- les employeurs devront re-saisir le nouveau CIB
      delete from entreprises_membres_cib where citoyen_id = d.demandeur_id;
    end if;
  end if;
  update demandes_changement_cib set statut = p_decision, traite_le = now() where id = p_id;
end; $$;
grant execute on function gouv_traiter_demande_cib(uuid, text) to authenticated;


-- ============================================================
-- 3) CAPITAL : détenteurs, partage des entrées d'argent, retrait
-- ============================================================
alter table entreprises_capital_detenteurs alter column citoyen_id drop not null;
alter table entreprises_capital_detenteurs add column if not exists est_gouvernement boolean not null default false;
alter table entreprises_capital_detenteurs add column if not exists solde numeric not null default 0;
create unique index if not exists capital_detenteur_gouv_unique on entreprises_capital_detenteurs (entreprise_id) where est_gouvernement;

-- Le solde accumulé de chacun est privé (l'info publique passe par entreprise_capital_public).
drop policy if exists "Lecture publique des détenteurs de capital" on entreprises_capital_detenteurs;
drop policy if exists "Lecture de ses propres capitaux" on entreprises_capital_detenteurs;
create policy "Lecture de ses propres capitaux" on entreprises_capital_detenteurs for select
  using (citoyen_id = auth.uid() or est_admin_actuel());

-- Tout ce qui fait AUGMENTER la trésorerie d'une entreprise est partagé au
-- prorata du capital détenu par des tiers (gouvernement -> trésorerie publique).
create or replace function _entreprise_repartir_capital()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_delta numeric; v_tiers numeric; v_d record;
begin
  if coalesce(current_setting('app.sans_partage_capital', true), '0') = '1' then return new; end if;
  v_delta := new.tresorerie - old.tresorerie;
  select coalesce(sum(pourcentage), 0) into v_tiers from entreprises_capital_detenteurs where entreprise_id = new.id;
  if v_tiers <= 0 then return new; end if;
  for v_d in select id, pourcentage, est_gouvernement from entreprises_capital_detenteurs where entreprise_id = new.id loop
    if v_d.est_gouvernement then
      update tresor_public set solde = solde + v_delta * v_d.pourcentage / 100.0 where id = 1;
    else
      update entreprises_capital_detenteurs set solde = solde + v_delta * v_d.pourcentage / 100.0 where id = v_d.id;
    end if;
  end loop;
  new.tresorerie := old.tresorerie + v_delta * (1 - v_tiers / 100.0);
  return new;
end; $$;
drop trigger if exists trg_repartir_capital on entreprises;
create trigger trg_repartir_capital before update of tresorerie on entreprises
  for each row when (new.tresorerie > old.tresorerie) execute function _entreprise_repartir_capital();

create or replace function capital_retirer_solde(p_entreprise_id uuid)
returns numeric language plpgsql security definer set search_path = public as $$
declare v_solde numeric;
begin
  select solde into v_solde from entreprises_capital_detenteurs
    where entreprise_id = p_entreprise_id and citoyen_id = auth.uid() for update;
  if v_solde is null or v_solde <= 0 then raise exception 'Aucun montant à retirer.'; end if;
  update entreprises_capital_detenteurs set solde = 0 where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  update citoyens set tresorerie = tresorerie + v_solde where id = auth.uid();
  return v_solde;
end; $$;
grant execute on function capital_retirer_solde(uuid) to authenticated;

alter table entreprises add column if not exists capital_description text check (char_length(capital_description) <= 3000);

create or replace function entreprise_capital_public(p_entreprise_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'en_vente_pct', e.capital_en_vente_pct, 'max_par_individu', e.capital_max_par_individu,
    'prix_par_centieme', e.capital_prix_par_centieme, 'min_achat_pct', e.capital_min_achat_pct,
    'description', e.capital_description,
    'detenteurs', coalesce((select jsonb_agg(jsonb_build_object(
        'username', case when d.est_gouvernement then 'gouvernement' else c.username end, 'pourcentage', d.pourcentage))
      from entreprises_capital_detenteurs d left join citoyens c on c.id = d.citoyen_id where d.entreprise_id = e.id), '[]'::jsonb)
  )
  from entreprises e where e.id = p_entreprise_id;
$$;
grant execute on function entreprise_capital_public(uuid) to authenticated, anon;

-- ---- Offre de l'entreprise au public (description 3000 car.) ----

drop function if exists entreprise_mettre_capital_en_vente(uuid, numeric, numeric, numeric, numeric);
create or replace function entreprise_mettre_capital_en_vente(p_entreprise_id uuid, p_pourcentage numeric, p_max_par_individu numeric, p_prix_par_centieme numeric, p_min_achat_pct numeric default 0.01, p_description text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_deja_vendu numeric;
begin
  perform _exige_droit(p_entreprise_id, 'vendre_capital');
  if p_pourcentage < 0 or p_pourcentage > 100 then raise exception 'Pourcentage invalide.'; end if;
  if p_description is not null and char_length(p_description) > 3000 then raise exception 'Description limitée à 3000 caractères.'; end if;
  select coalesce(sum(pourcentage), 0) into v_deja_vendu from entreprises_capital_detenteurs where entreprise_id = p_entreprise_id;
  if p_pourcentage + v_deja_vendu > 100 then raise exception 'Le total des capitaux vendus dépasserait 100 %%.'; end if;
  update entreprises set capital_en_vente_pct = p_pourcentage, capital_max_par_individu = p_max_par_individu,
    capital_prix_par_centieme = p_prix_par_centieme, capital_min_achat_pct = coalesce(p_min_achat_pct, 0.01),
    capital_description = nullif(trim(coalesce(p_description, '')), '')
    where id = p_entreprise_id;
end; $$;
grant execute on function entreprise_mettre_capital_en_vente(uuid, numeric, numeric, numeric, numeric, text) to authenticated;

create or replace function entreprise_acheter_capital(p_entreprise_id uuid, p_pourcentage numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_ent entreprises; v_cout numeric; v_deja numeric; v_tresor numeric;
begin
  select * into v_ent from entreprises where id = p_entreprise_id and statut = 'acceptee' for update;
  if v_ent.id is null then raise exception 'Entreprise introuvable.'; end if;
  if v_ent.capital_prix_par_centieme is null then raise exception 'Aucune offre en cours.'; end if;
  if p_pourcentage < v_ent.capital_min_achat_pct then raise exception 'Minimum achetable : % %%.', v_ent.capital_min_achat_pct; end if;
  if p_pourcentage > v_ent.capital_en_vente_pct then raise exception 'Il ne reste que % %% en vente.', v_ent.capital_en_vente_pct; end if;
  select coalesce(pourcentage, 0) into v_deja from entreprises_capital_detenteurs where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_ent.capital_max_par_individu is not null and (coalesce(v_deja, 0) + p_pourcentage) > v_ent.capital_max_par_individu then
    raise exception 'Maximum par individu dépassé (max : % %%).', v_ent.capital_max_par_individu;
  end if;

  v_cout := (p_pourcentage / 0.01) * v_ent.capital_prix_par_centieme;
  select tresorerie into v_tresor from citoyens where id = auth.uid() for update;
  if v_tresor < v_cout then raise exception 'Trésorerie insuffisante (coût : % R$).', v_cout; end if;

  update citoyens set tresorerie = tresorerie - v_cout where id = auth.uid();
  perform _sans_partage(true);
  update entreprises set tresorerie = tresorerie + v_cout, capital_en_vente_pct = capital_en_vente_pct - p_pourcentage where id = p_entreprise_id;
  perform _sans_partage(false);
  insert into entreprises_capital_detenteurs (entreprise_id, citoyen_id, pourcentage) values (p_entreprise_id, auth.uid(), p_pourcentage)
    on conflict (entreprise_id, citoyen_id) do update set pourcentage = entreprises_capital_detenteurs.pourcentage + p_pourcentage;
  perform _entreprise_regler_dette_employes(p_entreprise_id);
  perform _entreprise_log(p_entreprise_id, 'vente_capital',
    jsonb_build_object('acheteur_username', (select username from citoyens where id = auth.uid()), 'pourcentage', p_pourcentage, 'cout', v_cout, 'montant', v_cout));
end; $$;
grant execute on function entreprise_acheter_capital(uuid, numeric) to authenticated;

-- ---- Offres de tiers (description 500 car., tranches de 0,1 %) ----
create table if not exists capital_offres_tiers (
  id               uuid primary key default gen_random_uuid(),
  entreprise_id    uuid not null references entreprises(id),
  vendeur_id       uuid not null references auth.users(id),
  pourcentage      numeric not null check (pourcentage > 0),
  prix_par_dixieme numeric not null check (prix_par_dixieme >= 0),
  description      text check (char_length(description) <= 500),
  cree_le          timestamptz not null default now()
);
alter table capital_offres_tiers enable row level security;
drop policy if exists "Lecture publique des offres de capital de tiers" on capital_offres_tiers;
create policy "Lecture publique des offres de capital de tiers" on capital_offres_tiers for select using (true);

create or replace function mes_capitaux()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'entreprise_id', e.id, 'nom', e.nom, 'pourcentage', d.pourcentage, 'solde', d.solde,
    'valeur_tresorerie', round(e.tresorerie * d.pourcentage / 100.0, 2),
    'en_vente_pct', coalesce((select sum(o.pourcentage) from capital_offres_tiers o where o.entreprise_id = e.id and o.vendeur_id = auth.uid()), 0)
  ) order by e.nom), '[]'::jsonb)
  from entreprises_capital_detenteurs d join entreprises e on e.id = d.entreprise_id
  where d.citoyen_id = auth.uid();
$$;
grant execute on function mes_capitaux() to authenticated;

create or replace function capital_mettre_en_vente_tiers(p_entreprise_id uuid, p_pourcentage numeric, p_prix_par_dixieme numeric, p_description text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_detenu numeric; v_en_vente numeric;
begin
  if p_pourcentage <= 0 or round(p_pourcentage * 10) <> p_pourcentage * 10 then raise exception 'Le pourcentage doit être un multiple de 0,1 %%.'; end if;
  if p_prix_par_dixieme < 0 then raise exception 'Prix invalide.'; end if;
  if p_description is not null and char_length(p_description) > 500 then raise exception 'Description limitée à 500 caractères.'; end if;
  select pourcentage into v_detenu from entreprises_capital_detenteurs where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_detenu is null then raise exception 'Vous ne détenez pas de capital dans cette entreprise.'; end if;
  select coalesce(sum(pourcentage), 0) into v_en_vente from capital_offres_tiers where entreprise_id = p_entreprise_id and vendeur_id = auth.uid();
  if v_en_vente + p_pourcentage > v_detenu then raise exception 'Vous ne pouvez pas vendre plus que ce que vous détenez (% %% déjà en vente).', v_en_vente; end if;
  insert into capital_offres_tiers (entreprise_id, vendeur_id, pourcentage, prix_par_dixieme, description)
    values (p_entreprise_id, auth.uid(), p_pourcentage, p_prix_par_dixieme, nullif(trim(coalesce(p_description, '')), ''));
end; $$;
grant execute on function capital_mettre_en_vente_tiers(uuid, numeric, numeric, text) to authenticated;

create or replace function capital_retirer_offre_tiers(p_offre_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from capital_offres_tiers where id = p_offre_id and vendeur_id = auth.uid();
  if not found then raise exception 'Offre introuvable.'; end if;
end; $$;
grant execute on function capital_retirer_offre_tiers(uuid) to authenticated;

create or replace function capital_acheter_tiers(p_offre_id uuid, p_pourcentage numeric)
returns void language plpgsql security definer set search_path = public as $$
declare o capital_offres_tiers; v_cout numeric; v_tresor numeric;
begin
  select * into o from capital_offres_tiers where id = p_offre_id for update;
  if o.id is null then raise exception 'Offre introuvable.'; end if;
  if o.vendeur_id = auth.uid() then raise exception 'Vous ne pouvez pas acheter votre propre offre.'; end if;
  if p_pourcentage <= 0 or round(p_pourcentage * 10) <> p_pourcentage * 10 then raise exception 'Le pourcentage doit être un multiple de 0,1 %%.'; end if;
  if p_pourcentage > o.pourcentage then raise exception 'Il ne reste que % %% en vente.', o.pourcentage; end if;

  v_cout := (p_pourcentage / 0.1) * o.prix_par_dixieme;
  select tresorerie into v_tresor from citoyens where id = auth.uid() for update;
  if v_tresor < v_cout then raise exception 'Trésorerie insuffisante (coût : % R$).', v_cout; end if;

  update citoyens set tresorerie = tresorerie - v_cout where id = auth.uid();
  update citoyens set tresorerie = tresorerie + v_cout where id = o.vendeur_id;

  update entreprises_capital_detenteurs set pourcentage = pourcentage - p_pourcentage
    where entreprise_id = o.entreprise_id and citoyen_id = o.vendeur_id;
  delete from entreprises_capital_detenteurs where entreprise_id = o.entreprise_id and citoyen_id = o.vendeur_id and pourcentage <= 0;
  insert into entreprises_capital_detenteurs (entreprise_id, citoyen_id, pourcentage) values (o.entreprise_id, auth.uid(), p_pourcentage)
    on conflict (entreprise_id, citoyen_id) do update set pourcentage = entreprises_capital_detenteurs.pourcentage + p_pourcentage;

  if p_pourcentage >= o.pourcentage then delete from capital_offres_tiers where id = o.id;
  else update capital_offres_tiers set pourcentage = pourcentage - p_pourcentage where id = o.id; end if;
end; $$;
grant execute on function capital_acheter_tiers(uuid, numeric) to authenticated;

-- Marché public : toutes les offres, sans chercher le nom de l'entreprise.
create or replace function capital_marche()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'entreprises', coalesce((select jsonb_agg(jsonb_build_object(
      'entreprise_id', e.id, 'nom', e.nom, 'en_vente_pct', e.capital_en_vente_pct,
      'prix_par_centieme', e.capital_prix_par_centieme, 'min_achat_pct', e.capital_min_achat_pct,
      'max_par_individu', e.capital_max_par_individu, 'description', e.capital_description) order by e.nom)
      from entreprises e where e.statut = 'acceptee' and e.capital_en_vente_pct > 0 and e.capital_prix_par_centieme is not null), '[]'::jsonb),
    'tiers', coalesce((select jsonb_agg(jsonb_build_object(
      'id', o.id, 'entreprise_id', e.id, 'nom', e.nom, 'vendeur', c.username, 'pourcentage', o.pourcentage,
      'prix_par_dixieme', o.prix_par_dixieme, 'description', o.description) order by o.cree_le desc)
      from capital_offres_tiers o join entreprises e on e.id = o.entreprise_id join citoyens c on c.id = o.vendeur_id
      where e.statut = 'acceptee'), '[]'::jsonb)
  );
$$;
grant execute on function capital_marche() to authenticated, anon;


-- ============================================================
-- 4) LOGS : types étendus + consultation publique
-- ============================================================
do $$
declare r record;
begin
  for r in select conname from pg_constraint where conrelid = 'entreprises_logs'::regclass and contype = 'c'
           and pg_get_constraintdef(oid) ilike '%paiement_employe%' loop
    execute format('alter table entreprises_logs drop constraint %I', r.conname);
  end loop;
end $$;
alter table entreprises_logs add constraint entreprises_logs_type_check check (type in
  ('depense','ajout_fonds','paiement_employe','virement_entreprise','virement_tiers','vente_capital','capital_gouvernement','emprunt_gouvernement'));

create or replace function entreprise_logs_publics(p_entreprise_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'type', l.type, 'cree_le', l.cree_le,
    'donnees', l.donnees || case when l.donnees ? 'citoyen_id'
       then jsonb_build_object('username', (select c.username from citoyens c where c.id = (l.donnees->>'citoyen_id')::uuid))
       else '{}'::jsonb end
  ) order by l.cree_le desc), '[]'::jsonb)
  from entreprises_logs l join entreprises e on e.id = l.entreprise_id
  where l.entreprise_id = p_entreprise_id and e.statut = 'acceptee';
$$;
grant execute on function entreprise_logs_publics(uuid) to authenticated, anon;


-- ============================================================
-- 5) EMPRUNTS AU GOUVERNEMENT — négociation aller-retour
--    en_attente = au tour du gouvernement ; en_attente_entreprise = au
--    tour de l'entreprise. Chaque côté peut accepter, refuser ou
--    rectifier / contre-demander (montant, type et valeur du taux).
-- ============================================================
do $$
declare r record;
begin
  for r in select conname from pg_constraint where conrelid = 'entreprises_emprunts_gouv'::regclass and contype = 'c'
           and pg_get_constraintdef(oid) ilike '%en_attente%' loop
    execute format('alter table entreprises_emprunts_gouv drop constraint %I', r.conname);
  end loop;
end $$;
alter table entreprises_emprunts_gouv add constraint entreprises_emprunts_gouv_statut_check
  check (statut in ('en_attente','en_attente_entreprise','acceptee','refusee','rembourse'));

create table if not exists entreprises_emprunts_historique (
  id          uuid primary key default gen_random_uuid(),
  emprunt_id  uuid not null references entreprises_emprunts_gouv(id) on delete cascade,
  auteur      text not null check (auteur in ('entreprise','gouvernement')),
  montant     numeric not null,
  type_taux   text not null,
  taux_valeur numeric not null,
  message     text,
  cree_le     timestamptz not null default now()
);
alter table entreprises_emprunts_historique enable row level security;
drop policy if exists "Voir l'historique de ses emprunts" on entreprises_emprunts_historique;
create policy "Voir l'historique de ses emprunts" on entreprises_emprunts_historique for select
  using (est_admin_actuel() or exists (
    select 1 from entreprises_emprunts_gouv g join entreprises_membres m on m.entreprise_id = g.entreprise_id
    where g.id = entreprises_emprunts_historique.emprunt_id and m.citoyen_id = auth.uid()));

create or replace function entreprise_demander_emprunt_gouv(p_entreprise_id uuid, p_montant numeric, p_type_taux text, p_taux_valeur numeric, p_justification text)
returns entreprises_emprunts_gouv language plpgsql security definer set search_path = public as $$
declare v_row entreprises_emprunts_gouv;
begin
  perform _exige_droit(p_entreprise_id, 'emprunter_gouvernement');
  if p_montant <= 0 then raise exception 'Montant invalide.'; end if;
  if p_type_taux not in ('jour','mois','an','fixe') then raise exception 'Type de taux invalide.'; end if;
  insert into entreprises_emprunts_gouv (entreprise_id, montant_demande, type_taux, taux_valeur, justification)
    values (p_entreprise_id, p_montant, p_type_taux, p_taux_valeur, p_justification) returning * into v_row;
  insert into entreprises_emprunts_historique (emprunt_id, auteur, montant, type_taux, taux_valeur, message)
    values (v_row.id, 'entreprise', p_montant, p_type_taux, p_taux_valeur, p_justification);
  return v_row;
end; $$;
grant execute on function entreprise_demander_emprunt_gouv(uuid, numeric, text, numeric, text) to authenticated;

create or replace function _emprunt_accepter(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v entreprises_emprunts_gouv; v_du numeric; v_solde numeric;
begin
  select * into v from entreprises_emprunts_gouv where id = p_id for update;
  select solde into v_solde from tresor_public where id = 1 for update;
  if v_solde < v.montant_demande then raise exception 'Trésorerie publique insuffisante (% R$ disponibles).', v_solde; end if;
  v_du := case when v.type_taux = 'fixe' then v.montant_demande + v.taux_valeur else v.montant_demande end;
  update tresor_public set solde = solde - v.montant_demande where id = 1;
  perform _sans_partage(true);
  update entreprises set tresorerie = tresorerie + v.montant_demande where id = v.entreprise_id;
  perform _sans_partage(false);
  update entreprises_emprunts_gouv set statut = 'acceptee', montant_du = v_du, accepte_le = now() where id = p_id;
  perform _entreprise_log(v.entreprise_id, 'emprunt_gouvernement',
    jsonb_build_object('montant', v.montant_demande, 'type_taux', v.type_taux, 'taux_valeur', v.taux_valeur));
  perform _entreprise_regler_dette_employes(v.entreprise_id);
end; $$;

create or replace function gouv_traiter_emprunt_entreprise(p_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if p_decision not in ('acceptee','refusee') then raise exception 'Décision invalide.'; end if;
  if not exists (select 1 from entreprises_emprunts_gouv where id = p_id and statut = 'en_attente') then
    raise exception 'Demande introuvable ou pas au tour du gouvernement.';
  end if;
  if p_decision = 'refusee' then update entreprises_emprunts_gouv set statut = 'refusee' where id = p_id;
  else perform _emprunt_accepter(p_id); end if;
end; $$;
grant execute on function gouv_traiter_emprunt_entreprise(uuid, text) to authenticated;

create or replace function gouv_rectifier_emprunt_entreprise(p_id uuid, p_montant numeric, p_type_taux text, p_taux_valeur numeric, p_message text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if p_montant <= 0 or p_taux_valeur < 0 then raise exception 'Montant ou taux invalide.'; end if;
  if p_type_taux not in ('jour','mois','an','fixe') then raise exception 'Type de taux invalide.'; end if;
  update entreprises_emprunts_gouv set montant_demande = p_montant, type_taux = p_type_taux, taux_valeur = p_taux_valeur,
    statut = 'en_attente_entreprise' where id = p_id and statut = 'en_attente';
  if not found then raise exception 'Demande introuvable ou pas au tour du gouvernement.'; end if;
  insert into entreprises_emprunts_historique (emprunt_id, auteur, montant, type_taux, taux_valeur, message)
    values (p_id, 'gouvernement', p_montant, p_type_taux, p_taux_valeur, p_message);
end; $$;
grant execute on function gouv_rectifier_emprunt_entreprise(uuid, numeric, text, numeric, text) to authenticated;

create or replace function entreprise_repondre_emprunt(p_id uuid, p_action text, p_montant numeric default null, p_type_taux text default null, p_taux_valeur numeric default null, p_message text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_ent uuid;
begin
  select entreprise_id into v_ent from entreprises_emprunts_gouv where id = p_id and statut = 'en_attente_entreprise';
  if v_ent is null then raise exception 'Demande introuvable ou pas à votre tour.'; end if;
  perform _exige_droit(v_ent, 'emprunter_gouvernement');
  if p_action = 'accepter' then perform _emprunt_accepter(p_id);
  elsif p_action = 'refuser' then update entreprises_emprunts_gouv set statut = 'refusee' where id = p_id;
  elsif p_action = 'contre' then
    if p_montant is null or p_montant <= 0 or p_taux_valeur is null or p_taux_valeur < 0 or p_type_taux not in ('jour','mois','an','fixe') then
      raise exception 'Contre-demande invalide.';
    end if;
    update entreprises_emprunts_gouv set montant_demande = p_montant, type_taux = p_type_taux, taux_valeur = p_taux_valeur,
      statut = 'en_attente' where id = p_id;
    insert into entreprises_emprunts_historique (emprunt_id, auteur, montant, type_taux, taux_valeur, message)
      values (p_id, 'entreprise', p_montant, p_type_taux, p_taux_valeur, p_message);
  else raise exception 'Action invalide.'; end if;
end; $$;
grant execute on function entreprise_repondre_emprunt(uuid, text, numeric, text, numeric, text) to authenticated;

create or replace function gouv_liste_emprunts_entreprises(p_statut text default 'en_attente')
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not est_admin_actuel() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id, 'entreprise_nom', en.nom, 'montant_demande', e.montant_demande, 'type_taux', e.type_taux,
    'taux_valeur', e.taux_valeur, 'justification', e.justification, 'cree_le', e.cree_le,
    'historique', (select coalesce(jsonb_agg(jsonb_build_object('auteur', h.auteur, 'montant', h.montant,
       'type_taux', h.type_taux, 'taux_valeur', h.taux_valeur, 'message', h.message) order by h.cree_le), '[]'::jsonb)
       from entreprises_emprunts_historique h where h.emprunt_id = e.id)
  ) order by e.cree_le), '[]'::jsonb) end
  from entreprises_emprunts_gouv e join entreprises en on en.id = e.entreprise_id where e.statut = p_statut;
$$;
grant execute on function gouv_liste_emprunts_entreprises(text) to authenticated;


-- ============================================================
-- 6) VENTE DE CAPITAL AU GOUVERNEMENT — négociation aller-retour
--    (0,01 % à 99,9 %, prix par 0,01 %). Le capital vendu appartient
--    ensuite au @gouvernement.
-- ============================================================
create table if not exists capital_offres_gouvernement (
  id                uuid primary key default gen_random_uuid(),
  entreprise_id     uuid not null references entreprises(id),
  pourcentage       numeric not null check (pourcentage >= 0.01 and pourcentage <= 99.9),
  prix_par_centieme numeric not null check (prix_par_centieme >= 0),
  statut            text not null default 'en_attente' check (statut in ('en_attente','en_attente_entreprise','acceptee','refusee')),
  cree_par          uuid not null references auth.users(id),
  cree_le           timestamptz not null default now()
);
alter table capital_offres_gouvernement enable row level security;
drop policy if exists "Voir les offres de capital au gouvernement" on capital_offres_gouvernement;
create policy "Voir les offres de capital au gouvernement" on capital_offres_gouvernement for select
  using (est_admin_actuel() or exists (select 1 from entreprises_membres m where m.entreprise_id = capital_offres_gouvernement.entreprise_id and m.citoyen_id = auth.uid()));

create table if not exists capital_offres_gouvernement_historique (
  id                uuid primary key default gen_random_uuid(),
  offre_id          uuid not null references capital_offres_gouvernement(id) on delete cascade,
  auteur            text not null check (auteur in ('entreprise','gouvernement')),
  pourcentage       numeric not null,
  prix_par_centieme numeric not null,
  message           text,
  cree_le           timestamptz not null default now()
);
alter table capital_offres_gouvernement_historique enable row level security;
drop policy if exists "Voir l'historique des offres de capital" on capital_offres_gouvernement_historique;
create policy "Voir l'historique des offres de capital" on capital_offres_gouvernement_historique for select
  using (est_admin_actuel() or exists (
    select 1 from capital_offres_gouvernement g join entreprises_membres m on m.entreprise_id = g.entreprise_id
    where g.id = capital_offres_gouvernement_historique.offre_id and m.citoyen_id = auth.uid()));

create or replace function entreprise_offrir_capital_gouvernement(p_entreprise_id uuid, p_pourcentage numeric, p_prix_par_centieme numeric, p_message text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_vendu numeric; v_id uuid;
begin
  perform _exige_droit(p_entreprise_id, 'vendre_capital');
  if p_pourcentage < 0.01 or p_pourcentage > 99.9 then raise exception 'Le pourcentage doit être entre 0,01 %% et 99,9 %%.'; end if;
  if p_prix_par_centieme < 0 then raise exception 'Prix invalide.'; end if;
  if exists (select 1 from capital_offres_gouvernement where entreprise_id = p_entreprise_id and statut in ('en_attente','en_attente_entreprise')) then
    raise exception 'Une offre au gouvernement est déjà en cours pour cette entreprise.';
  end if;
  select coalesce(sum(pourcentage), 0) into v_vendu from entreprises_capital_detenteurs where entreprise_id = p_entreprise_id;
  if v_vendu + p_pourcentage > 100 then raise exception 'L''entreprise ne possède pas assez de capital (% %% déjà vendus).', v_vendu; end if;
  insert into capital_offres_gouvernement (entreprise_id, pourcentage, prix_par_centieme, cree_par)
    values (p_entreprise_id, p_pourcentage, p_prix_par_centieme, auth.uid()) returning id into v_id;
  insert into capital_offres_gouvernement_historique (offre_id, auteur, pourcentage, prix_par_centieme, message)
    values (v_id, 'entreprise', p_pourcentage, p_prix_par_centieme, p_message);
end; $$;
grant execute on function entreprise_offrir_capital_gouvernement(uuid, numeric, numeric, text) to authenticated;

create or replace function _capital_gouv_accepter(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare o capital_offres_gouvernement; v_vendu numeric; v_cout numeric; v_solde numeric;
begin
  select * into o from capital_offres_gouvernement where id = p_id for update;
  select coalesce(sum(pourcentage), 0) into v_vendu from entreprises_capital_detenteurs where entreprise_id = o.entreprise_id;
  if v_vendu + o.pourcentage > 100 then raise exception 'L''entreprise ne possède plus assez de capital.'; end if;
  v_cout := (o.pourcentage / 0.01) * o.prix_par_centieme;
  select solde into v_solde from tresor_public where id = 1 for update;
  if v_solde < v_cout then raise exception 'Trésorerie publique insuffisante (% R$ disponibles, % R$ requis).', v_solde, v_cout; end if;
  update tresor_public set solde = solde - v_cout where id = 1;
  perform _sans_partage(true);
  update entreprises set tresorerie = tresorerie + v_cout where id = o.entreprise_id;
  perform _sans_partage(false);
  insert into entreprises_capital_detenteurs (entreprise_id, citoyen_id, est_gouvernement, pourcentage)
    values (o.entreprise_id, null, true, o.pourcentage)
    on conflict (entreprise_id) where est_gouvernement do update
      set pourcentage = entreprises_capital_detenteurs.pourcentage + excluded.pourcentage;
  update capital_offres_gouvernement set statut = 'acceptee' where id = p_id;
  perform _entreprise_log(o.entreprise_id, 'capital_gouvernement',
    jsonb_build_object('acheteur_username', 'gouvernement', 'pourcentage', o.pourcentage, 'cout', v_cout, 'montant', v_cout));
  perform _entreprise_regler_dette_employes(o.entreprise_id);
end; $$;

create or replace function gouv_traiter_offre_capital(p_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if p_decision not in ('acceptee','refusee') then raise exception 'Décision invalide.'; end if;
  if not exists (select 1 from capital_offres_gouvernement where id = p_id and statut = 'en_attente') then
    raise exception 'Offre introuvable ou pas au tour du gouvernement.';
  end if;
  if p_decision = 'refusee' then update capital_offres_gouvernement set statut = 'refusee' where id = p_id;
  else perform _capital_gouv_accepter(p_id); end if;
end; $$;
grant execute on function gouv_traiter_offre_capital(uuid, text) to authenticated;

create or replace function gouv_rectifier_offre_capital(p_id uuid, p_pourcentage numeric, p_prix_par_centieme numeric, p_message text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if p_pourcentage < 0.01 or p_pourcentage > 99.9 or p_prix_par_centieme < 0 then raise exception 'Valeurs invalides.'; end if;
  update capital_offres_gouvernement set pourcentage = p_pourcentage, prix_par_centieme = p_prix_par_centieme,
    statut = 'en_attente_entreprise' where id = p_id and statut = 'en_attente';
  if not found then raise exception 'Offre introuvable ou pas au tour du gouvernement.'; end if;
  insert into capital_offres_gouvernement_historique (offre_id, auteur, pourcentage, prix_par_centieme, message)
    values (p_id, 'gouvernement', p_pourcentage, p_prix_par_centieme, p_message);
end; $$;
grant execute on function gouv_rectifier_offre_capital(uuid, numeric, numeric, text) to authenticated;

create or replace function entreprise_repondre_offre_capital(p_id uuid, p_action text, p_pourcentage numeric default null, p_prix_par_centieme numeric default null, p_message text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_ent uuid;
begin
  select entreprise_id into v_ent from capital_offres_gouvernement where id = p_id and statut = 'en_attente_entreprise';
  if v_ent is null then raise exception 'Offre introuvable ou pas à votre tour.'; end if;
  perform _exige_droit(v_ent, 'vendre_capital');
  if p_action = 'accepter' then perform _capital_gouv_accepter(p_id);
  elsif p_action = 'refuser' then update capital_offres_gouvernement set statut = 'refusee' where id = p_id;
  elsif p_action = 'modifier' then
    if p_pourcentage is null or p_pourcentage < 0.01 or p_pourcentage > 99.9 or p_prix_par_centieme is null or p_prix_par_centieme < 0 then
      raise exception 'Valeurs invalides.';
    end if;
    update capital_offres_gouvernement set pourcentage = p_pourcentage, prix_par_centieme = p_prix_par_centieme, statut = 'en_attente' where id = p_id;
    insert into capital_offres_gouvernement_historique (offre_id, auteur, pourcentage, prix_par_centieme, message)
      values (p_id, 'entreprise', p_pourcentage, p_prix_par_centieme, p_message);
  else raise exception 'Action invalide.'; end if;
end; $$;
grant execute on function entreprise_repondre_offre_capital(uuid, text, numeric, numeric, text) to authenticated;

create or replace function gouv_liste_offres_capital(p_statut text default 'en_attente')
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not est_admin_actuel() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
    'id', g.id, 'entreprise_nom', e.nom, 'pourcentage', g.pourcentage, 'prix_par_centieme', g.prix_par_centieme,
    'cout_total', round(g.pourcentage / 0.01 * g.prix_par_centieme, 2),
    'historique', (select coalesce(jsonb_agg(jsonb_build_object('auteur', h.auteur, 'pourcentage', h.pourcentage,
       'prix_par_centieme', h.prix_par_centieme, 'message', h.message) order by h.cree_le), '[]'::jsonb)
       from capital_offres_gouvernement_historique h where h.offre_id = g.id)
  ) order by g.cree_le), '[]'::jsonb) end
  from capital_offres_gouvernement g join entreprises e on e.id = g.entreprise_id where g.statut = p_statut;
$$;
grant execute on function gouv_liste_offres_capital(text) to authenticated;


-- ============================================================
-- 7) RAPPORTS D'IMPÔTS — période = mois précédent, dépôt le 1er,
--    rapport automatique le 2 ; mode manuel "assisté par les logs".
-- ============================================================
do $$
declare r record;
begin
  for r in select conname from pg_constraint where conrelid = 'entreprises_depots_impots'::regclass and contype = 'c'
           and pg_get_constraintdef(oid) ilike '%automatique%' loop
    execute format('alter table entreprises_depots_impots drop constraint %I', r.conname);
  end loop;
end $$;
alter table entreprises_depots_impots add constraint entreprises_depots_impots_type_check
  check (type in ('manuel','automatique','assiste'));

create or replace function _entreprise_rapport_calcul(p_entreprise_id uuid, p_periode text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_fin timestamptz; v_ancien numeric; v_tresor numeric; v_dep numeric;
  v_tiers jsonb; v_ajouts jsonb; v_vent jsonb; v_cap jsonb; v_emp jsonb; v_sal jsonb; v_pct_tiers numeric;
begin
  if p_periode !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception 'Période invalide (format AAAA-MM).'; end if;
  v_fin := (to_date(p_periode || '-01', 'YYYY-MM-DD') + interval '1 month');

  select benefices into v_ancien from entreprises_depots_impots where entreprise_id = p_entreprise_id order by cree_le desc limit 1;
  select tresorerie into v_tresor from entreprises where id = p_entreprise_id;

  select coalesce(sum((donnees->>'montant')::numeric), 0) into v_dep from entreprises_logs
    where entreprise_id = p_entreprise_id and cree_le < v_fin and type in ('depense','paiement_employe','virement_tiers','virement_entreprise');

  select coalesce(jsonb_agg(jsonb_build_object('destinataire_username', donnees->>'destinataire_username', 'montant', donnees->>'montant')), '[]'::jsonb)
    into v_tiers from entreprises_logs where entreprise_id = p_entreprise_id and cree_le < v_fin and type = 'virement_tiers';
  select coalesce(jsonb_agg(jsonb_build_object('username', c.username, 'montant', l.donnees->>'montant')), '[]'::jsonb)
    into v_ajouts from entreprises_logs l left join citoyens c on c.id = (l.donnees->>'citoyen_id')::uuid
    where l.entreprise_id = p_entreprise_id and l.cree_le < v_fin and l.type = 'ajout_fonds';
  select coalesce(jsonb_agg(jsonb_build_object('entreprise_dest_nom', donnees->>'entreprise_dest_nom', 'montant', donnees->>'montant')), '[]'::jsonb)
    into v_vent from entreprises_logs where entreprise_id = p_entreprise_id and cree_le < v_fin and type = 'virement_entreprise';
  select coalesce(jsonb_agg(jsonb_build_object('acheteur_username', donnees->>'acheteur_username', 'pourcentage', donnees->>'pourcentage')), '[]'::jsonb)
    into v_cap from entreprises_logs where entreprise_id = p_entreprise_id and cree_le < v_fin and type in ('vente_capital','capital_gouvernement');
  select coalesce(jsonb_agg(jsonb_build_object('montant', donnees->>'montant', 'type_taux', donnees->>'type_taux', 'taux_valeur', donnees->>'taux_valeur')), '[]'::jsonb)
    into v_emp from entreprises_logs where entreprise_id = p_entreprise_id and cree_le < v_fin and type = 'emprunt_gouvernement';
  select coalesce(jsonb_agg(jsonb_build_object('username', c.username, 'montant_recu', (l.donnees->>'montant')::numeric,
      'heures', l.donnees->>'heures', 'taux', l.donnees->>'taux')), '[]'::jsonb)
    into v_sal from entreprises_logs l join citoyens c on c.id = (l.donnees->>'citoyen_id')::uuid
    where l.entreprise_id = p_entreprise_id and l.cree_le < v_fin and l.type = 'paiement_employe';

  select coalesce(sum(pourcentage), 0) into v_pct_tiers from entreprises_capital_detenteurs where entreprise_id = p_entreprise_id;

  return jsonb_build_object(
    'periode', p_periode, 'fin', v_fin, 'benefices', v_tresor - coalesce(v_ancien, 0), 'depenses', v_dep,
    'capital_pdg_pct', 100 - v_pct_tiers, 'capital_tiers_pct', v_pct_tiers,
    'details', jsonb_build_object('virements_tiers', v_tiers, 'ajouts_fonds', v_ajouts, 'virements_entreprises', v_vent,
      'capitaux_vendus', v_cap, 'emprunts_gouvernement', v_emp, 'salaires', v_sal));
end; $$;

create or replace function entreprise_apercu_rapport(p_entreprise_id uuid, p_periode text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform _exige_droit(p_entreprise_id, 'deposer_impot');
  return _entreprise_rapport_calcul(p_entreprise_id, p_periode);
end; $$;
grant execute on function entreprise_apercu_rapport(uuid, text) to authenticated;

create or replace function _entreprise_rapport_creer(p_entreprise_id uuid, p_periode text, p_type text, p_benefices numeric, p_depenses numeric, p_note text, p_par uuid, p_avec_details boolean)
returns entreprises_depots_impots language plpgsql security definer set search_path = public as $$
declare v_calc jsonb; v_row entreprises_depots_impots;
begin
  v_calc := _entreprise_rapport_calcul(p_entreprise_id, p_periode);
  if exists (select 1 from entreprises_depots_impots where entreprise_id = p_entreprise_id and periode = p_periode) then
    raise exception 'Un rapport existe déjà pour la période %.', p_periode;
  end if;
  insert into entreprises_depots_impots (entreprise_id, periode, benefices, depenses, note, depose_par, type, details, capital_pdg_pct, capital_tiers_pct)
  values (p_entreprise_id, p_periode,
    coalesce(p_benefices, (v_calc->>'benefices')::numeric), coalesce(p_depenses, (v_calc->>'depenses')::numeric),
    p_note, p_par, p_type, case when p_avec_details then v_calc->'details' else null end,
    (v_calc->>'capital_pdg_pct')::numeric, (v_calc->>'capital_tiers_pct')::numeric)
  returning * into v_row;
  delete from entreprises_logs where entreprise_id = p_entreprise_id and cree_le < (v_calc->>'fin')::timestamptz;
  return v_row;
end; $$;

-- Dépôt manuel simple (Période, Bénéfices, Dépenses, Note).
create or replace function entreprise_deposer_impot(p_entreprise_id uuid, p_periode text, p_benefices numeric, p_depenses numeric, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exige_droit(p_entreprise_id, 'deposer_impot');
  perform _entreprise_rapport_creer(p_entreprise_id, p_periode, 'manuel', p_benefices, p_depenses, p_note, auth.uid(), false);
end; $$;
grant execute on function entreprise_deposer_impot(uuid, text, numeric, numeric, text) to authenticated;

-- Dépôt "assisté" : détails automatiques issus des logs, chiffres
-- (bénéfices / dépenses / note) validés ou corrigés à la main.
create or replace function entreprise_deposer_impot_assiste(p_entreprise_id uuid, p_periode text, p_benefices numeric, p_depenses numeric, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exige_droit(p_entreprise_id, 'deposer_impot');
  perform _entreprise_rapport_creer(p_entreprise_id, p_periode, 'assiste', p_benefices, p_depenses, p_note, auth.uid(), true);
end; $$;
grant execute on function entreprise_deposer_impot_assiste(uuid, text, numeric, numeric, text) to authenticated;

-- Conservé pour compatibilité : génération automatique immédiate par un PDG/Co-PDG.
create or replace function entreprise_generer_rapport_auto(p_entreprise_id uuid, p_periode text)
returns entreprises_depots_impots language plpgsql security definer set search_path = public as $$
declare v_role text;
begin
  select role into v_role from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_role not in ('pdg','co_pdg') and not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  return _entreprise_rapport_creer(p_entreprise_id, p_periode, 'automatique', null, null, 'Généré automatiquement', auth.uid(), true);
end; $$;
grant execute on function entreprise_generer_rapport_auto(uuid, text) to authenticated;

-- Le 2 de chaque mois : rapport automatique du mois précédent pour toute
-- entreprise acceptée qui n'a pas déposé le sien le 1er. Idempotent.
create or replace function entreprises_rattraper_rapports()
returns int language plpgsql security definer set search_path = public as $$
declare v_n int := 0; v_periode text; v_e record; v_pdg uuid; v_debut timestamptz;
begin
  if extract(day from current_date) < 2 then return 0; end if;
  v_periode := to_char(current_date - interval '1 month', 'YYYY-MM');
  v_debut := date_trunc('month', now());
  for v_e in select id from entreprises e where e.statut = 'acceptee' and e.cree_le < v_debut
    and not exists (select 1 from entreprises_depots_impots d where d.entreprise_id = e.id and d.periode = v_periode) loop
    select citoyen_id into v_pdg from entreprises_membres where entreprise_id = v_e.id and role = 'pdg' limit 1;
    continue when v_pdg is null;
    perform _entreprise_rapport_creer(v_e.id, v_periode, 'automatique', null, null, 'Généré automatiquement', v_pdg, true);
    v_n := v_n + 1;
  end loop;
  return v_n;
end; $$;
grant execute on function entreprises_rattraper_rapports() to authenticated;

-- Planification exacte le 2 à 00h05 si pg_cron est activé ; sinon le
-- rattrapage se fait à la connexion de n'importe quel citoyen.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('entreprises-rapports-auto', '5 0 2 * *', 'select public.entreprises_rattraper_rapports()');
  end if;
exception when others then null;
end $$;

create or replace function rapport_impot_public(p_nom_entreprise text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_ent entreprises; v_rapports jsonb;
begin
  select * into v_ent from entreprises where lower(nom) = lower(trim(p_nom_entreprise)) and statut = 'acceptee';
  if v_ent.id is null then raise exception 'Entreprise introuvable.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'periode', periode, 'type', type, 'benefices', benefices, 'depenses', depenses, 'note', note,
    'details', details, 'capital_pdg_pct', capital_pdg_pct, 'capital_tiers_pct', capital_tiers_pct, 'cree_le', cree_le
  ) order by periode desc, cree_le desc), '[]'::jsonb) into v_rapports
  from entreprises_depots_impots where entreprise_id = v_ent.id;
  return jsonb_build_object('id', v_ent.id, 'nom', v_ent.nom, 'code', v_ent.code, 'sieges', v_ent.sieges,
    'type_vente', v_ent.type_vente, 'mode_vente', v_ent.mode_vente, 'cree_le', v_ent.cree_le, 'rapports', v_rapports);
end; $$;
grant execute on function rapport_impot_public(text) to authenticated, anon;


-- ============================================================
-- 8) entreprise_detail (CIB masqués) + mes_infos_personnelles
-- ============================================================
create or replace function entreprise_detail(p_entreprise_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_e public.entreprises; v_mon_role text; v_membres jsonb; v_depots jsonb; v_roles jsonb; v_prec text;
begin
  select * into v_e from entreprises where id = p_entreprise_id;
  if v_e.id is null then raise exception 'Entreprise introuvable.'; end if;
  select role into v_mon_role from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_mon_role is null and not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  v_prec := to_char(current_date - interval '1 month', 'YYYY-MM');

  select coalesce(jsonb_agg(jsonb_build_object(
      'username', c.username, 'nom_complet', coalesce(c.nom_complet, c.prenom || ' ' || c.nom),
      'role', m.role, 'role_id', m.role_id, 'role_nom', r.nom,
      'salaire_horaire', m.salaire_horaire, 'citoyen_id', m.citoyen_id,
      'cib_masque', case when exists (select 1 from entreprises_membres_cib k where k.entreprise_id = m.entreprise_id and k.citoyen_id = m.citoyen_id)
                         then '0R-0***********' end,
      'heures', case when _entreprise_a_droit(p_entreprise_id, 'payer_employe') or _entreprise_a_droit(p_entreprise_id, 'ajouter_employe') or m.citoyen_id = auth.uid() then
         (select coalesce(jsonb_agg(jsonb_build_object('taux', h.taux, 'heures', h.heures) order by h.taux), '[]'::jsonb)
          from entreprises_membres_heures h where h.entreprise_id = m.entreprise_id and h.citoyen_id = m.citoyen_id and h.heures > 0)
         else '[]'::jsonb end
    )), '[]'::jsonb)
    into v_membres from entreprises_membres m join citoyens c on c.id = m.citoyen_id
    left join entreprises_roles r on r.id = m.role_id where m.entreprise_id = p_entreprise_id;

  select coalesce(jsonb_agg(jsonb_build_object('periode', periode, 'type', type, 'benefices', benefices,
      'depenses', depenses, 'note', note, 'details', details, 'capital_pdg_pct', capital_pdg_pct,
      'capital_tiers_pct', capital_tiers_pct, 'cree_le', cree_le) order by periode desc, cree_le desc), '[]'::jsonb)
    into v_depots from entreprises_depots_impots where entreprise_id = p_entreprise_id;

  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nom', nom, 'droits', droits) order by nom), '[]'::jsonb)
    into v_roles from entreprises_roles where entreprise_id = p_entreprise_id;

  return jsonb_build_object(
    'id', v_e.id, 'code', v_e.code, 'nom', v_e.nom, 'tresorerie', v_e.tresorerie, 'sieges', v_e.sieges,
    'type', _type_entreprise(jsonb_array_length(v_membres)), 'mon_role', v_mon_role,
    'membres', v_membres, 'depots_impots', v_depots, 'roles', v_roles,
    'mes_droits', entreprise_mes_droits(p_entreprise_id), 'droits_co_pdg', v_e.droits_co_pdg,
    'mode_paiement', v_e.mode_paiement, 'option_defaillance', v_e.option_defaillance,
    'dette_salariale_gouv', v_e.dette_salariale_gouv, 'dette_salariale_employes', v_e.dette_salariale_employes,
    'option3_cibs', case when _entreprise_a_droit(p_entreprise_id, 'definir_mode_paiement') then to_jsonb(v_e.option3_cibs) else '[]'::jsonb end,
    'capital_en_vente_pct', v_e.capital_en_vente_pct, 'capital_max_par_individu', v_e.capital_max_par_individu,
    'capital_prix_par_centieme', v_e.capital_prix_par_centieme, 'capital_min_achat_pct', v_e.capital_min_achat_pct,
    'capital_description', v_e.capital_description,
    'periode_a_declarer', v_prec,
    'rapport_precedent_fait', exists (select 1 from entreprises_depots_impots d where d.entreprise_id = p_entreprise_id and d.periode = v_prec),
    'capital', entreprise_capital_public(p_entreprise_id)
  );
end; $$;
grant execute on function entreprise_detail(uuid) to authenticated;

create or replace function mes_infos_personnelles()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_c citoyens; v_ent jsonb; v_somme_h numeric; v_brut numeric; v_taux numeric; v_prev numeric;
  v_tr numeric; v_te numeric; v_cot numeric; v_net numeric; v_cib text;
begin
  select * into v_c from citoyens where id = auth.uid();
  if v_c.id is null then raise exception 'Non authentifié.'; end if;

  select coalesce(jsonb_agg(jsonb_build_object('entreprise', e.nom, 'role', m.role, 'salaire_horaire', m.salaire_horaire)), '[]'::jsonb),
         coalesce(sum(m.salaire_horaire), 0)
    into v_ent, v_somme_h
    from entreprises_membres m join entreprises e on e.id = m.entreprise_id
    where m.citoyen_id = auth.uid() and e.statut = 'acceptee' and m.salaire_horaire is not null;

  -- Salaire du CAS (R$/minute) + salaires horaires d'entreprises convertis en R$/minute
  v_brut := coalesce(v_c.salaire, 0) + v_somme_h / 60.0;
  v_taux := calculer_taux_revenu(v_brut);
  select taux_preventif into v_prev from parametres_fiscaux where id = 1;
  v_tr := v_brut * v_taux / 100.0;
  v_te := v_brut * coalesce(v_prev, 0) / 100.0;
  v_cot := v_brut * (0.0275 + 0.0675 + 0.0025);
  v_net := v_brut - v_tr - v_te - v_cot;

  select cib into v_cib from cib_reserves where code_encrypte = v_c.code_social_encrypte and actif order by remplace_fichier desc limit 1;

  return jsonb_build_object(
    'username', v_c.username, 'email', v_c.email, 'nom_complet', v_c.nom_complet,
    'date_naissance', v_c.date_naissance, 'cree_le', v_c.cree_le, 'est_agent_paix', v_c.est_agent_paix,
    'code_social_encrypte', v_c.code_social_encrypte, 'cib', v_cib,
    'salaire_cas_minute', v_c.salaire, 'entreprises', v_ent,
    'salaire_brut_minute', v_brut, 'taux_revenu', v_taux,
    'taxe_revenu_minute', v_tr, 'taxe_preventive_minute', v_te, 'taux_preventif', v_prev,
    'cotisations_minute', v_cot, 'salaire_net_minute', v_net);
end; $$;
grant execute on function mes_infos_personnelles() to authenticated;

-- ============================================================
-- FIN
-- ============================================================
