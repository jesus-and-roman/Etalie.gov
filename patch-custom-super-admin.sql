-- ============================================================
-- Correctif — Compte(s) "custom" (super-admin caché)
-- À exécuter APRÈS tous les patches existants (dernier de la liste,
-- après fix-2-permis-adresse.sql). N'écrase et ne modifie AUCUNE
-- table/fonction existante : 100% additif.
--
-- Accès uniquement via la page custom.html (non liée dans le site,
-- non référencée dans aucune navigation).
-- ============================================================

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- 1) COMPTES CUSTOM (le "super-admin", au-dessus de est_admin)
--    Aucune policy = invisible depuis le client, comme cas_valides.
--    Seules les fonctions security definer ci-dessous y touchent.
-- ------------------------------------------------------------
create table if not exists custom_comptes (
  numero_compte      text primary key check (char_length(numero_compte) between 4 and 64),
  secret_key_hash    text not null,
  actif              boolean not null default true,
  cree_par           text references custom_comptes(numero_compte) on delete set null,
  cree_le            timestamptz not null default now(),
  derniere_connexion timestamptz,
  note               text
);
alter table custom_comptes enable row level security;

-- ------------------------------------------------------------
-- 2) SESSIONS CUSTOM (jetons temporaires, remplacent auth.users
--    pour ce système parallèle — expiration 12h)
-- ------------------------------------------------------------
create table if not exists custom_sessions (
  token       text primary key default encode(gen_random_bytes(32), 'hex'),
  numero_compte text not null references custom_comptes(numero_compte) on delete cascade,
  cree_le     timestamptz not null default now(),
  expire_le   timestamptz not null default (now() + interval '12 hours')
);
alter table custom_sessions enable row level security;

-- ------------------------------------------------------------
-- 3) DEMANDES D'ACCÈS CUSTOM (formulaire public sur custom.html)
--    La secret key demandée n'est JAMAIS lisible directement par le
--    client (pas de policy select) : elle ne transite que par
--    custom_lister_demandes(), qui l'efface dès que la demande est
--    traitée (approuvée ou refusée). Un seul comptes custom actif
--    peut donc la voir en clair, et uniquement pendant l'attente.
-- ------------------------------------------------------------
create table if not exists custom_demandes (
  id                    uuid primary key default gen_random_uuid(),
  demandeur_username    text not null,   -- pseudo du citoyen sur le portail-citoyen
  demandeur_code_jeu    text not null,   -- code d'identification/contact interne au jeu
  numero_compte_demande text not null check (char_length(numero_compte_demande) between 4 and 64),
  secret_key_demandee   text,            -- effacée après traitement, voir trigger + fonctions
  statut                text not null default 'en_attente' check (statut in ('en_attente','approuvee','refusee')),
  cree_le               timestamptz not null default now(),
  traite_par            text references custom_comptes(numero_compte) on delete set null,
  traite_le             timestamptz,
  constraint longueur_secret_key check (char_length(secret_key_demandee) >= 24)
);
alter table custom_demandes enable row level security;

-- N'importe qui peut soumettre une demande (même déconnecté du portail)
drop policy if exists "Soumission publique d'une demande custom" on custom_demandes;
create policy "Soumission publique d'une demande custom"
  on custom_demandes for insert
  with check (true);
grant insert on custom_demandes to anon, authenticated;
-- Pas de policy select : la lecture ne passe que par custom_lister_demandes()

-- Verrouille les champs qu'un demandeur ne doit jamais pouvoir fixer lui-même
create or replace function verrouiller_insertion_demande_custom()
returns trigger language plpgsql as $$
begin
  new.statut := 'en_attente';
  new.traite_par := null;
  new.traite_le := null;
  new.cree_le := now();
  return new;
end; $$;
drop trigger if exists avant_insertion_demande_custom on custom_demandes;
create trigger avant_insertion_demande_custom
  before insert on custom_demandes
  for each row execute function verrouiller_insertion_demande_custom();

-- ------------------------------------------------------------
-- 4) SESSION ACTIVE ? (fonction utilitaire interne)
-- ------------------------------------------------------------
create or replace function custom_session_active(p_token text)
returns text
language sql stable security definer set search_path = public as $$
  select numero_compte from custom_sessions
  where token = p_token and expire_le > now();
$$;

