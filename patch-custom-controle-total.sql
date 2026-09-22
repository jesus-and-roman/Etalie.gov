-- ============================================================
-- Correctif — Panneau custom "sans SQL" : gel granulaire par
-- action, overrides CAS/taxes plus forts que num_CAS.txt, éditeur
-- de fiche citoyen. À exécuter après patch-custom-super-admin.sql
-- et patch-custom-super-admin-fix-pgcrypto.sql. Additif : ne
-- touche à aucune donnée existante, ajoute seulement des colonnes
-- (add column if not exists), des tables, et re-déclare UNE seule
-- fonction déjà existante (mettre_a_jour_salaire, reproduite ici
-- à l'identique + l'ajout de l'override de taux).
-- ============================================================

-- ------------------------------------------------------------
-- 1) HABILETÉS — gel/dégel par action, par citoyen ou pour tous.
--    cible_id = null  -> règle globale (s'applique à tout le monde
--                         qui n'a pas de règle spécifique pour cette action)
--    cible_id = <uuid> -> règle spécifique à ce citoyen (prioritaire
--                          sur la règle globale)
--    etat: 'gele_temporaire' (jusqu'à gele_jusqua), 'gele_definitif'
-- ------------------------------------------------------------
create table if not exists custom_habiletes (
  id           uuid primary key default gen_random_uuid(),
  cible_id     uuid references citoyens(id) on delete cascade,
  action       text not null check (action in (
                 'tso','tsq','remboursement_dettes','remboursement_prets',
                 'virement_familial','virement_business','virement_econome',
                 'virement_considerable','achat_permis','payer_constat',
                 'supprimer_constat','demande_chomage','demande_retraite',
                 'envoyer_message','envoyer_document'
               )),
  etat         text not null check (etat in ('gele_temporaire','gele_definitif')),
  gele_jusqua  timestamptz,
  defini_par   text,
  defini_le    timestamptz not null default now(),
  unique (cible_id, action)
);
alter table custom_habiletes enable row level security;
-- Pas de policy : lecture/écriture uniquement via les fonctions ci-dessous
-- et via custom_habilite() (stable, appelée par les triggers).

create or replace function custom_habilite(p_citoyen_id uuid, p_action text)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_regle custom_habiletes;
begin
  select * into v_regle from custom_habiletes where cible_id = p_citoyen_id and action = p_action;
  if v_regle is null then
    select * into v_regle from custom_habiletes where cible_id is null and action = p_action;
  end if;
  if v_regle is null then return true; end if;
  if v_regle.etat = 'gele_temporaire' and v_regle.gele_jusqua is not null and v_regle.gele_jusqua <= now() then
    return true; -- gel temporaire expiré
  end if;
  return false;
end; $$;

create or replace function custom_definir_habilite(p_token text, p_cible_id uuid, p_action text, p_definitif boolean, p_duree_secondes int default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_compte text;
begin
  v_compte := custom_session_active(p_token);
  if v_compte is null then raise exception 'Session invalide ou expirée.'; end if;

  insert into custom_habiletes (cible_id, action, etat, gele_jusqua, defini_par)
  values (
    p_cible_id, p_action,
    case when p_definitif then 'gele_definitif' else 'gele_temporaire' end,
    case when p_definitif then null else now() + make_interval(secs => coalesce(p_duree_secondes, 3600)) end,
    v_compte
  )
  on conflict (cible_id, action) do update
    set etat = excluded.etat, gele_jusqua = excluded.gele_jusqua, defini_par = excluded.defini_par, defini_le = now();
end; $$;
grant execute on function custom_definir_habilite(text, uuid, text, boolean, int) to anon, authenticated;

create or replace function custom_reactiver_habilite(p_token text, p_cible_id uuid, p_action text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if custom_session_active(p_token) is null then raise exception 'Session invalide ou expirée.'; end if;
  if p_cible_id is null then
    delete from custom_habiletes where cible_id is null and action = p_action;
  else
    delete from custom_habiletes where cible_id = p_cible_id and action = p_action;
  end if;
end; $$;
grant execute on function custom_reactiver_habilite(text, uuid, text) to anon, authenticated;

create or replace function custom_lister_habiletes(p_token text)
returns table (id uuid, cible_id uuid, cible_username text, action text, etat text, gele_jusqua timestamptz, defini_par text, defini_le timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if custom_session_active(p_token) is null then raise exception 'Session invalide ou expirée.'; end if;
  return query
    select h.id, h.cible_id, c.username, h.action, h.etat, h.gele_jusqua, h.defini_par, h.defini_le
    from custom_habiletes h left join citoyens c on c.id = h.cible_id
    order by h.cible_id nulls first, h.action;
end; $$;
grant execute on function custom_lister_habiletes(text) to anon, authenticated;

-- ------------------------------------------------------------
-- 2) TRIGGERS D'APPLICATION — bloquent réellement l'action si
--    l'habileté est gelée. Ne s'appliquent qu'aux actions faites
--    par le citoyen lui-même (auth.uid() = la personne concernée) :
--    une action faite par vous depuis custom.html (auth.uid() est
--    toujours null là-bas) ou par un agent/gouvernement n'est
--    jamais bloquée par ce système.
-- ------------------------------------------------------------
create or replace function _custom_verifier_transfert()
returns trigger language plpgsql as $$
declare v_action text;
begin
  if auth.uid() is distinct from new.expediteur_id then return new; end if;
  v_action := case new.type when 'famille' then 'virement_familial' when 'business' then 'virement_business' when 'econome' then 'virement_econome' end;
  if v_action is not null and not custom_habilite(new.expediteur_id, v_action) then
    raise exception 'Cette action est désactivée pour votre compte.';
  end if;
  return new;
end; $$;
drop trigger if exists custom_gel_transferts on transferts;
create trigger custom_gel_transferts before insert on transferts
  for each row execute function _custom_verifier_transfert();

create or replace function _custom_verifier_virement_considerable()
returns trigger language plpgsql as $$
begin
  if auth.uid() is distinct from new.expediteur_id then return new; end if;
  if not custom_habilite(new.expediteur_id, 'virement_considerable') then
    raise exception 'Cette action est désactivée pour votre compte.';
  end if;
  return new;
end; $$;
drop trigger if exists custom_gel_virement_considerable on virements_considerables;
create trigger custom_gel_virement_considerable before insert on virements_considerables
  for each row execute function _custom_verifier_virement_considerable();

create or replace function _custom_verifier_permis()
returns trigger language plpgsql as $$
begin
  if auth.uid() is distinct from new.citoyen_id then return new; end if;
  if not custom_habilite(new.citoyen_id, 'achat_permis') then
    raise exception 'Cette action est désactivée pour votre compte.';
  end if;
  return new;
end; $$;
drop trigger if exists custom_gel_permis on permis_citoyens;
create trigger custom_gel_permis before insert on permis_citoyens
  for each row execute function _custom_verifier_permis();

create or replace function _custom_verifier_constat()
returns trigger language plpgsql as $$
begin
  if auth.uid() is distinct from new.destinataire_id then return new; end if;
  if (new.paye and not old.paye) and not custom_habilite(new.destinataire_id, 'payer_constat') then
    raise exception 'Cette action est désactivée pour votre compte.';
  end if;
  if (new.supprime_par_citoyen and not old.supprime_par_citoyen) and not custom_habilite(new.destinataire_id, 'supprimer_constat') then
    raise exception 'Cette action est désactivée pour votre compte.';
  end if;
  return new;
end; $$;
drop trigger if exists custom_gel_constat on constats_infraction;
create trigger custom_gel_constat before update on constats_infraction
  for each row execute function _custom_verifier_constat();

create or replace function _custom_verifier_epargne()
returns trigger language plpgsql as $$
declare v_action text;
begin
  if auth.uid() is distinct from new.citoyen_id then return new; end if;
  v_action := case new.type when 'chomage' then 'demande_chomage' when 'retraite' then 'demande_retraite' end;
  if v_action is not null and not custom_habilite(new.citoyen_id, v_action) then
    raise exception 'Cette action est désactivée pour votre compte.';
  end if;
  return new;
end; $$;
drop trigger if exists custom_gel_epargne on demandes_epargne;
create trigger custom_gel_epargne before insert on demandes_epargne
  for each row execute function _custom_verifier_epargne();

create or replace function _custom_verifier_message()
returns trigger language plpgsql as $$
begin
  if new.type <> 'normal' then return new; end if;
  if auth.uid() is distinct from new.expediteur_id then return new; end if;
  if not custom_habilite(new.expediteur_id, 'envoyer_message') then
    raise exception 'Cette action est désactivée pour votre compte.';
  end if;
  return new;
end; $$;
drop trigger if exists custom_gel_message on messages;
create trigger custom_gel_message before insert on messages
  for each row execute function _custom_verifier_message();

create or replace function _custom_verifier_document()
returns trigger language plpgsql as $$
begin
  if auth.uid() is distinct from new.expediteur_id then return new; end if;
  if not custom_habilite(new.expediteur_id, 'envoyer_document') then
    raise exception 'Cette action est désactivée pour votre compte.';
  end if;
  return new;
end; $$;
drop trigger if exists custom_gel_document on documents_contractuels;
create trigger custom_gel_document before insert on documents_contractuels
  for each row execute function _custom_verifier_document();

create or replace function _custom_verifier_citoyens()
returns trigger language plpgsql as $$
begin
  if auth.uid() is distinct from old.id then return new; end if; -- pas une action du citoyen sur sa propre fiche : jamais bloqué (custom, agent, admin...)
  if new.dettes < old.dettes and not custom_habilite(old.id, 'remboursement_dettes') then
    raise exception 'Cette action est désactivée pour votre compte.';
  end if;
  if new.prets < old.prets and not custom_habilite(old.id, 'remboursement_prets') then
    raise exception 'Cette action est désactivée pour votre compte.';
  end if;
  if old.tso_secondes_restantes = 0 and new.tso_secondes_restantes > 0 and not custom_habilite(old.id, 'tso') then
    raise exception 'Cette action est désactivée pour votre compte.';
  end if;
  if old.tsq_secondes_restantes = 0 and new.tsq_secondes_restantes > 0 and not custom_habilite(old.id, 'tsq') then
    raise exception 'Cette action est désactivée pour votre compte.';
  end if;
  return new;
end; $$;
drop trigger if exists custom_gel_citoyens on citoyens;
create trigger custom_gel_citoyens before update on citoyens
  for each row execute function _custom_verifier_citoyens();

-- ------------------------------------------------------------
-- 3) OVERRIDE DES CHAMPS DU FICHIER CAS (prénom, nom, expiration,
--    protection, agent de la paix, salaire par minute). Clé =
--    le code encrypté tel qu'écrit dans num_CAS.txt. Un champ
--    laissé vide = pas d'override, la valeur du .txt continue de
--    s'appliquer. Lecture publique (nécessaire : elle est
--    consultée par n'importe quel visiteur non connecté au moment
--    de l'inscription, exactement comme num_CAS.txt lui-même).
-- ------------------------------------------------------------
create table if not exists custom_override_cas (
  code_encrypte             text primary key,
  prenom_legal              text,
  nom_legal                 text,
  date_expiration           date,
  protection_gouvernementale boolean,
  agent_paix                boolean,
  salaire_par_minute        numeric,
  defini_par                text,
  defini_le                 timestamptz not null default now()
);
alter table custom_override_cas enable row level security;

create or replace function custom_lire_override_cas(p_code text)
returns setof custom_override_cas
language sql stable security definer set search_path = public as $$
  select * from custom_override_cas where code_encrypte = p_code;
$$;
grant execute on function custom_lire_override_cas(text) to anon, authenticated;

create or replace function custom_definir_override_cas(
  p_token text, p_code text, p_prenom_legal text, p_nom_legal text,
  p_date_expiration date, p_protection_gouvernementale boolean,
  p_agent_paix boolean, p_salaire_par_minute numeric
) returns void
language plpgsql security definer set search_path = public as $$
declare v_compte text;
begin
  v_compte := custom_session_active(p_token);
  if v_compte is null then raise exception 'Session invalide ou expirée.'; end if;

  insert into custom_override_cas (code_encrypte, prenom_legal, nom_legal, date_expiration, protection_gouvernementale, agent_paix, salaire_par_minute, defini_par)
  values (p_code, p_prenom_legal, p_nom_legal, p_date_expiration, p_protection_gouvernementale, p_agent_paix, p_salaire_par_minute, v_compte)
  on conflict (code_encrypte) do update set
    prenom_legal = excluded.prenom_legal, nom_legal = excluded.nom_legal,
    date_expiration = excluded.date_expiration, protection_gouvernementale = excluded.protection_gouvernementale,
    agent_paix = excluded.agent_paix, salaire_par_minute = excluded.salaire_par_minute,
    defini_par = excluded.defini_par, defini_le = now();
end; $$;
grant execute on function custom_definir_override_cas(text, text, text, text, date, boolean, boolean, numeric) to anon, authenticated;

create or replace function custom_supprimer_override_cas(p_token text, p_code text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if custom_session_active(p_token) is null then raise exception 'Session invalide ou expirée.'; end if;
  delete from custom_override_cas where code_encrypte = p_code;
end; $$;
grant execute on function custom_supprimer_override_cas(text, text) to anon, authenticated;

create or replace function custom_lister_overrides_cas(p_token text)
returns setof custom_override_cas
language plpgsql security definer set search_path = public as $$
begin
  if custom_session_active(p_token) is null then raise exception 'Session invalide ou expirée.'; end if;
  return query select * from custom_override_cas order by defini_le desc;
end; $$;
grant execute on function custom_lister_overrides_cas(text) to anon, authenticated;

-- ------------------------------------------------------------
-- 4) OVERRIDE DU TAUX DE TAXE SUR LE REVENU D'UN CITOYEN PRÉCIS.
--    Sans ça, mettre_a_jour_salaire recalcule toujours taux_revenu
--    depuis le salaire à chaque connexion et écraserait un
--    changement manuel : cette colonne prend le dessus.
-- ------------------------------------------------------------
alter table citoyens add column if not exists taux_revenu_override numeric;
alter table citoyens add column if not exists quota_virement_considerable numeric;

create or replace function mettre_a_jour_salaire(p_salaire numeric, p_police boolean)
returns citoyens language plpgsql security definer set search_path = public as $$
declare v_row citoyens; v_taux_override numeric;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  select taux_revenu_override into v_taux_override from citoyens where id = auth.uid();
  update citoyens
    set salaire = p_salaire,
        taux_revenu = coalesce(v_taux_override, calculer_taux_revenu(p_salaire)),
        est_agent_paix = p_police
    where id = auth.uid()
    returning * into v_row;
  return v_row;
end;
$$;

create or replace function custom_definir_taux_revenu(p_token text, p_citoyen_id uuid, p_taux numeric)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if custom_session_active(p_token) is null then raise exception 'Session invalide ou expirée.'; end if;
  update citoyens set taux_revenu_override = p_taux, taux_revenu = coalesce(p_taux, taux_revenu) where id = p_citoyen_id;
end; $$;
grant execute on function custom_definir_taux_revenu(text, uuid, numeric) to anon, authenticated;

create or replace function custom_supprimer_taux_revenu_override(p_token text, p_citoyen_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_salaire numeric;
begin
  if custom_session_active(p_token) is null then raise exception 'Session invalide ou expirée.'; end if;
  select salaire into v_salaire from citoyens where id = p_citoyen_id;
  update citoyens set taux_revenu_override = null, taux_revenu = calculer_taux_revenu(v_salaire) where id = p_citoyen_id;
end; $$;
grant execute on function custom_supprimer_taux_revenu_override(text, uuid) to anon, authenticated;

create or replace function custom_definir_quota_virement_considerable(p_token text, p_citoyen_id uuid, p_quota numeric)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if custom_session_active(p_token) is null then raise exception 'Session invalide ou expirée.'; end if;
  update citoyens set quota_virement_considerable = p_quota where id = p_citoyen_id;
end; $$;
grant execute on function custom_definir_quota_virement_considerable(text, uuid, numeric) to anon, authenticated;
-- NOTE : cette colonne est disponible pour l'affichage et pour vos propres
-- vérifications, mais n'est pas encore branchée dans envoyer_virement_considerable
-- (cette fonction a été redéfinie dans plusieurs fichiers et je ne peux pas
-- deviner sans risque laquelle est réellement active sur ta base — voir message).

create or replace function custom_definir_virements_illimites(p_token text, p_citoyen_id uuid, p_actif boolean, p_duree_secondes int default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if custom_session_active(p_token) is null then raise exception 'Session invalide ou expirée.'; end if;
  update citoyens set
    virements_illimites = p_actif,
    virements_illimites_jusqua = case when p_actif and p_duree_secondes is not null then now() + make_interval(secs => p_duree_secondes) else null end
  where id = p_citoyen_id;
end; $$;
grant execute on function custom_definir_virements_illimites(text, uuid, boolean, int) to anon, authenticated;

-- ------------------------------------------------------------
-- 5) PARAMÈTRES GLOBAUX (taux affichés) — clé/valeur, lecture
--    publique pour que l'affichage se mette à jour partout.
-- ------------------------------------------------------------
create table if not exists custom_parametres_globaux (
  cle    text primary key,
  valeur numeric not null,
  defini_par text,
  defini_le  timestamptz not null default now()
);
alter table custom_parametres_globaux enable row level security;

insert into custom_parametres_globaux (cle, valeur) values
  ('taux_retraite', 4), ('taux_chomage', 1), ('taux_parentalite', 0.25),
  ('taux_virement_familial', 5), ('taux_virement_business', 25), ('taux_virement_econome', 0.35)
on conflict (cle) do nothing;

create or replace function custom_lire_parametres()
returns setof custom_parametres_globaux
language sql stable security definer set search_path = public as $$
  select * from custom_parametres_globaux order by cle;
$$;
grant execute on function custom_lire_parametres() to anon, authenticated;

create or replace function custom_definir_parametre(p_token text, p_cle text, p_valeur numeric)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if custom_session_active(p_token) is null then raise exception 'Session invalide ou expirée.'; end if;
  insert into custom_parametres_globaux (cle, valeur, defini_par)
  values (p_cle, p_valeur, custom_session_active(p_token))
  on conflict (cle) do update set valeur = excluded.valeur, defini_par = excluded.defini_par, defini_le = now();
end; $$;
grant execute on function custom_definir_parametre(text, text, numeric) to anon, authenticated;
-- NOTE : ces paramètres alimentent l'affichage (patch JS fourni) mais ne
-- sont pas encore branchés dans le calcul réel des retenues par seconde
-- (deposer_revenu_citoyen) pour la même raison que ci-dessus.

-- ------------------------------------------------------------
-- 6) RECHERCHE + ÉDITION DIRECTE D'UN CITOYEN
-- ------------------------------------------------------------
create or replace function custom_rechercher_citoyen(p_token text, p_terme text)
returns setof citoyens
language plpgsql security definer set search_path = public as $$
begin
  if custom_session_active(p_token) is null then raise exception 'Session invalide ou expirée.'; end if;
  return query
    select * from citoyens
    where lower(username) = lower(p_terme) or code_social_encrypte = p_terme or id::text = p_terme
    limit 5;
end; $$;
grant execute on function custom_rechercher_citoyen(text, text) to anon, authenticated;

-- Tous les champs sont optionnels : ne passer que ceux à changer,
-- les autres (null) restent inchangés.
create or replace function custom_modifier_citoyen(
  p_token text, p_citoyen_id uuid,
  p_username text default null, p_nom text default null, p_prenom text default null,
  p_nom_complet text default null, p_date_naissance date default null,
  p_age_toutouien_inscription numeric default null, p_cree_le timestamptz default null,
  p_province_residence text default null, p_salaire numeric default null,
  p_est_agent_paix boolean default null, p_est_admin boolean default null,
  p_tresorerie_delta numeric default null, p_dettes_delta numeric default null,
  p_prets_delta numeric default null, p_argent_attendu_delta numeric default null
) returns citoyens
language plpgsql security definer set search_path = public as $$
declare v_row citoyens;
begin
  if custom_session_active(p_token) is null then raise exception 'Session invalide ou expirée.'; end if;

  update citoyens set
    username = coalesce(p_username, username),
    nom = coalesce(p_nom, nom),
    prenom = coalesce(p_prenom, prenom),
    nom_complet = coalesce(p_nom_complet, nom_complet),
    date_naissance = coalesce(p_date_naissance, date_naissance),
    age_toutouien_inscription = coalesce(p_age_toutouien_inscription, age_toutouien_inscription),
    cree_le = coalesce(p_cree_le, cree_le),
    province_residence = coalesce(p_province_residence, province_residence),
    salaire = coalesce(p_salaire, salaire),
    est_agent_paix = coalesce(p_est_agent_paix, est_agent_paix),
    est_admin = coalesce(p_est_admin, est_admin),
    tresorerie = tresorerie + coalesce(p_tresorerie_delta, 0),
    dettes = greatest(0, dettes + coalesce(p_dettes_delta, 0)),
    prets = greatest(0, prets + coalesce(p_prets_delta, 0)),
    argent_attendu = greatest(0, argent_attendu + coalesce(p_argent_attendu_delta, 0))
  where id = p_citoyen_id
  returning * into v_row;

  if v_row is null then raise exception 'Citoyen introuvable.'; end if;
  return v_row;
end; $$;
grant execute on function custom_modifier_citoyen(text, uuid, text, text, text, text, date, numeric, timestamptz, text, numeric, boolean, boolean, numeric, numeric, numeric, numeric) to anon, authenticated;

create or replace function custom_supprimer_citoyen(p_token text, p_citoyen_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if custom_session_active(p_token) is null then raise exception 'Session invalide ou expirée.'; end if;
  delete from auth.users where id = p_citoyen_id; -- cascade sur citoyens
end; $$;
grant execute on function custom_supprimer_citoyen(text, uuid) to anon, authenticated;
