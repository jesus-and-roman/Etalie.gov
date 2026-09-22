-- ============================================================
-- Correctif — gen_salt()/crypt() introuvables (pgcrypto vit dans
-- le schéma "extensions" chez Supabase, pas "public").
-- À exécuter après patch-custom-super-admin.sql. Ne recrée rien
-- d'autre, ne change aucune donnée.
-- ============================================================

create or replace function custom_bootstrap_premier_compte(p_numero_compte text, p_secret_key text, p_cle_maitre text)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if exists (select 1 from custom_comptes) then
    raise exception 'Un compte custom existe déjà. Utilise custom_creer_compte() ou le formulaire de demande.';
  end if;

  -- !!! REMPLACE CETTE VALEUR avant d'exécuter ce patch dans Supabase !!!
  if p_cle_maitre <> '000000000000000000000000' then
    raise exception 'Clé maître invalide.';
  end if;

  if char_length(p_secret_key) < 24 then
    raise exception 'La secret key doit contenir au moins 24 caractères.';
  end if;

  insert into custom_comptes (numero_compte, secret_key_hash, cree_par, note)
  values (p_numero_compte, crypt(p_secret_key, gen_salt('bf')), null, 'Compte fondateur (bootstrap)');
end; $$;

create or replace function custom_connexion(p_numero_compte text, p_secret_key text)
returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_hash   text;
  v_actif  boolean;
  v_token  text;
begin
  select secret_key_hash, actif into v_hash, v_actif
  from custom_comptes where numero_compte = p_numero_compte;

  if v_hash is null or v_actif is not true or crypt(p_secret_key, v_hash) <> v_hash then
    perform pg_sleep(1);
    raise exception 'Identifiants invalides.';
  end if;

  delete from custom_sessions where expire_le < now();

  insert into custom_sessions (numero_compte) values (p_numero_compte)
  returning token into v_token;

  update custom_comptes set derniere_connexion = now() where numero_compte = p_numero_compte;

  return v_token;
end; $$;

create or replace function custom_creer_compte(p_token text, p_nouveau_numero text, p_nouvelle_secret_key text, p_note text default null)
returns void
language plpgsql security definer set search_path = public, extensions as $$
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

create or replace function custom_traiter_demande(p_token text, p_id uuid, p_approuver boolean)
returns void
language plpgsql security definer set search_path = public, extensions as $$
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
    exception when others then null;
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