-- ------------------------------------------------------------
-- 5) BOOTSTRAP — crée l'unique premier compte custom (fondateur).
--    Ne fonctionne qu'une seule fois : dès qu'un compte custom
--    existe, cette fonction refuse pour toujours. Change la clé
--    maître ci-dessous avant d'exécuter ce patch, exécute la
--    fonction une fois depuis custom.html, puis considère-la morte.
-- ------------------------------------------------------------
create or replace function custom_bootstrap_premier_compte(p_numero_compte text, p_secret_key text, p_cle_maitre text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from custom_comptes) then
    raise exception 'Un compte custom existe déjà. Utilise custom_creer_compte() ou le formulaire de demande.';
  end if;

  -- !!! REMPLACE CETTE VALEUR avant d'exécuter ce patch dans Supabase !!!
  if p_cle_maitre <> 'CHANGE_MOI_AVANT_EXECUTION' then
    raise exception 'Clé maître invalide.';
  end if;

  if char_length(p_secret_key) < 24 then
    raise exception 'La secret key doit contenir au moins 24 caractères.';
  end if;

  insert into custom_comptes (numero_compte, secret_key_hash, cree_par, note)
  values (p_numero_compte, crypt(p_secret_key, gen_salt('bf')), null, 'Compte fondateur (bootstrap)');
end; $$;
grant execute on function custom_bootstrap_premier_compte(text, text, text) to anon, authenticated;

-- ------------------------------------------------------------
-- 6) CONNEXION / DÉCONNEXION
-- ------------------------------------------------------------
create or replace function custom_connexion(p_numero_compte text, p_secret_key text)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_hash   text;
  v_actif  boolean;
  v_token  text;
begin
  select secret_key_hash, actif into v_hash, v_actif
  from custom_comptes where numero_compte = p_numero_compte;

  if v_hash is null or v_actif is not true or crypt(p_secret_key, v_hash) <> v_hash then
    perform pg_sleep(1); -- ralentit un bruteforce automatisé
    raise exception 'Identifiants invalides.';
  end if;

  delete from custom_sessions where expire_le < now();

  insert into custom_sessions (numero_compte) values (p_numero_compte)
  returning token into v_token;

  update custom_comptes set derniere_connexion = now() where numero_compte = p_numero_compte;

  return v_token;
end; $$;
grant execute on function custom_connexion(text, text) to anon, authenticated;

create or replace function custom_deconnexion(p_token text)
returns void language sql security definer set search_path = public as $$
  delete from custom_sessions where token = p_token;
$$;
grant execute on function custom_deconnexion(text) to anon, authenticated;

-- ------------------------------------------------------------
-- 7) CRÉER UN AUTRE COMPTE CUSTOM DIRECTEMENT (sans passer par une demande)
-- ------------------------------------------------------------
create or replace function custom_creer_compte(p_token text, p_nouveau_numero text, p_nouvelle_secret_key text, p_note text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_compte text;
begin
  v_compte := custom_session_active(p_token);
  if v_compte is null then raise exception 'Session invalide ou expirée.'; end if;

  if char_length(p_nouvelle_secret_key) < 24 then
    raise exception 'La secret key doit contenir au moins 24 caractères.';
  end if;

  insert into custom_comptes (numero_compte, secret_key_hash, cree_par, note)
  values (p_nouveau_numero, crypt(p_nouvelle_secret_key, gen_salt('bf')), v_compte, p_note);
end; $$;
grant execute on function custom_creer_compte(text, text, text, text) to anon, authenticated;

create or replace function custom_desactiver_compte(p_token text, p_numero_compte_cible text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if custom_session_active(p_token) is null then raise exception 'Session invalide ou expirée.'; end if;
  update custom_comptes set actif = false where numero_compte = p_numero_compte_cible;
  delete from custom_sessions where numero_compte = p_numero_compte_cible;
end; $$;
grant execute on function custom_desactiver_compte(text, text) to anon, authenticated;

create or replace function custom_lister_comptes(p_token text)
returns table (numero_compte text, actif boolean, cree_par text, cree_le timestamptz, derniere_connexion timestamptz, note text)
language plpgsql security definer set search_path = public as $$
begin
  if custom_session_active(p_token) is null then raise exception 'Session invalide ou expirée.'; end if;
  return query
    select c.numero_compte, c.actif, c.cree_par, c.cree_le, c.derniere_connexion, c.note
    from custom_comptes c order by c.cree_le asc;
end; $$;
grant execute on function custom_lister_comptes(text) to anon, authenticated;

-- ------------------------------------------------------------
-- 8) FILE DES DEMANDES (lecture + traitement V/X avec message bot)
--    La secret key demandée n'est retournée que pour les demandes
--    encore en_attente. Dès qu'une demande est traitée elle est
--    effacée en base (colonne mise à null) : personne ne peut plus
--    jamais la relire, même un compte custom.
-- ------------------------------------------------------------
create or replace function custom_lister_demandes(p_token text)
returns table (
  id uuid, demandeur_username text, demandeur_code_jeu text,
  numero_compte_demande text, secret_key_demandee text,
  statut text, cree_le timestamptz, traite_par text, traite_le timestamptz
)
language plpgsql security definer set search_path = public as $$
begin
  if custom_session_active(p_token) is null then raise exception 'Session invalide ou expirée.'; end if;
  return query
    select d.id, d.demandeur_username, d.demandeur_code_jeu, d.numero_compte_demande,
           case when d.statut = 'en_attente' then d.secret_key_demandee else null end,
           d.statut, d.cree_le, d.traite_par, d.traite_le
    from custom_demandes d
    order by (d.statut = 'en_attente') desc, d.cree_le desc;
end; $$;
grant execute on function custom_lister_demandes(text) to anon, authenticated;

create or replace function custom_envoyer_message_bot(p_token text, p_destinataire_username text, p_titre text, p_contenu text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_dest uuid;
begin
  if custom_session_active(p_token) is null then raise exception 'Session invalide ou expirée.'; end if;

  select id into v_dest from citoyens where lower(username) = lower(p_destinataire_username);
  if v_dest is null then raise exception 'Destinataire introuvable sur le portail citoyen.'; end if;

  insert into messages (type, destinataire_id, nom_affiche, liste_gouvernementale, titre, contenu)
  values ('gouvernemental', v_dest, 'Sécurité d''État', 'anonyme', p_titre, p_contenu);
end; $$;
grant execute on function custom_envoyer_message_bot(text, text, text, text) to anon, authenticated;

create or replace function custom_traiter_demande(p_token text, p_id uuid, p_approuver boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_compte    text;
  v_demande   custom_demandes%rowtype;
begin
  v_compte := custom_session_active(p_token);
  if v_compte is null then raise exception 'Session invalide ou expirée.'; end if;

  select * into v_demande from custom_demandes where id = p_id for update;
  if v_demande is null then raise exception 'Demande introuvable.'; end if;
  if v_demande.statut <> 'en_attente' then raise exception 'Cette demande a déjà été traitée.'; end if;

  if p_approuver then
    if exists (select 1 from custom_comptes where numero_compte = v_demande.numero_compte_demande) then
      raise exception 'Ce numéro de compte custom existe déjà — refuse la demande et redemande un autre numéro.';
    end if;

    insert into custom_comptes (numero_compte, secret_key_hash, cree_par, note)
    values (v_demande.numero_compte_demande, crypt(v_demande.secret_key_demandee, gen_salt('bf')), v_compte,
            'Approuvé via demande de ' || v_demande.demandeur_username);

    update custom_demandes
       set statut = 'approuvee', secret_key_demandee = null, traite_par = v_compte, traite_le = now()
     where id = p_id;

    begin
      perform custom_envoyer_message_bot(p_token, v_demande.demandeur_username,
        'Demande d''accès approuvée',
        'Ta demande d''accès a été approuvée. Le compte que tu as demandé est maintenant actif — connecte-toi avec le numéro de compte et la secret key que tu as choisis.');
    exception when others then null; -- le message échoue si le pseudo ne correspond à aucun citoyen : n'empêche pas l'approbation
    end;
  else
    update custom_demandes
       set statut = 'refusee', secret_key_demandee = null, traite_par = v_compte, traite_le = now()
     where id = p_id;

    begin
      perform custom_envoyer_message_bot(p_token, v_demande.demandeur_username,
        'Demande d''accès refusée',
        'Ta demande d''accès a été refusée.');
    exception when others then null;
    end;
  end if;
end; $$;
grant execute on function custom_traiter_demande(text, uuid, boolean) to anon, authenticated;

-- ------------------------------------------------------------
-- 9) CONTRÔLE TOTAL — console SQL brute + explorateur de tables.
--    Tourne avec les droits du propriétaire des fonctions (contourne
--    RLS). Aucune restriction de commande : SELECT, UPDATE, DELETE,
--    DROP, tout est permis. C'est voulu — c'est le point de ce compte.
-- ------------------------------------------------------------
create or replace function custom_lister_tables(p_token text)
returns table (nom_table text)
language plpgsql security definer set search_path = public as $$
begin
  if custom_session_active(p_token) is null then raise exception 'Session invalide ou expirée.'; end if;
  return query select tablename::text from pg_tables where schemaname = 'public' order by 1;
end; $$;
grant execute on function custom_lister_tables(text) to anon, authenticated;

create or replace function custom_executer_sql(p_token text, p_sql text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_resultat jsonb;
begin
  if custom_session_active(p_token) is null then raise exception 'Session invalide ou expirée.'; end if;

  begin
    execute format('select coalesce(jsonb_agg(t), ''[]''::jsonb) from (%s) t', p_sql) into v_resultat;
  exception when others then
    -- pas une requête qui retourne des lignes (UPDATE/DELETE/DDL/etc.) : exécution directe
    execute p_sql;
    v_resultat := jsonb_build_object('statut', 'exécuté sans retour de lignes');
  end;

  return v_resultat;
end; $$;
grant execute on function custom_executer_sql(text, text) to anon, authenticated;
