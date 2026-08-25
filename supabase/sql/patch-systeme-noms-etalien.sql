-- ============================================================
-- patch-systeme-noms-etalien.sql
--
-- Passage de l'ancien système :
--   prenom + nom
--
-- vers le système étalien :
--   nom_complet
--
-- Formes acceptées :
--   Benk Margus
--   Benk Margus hwol Gucie
--   Benk Margus hw. Gucie
--   Benk Margus hw. G.
--   B. Margus hw. G.
--
-- IMPORTANT :
-- nom_complet devient la source de vérité pour l'identité légale.
--
-- prenom / nom sont conservés temporairement comme champs de
-- compatibilité avec les anciennes fonctions du portail.
-- ============================================================


-- ============================================================
-- 1. NOUVEAU CHAMP : NOM LÉGAL COMPLET
-- ============================================================

alter table citoyens
  add column if not exists nom_complet text;


-- ============================================================
-- 2. MIGRATION DES COMPTES EXISTANTS
--
-- Ancien système :
--   prenom = Benk
--   nom    = Margus
--
-- devient :
--   nom_complet = Benk Margus
-- ============================================================

update citoyens
set nom_complet = trim(
  concat_ws(' ', nullif(trim(prenom), ''), nullif(trim(nom), ''))
)
where nom_complet is null
   or trim(nom_complet) = '';


-- On interdit maintenant un nom légal vide.
alter table citoyens
  alter column nom_complet set not null;


-- ============================================================
-- 3. EMAIL : DEVENU OPTIONNEL
-- ============================================================

alter table citoyens
  alter column email drop not null;


-- ============================================================
-- 4. FONCTION DE VALIDATION DU NOM ÉTALIEN
--
-- Lettres autorisées :
-- A-Z sauf F J L Q X
-- a-z sauf f j l q x
-- ä ö í ü ë ŕ
--
-- Formes :
--
-- 1. Benk Margus
-- 2. Benk Margus hwol Gucie
-- 3. Benk Margus hw. Gucie
-- 4. Benk Margus hw. G.
-- 5. B. Margus hw. G.
-- ============================================================

create or replace function nom_etalien_valide(p_nom text)
returns boolean
language sql
immutable
as $$
  select p_nom ~
    '^(?:' ||

    -- Complet-1
    '[A-EG-IKM-PR-WYZÄÖÍÜËŔ][a-eg-ikm-pr-wyzäöíüëŕ]* ' ||
    '[A-EG-IKM-PR-WYZÄÖÍÜËŔ][a-eg-ikm-pr-wyzäöíüëŕ]*' ||

    '|' ||

    -- Complet-2
    '[A-EG-IKM-PR-WYZÄÖÍÜËŔ][a-eg-ikm-pr-wyzäöíüëŕ]* ' ||
    '[A-EG-IKM-PR-WYZÄÖÍÜËŔ][a-eg-ikm-pr-wyzäöíüëŕ]* hwol ' ||
    '[A-EG-IKM-PR-WYZÄÖÍÜËŔ][a-eg-ikm-pr-wyzäöíüëŕ]*' ||

    '|' ||

    -- ABR-1
    '[A-EG-IKM-PR-WYZÄÖÍÜËŔ][a-eg-ikm-pr-wyzäöíüëŕ]* ' ||
    '[A-EG-IKM-PR-WYZÄÖÍÜËŔ][a-eg-ikm-pr-wyzäöíüëŕ]* hw\. ' ||
    '[A-EG-IKM-PR-WYZÄÖÍÜËŔ][a-eg-ikm-pr-wyzäöíüëŕ]*' ||

    '|' ||

    -- ABR-2
    '[A-EG-IKM-PR-WYZ]\. ' ||
    '[A-EG-IKM-PR-WYZÄÖÍÜËŔ][a-eg-ikm-pr-wyzäöíüëŕ]* hw\. ' ||
    '[A-EG-IKM-PR-WYZ]\.' ||

    ')$';
$$;


-- ============================================================
-- 5. FONCTION : NOM COMPLET -> ANCIENS CHAMPS DE COMPATIBILITÉ
--
-- Exemple :
--   Benk Margus hwol Gucie
--
-- devient temporairement :
--   prenom = Benk
--   nom    = Margus hwol Gucie
--
-- Cela permet aux anciennes fonctions de continuer à fonctionner
-- pendant la migration du portail.
-- ============================================================

create or replace function synchroniser_nom_legacy()
returns trigger
language plpgsql
as $$
declare
  v_espace int;
begin
  if new.nom_complet is null or trim(new.nom_complet) = '' then
    raise exception 'Le nom légal complet est obligatoire.';
  end if;

  v_espace := position(' ' in trim(new.nom_complet));

  if v_espace = 0 then
    raise exception 'Le nom légal doit contenir au minimum deux mots.';
  end if;

  new.prenom := trim(left(new.nom_complet, v_espace - 1));
  new.nom := trim(substr(new.nom_complet, v_espace + 1));

  return new;
end;
$$;


drop trigger if exists synchroniser_nom_legacy_trigger
on citoyens;

create trigger synchroniser_nom_legacy_trigger
before insert or update of nom_complet
on citoyens
for each row
execute function synchroniser_nom_legacy();


-- ============================================================
-- 6. FONCTION DE CONNEXION PAR USERNAME / EMAIL
--
-- Si un citoyen n'a pas de courriel réel, le portail utilisera
-- une adresse technique dans Supabase Auth.
-- ============================================================

create or replace function email_pour_identifiant(p_identifiant text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select u.email
  from citoyens c
  join auth.users u on u.id = c.id
  where lower(c.username) = lower(trim(p_identifiant))
     or (
       c.email is not null
       and lower(c.email) = lower(trim(p_identifiant))
     )
  limit 1;
$$;

grant execute on function email_pour_identifiant(text)
to anon;


-- ============================================================
-- 7. REMPLACEMENT COMPLET DE inscrire_citoyen
--
-- On supprime les anciennes signatures pour éviter les
-- ambiguïtés RPC.
-- ============================================================

drop function if exists inscrire_citoyen(
  text,text,text,text,text,date
);

drop function if exists inscrire_citoyen(
  text,text,text,text,text,date,boolean
);

drop function if exists inscrire_citoyen(
  text,text,text,text,text,date,boolean,boolean,numeric
);

drop function if exists inscrire_citoyen(
  text,text,text,text,text,date,boolean,boolean,numeric,text
);


create or replace function inscrire_citoyen(
  p_username text,
  p_email text,
  p_nom_complet text,
  p_code_social_encrypte text,
  p_date_naissance date,
  p_protege_gouvernement boolean default false,
  p_police boolean default false,
  p_salaire numeric default 12.5,
  p_province text default null
)
returns citoyens
language plpgsql
security definer
set search_path = public
as $$
declare
  v_age numeric;
  v_row citoyens;
  v_est_admin boolean;
  v_premier_mot text;
  v_reste_nom text;
begin

  if auth.uid() is null then
    raise exception 'Utilisateur non authentifié.';
  end if;


  -- ----------------------------------------------------------
  -- Username
  -- ----------------------------------------------------------

  if p_username is null
     or char_length(trim(p_username)) < 3
     or char_length(trim(p_username)) > 24 then
    raise exception 'Nom d''utilisateur invalide.';
  end if;


  -- ----------------------------------------------------------
  -- Nom légal
  -- ----------------------------------------------------------

  if p_nom_complet is null
     or not nom_etalien_valide(trim(p_nom_complet)) then
    raise exception
      'Le nom légal ne respecte pas les règles de nom étaliennes.';
  end if;


  -- ----------------------------------------------------------
  -- CAS
  -- ----------------------------------------------------------

  if exists (
    select 1
    from citoyens
    where code_social_encrypte = p_code_social_encrypte
  ) then
    raise exception
      'Ce code d''assurance social est déjà associé à un compte.';
  end if;


  -- ----------------------------------------------------------
  -- Âge
  -- ----------------------------------------------------------

  v_age := age_toutouien(p_date_naissance);

  if v_age < 20 then
    raise exception
      'Majorité civile non atteinte (20 ans toutouïens requis, actuel: %).',
      round(v_age, 2);
  end if;


  -- ----------------------------------------------------------
  -- Province
  -- ----------------------------------------------------------

  if p_province is not null
     and not exists (
       select 1
       from province_residence_banque
       where province = p_province
     ) then
    raise exception 'Province de résidence invalide.';
  end if;


  -- ----------------------------------------------------------
  -- Admin
  --
  -- Le CAS ADMIN/ADMIN donne le rôle administrateur.
  -- ----------------------------------------------------------

  v_est_admin :=
    upper(trim(p_nom_complet)) = 'ADMIN ADMIN';


  -- ----------------------------------------------------------
  -- Compatibilité avec les anciennes colonnes
  -- ----------------------------------------------------------

  v_premier_mot :=
    split_part(trim(p_nom_complet), ' ', 1);

  v_reste_nom :=
    trim(
      substr(
        trim(p_nom_complet),
        char_length(v_premier_mot) + 2
      )
    );


  -- ----------------------------------------------------------
  -- Création du citoyen
  -- ----------------------------------------------------------

  insert into citoyens (
    id,
    username,
    email,
    nom_complet,

    -- Compatibilité ancienne interface
    prenom,
    nom,

    code_social_encrypte,
    date_naissance,
    age_toutouien_inscription,
    est_admin,
    est_agent_paix,
    salaire,
    taux_revenu,
    province_residence
  )
  values (
    auth.uid(),
    trim(p_username),
    nullif(trim(p_email), ''),
    trim(p_nom_complet),

    v_premier_mot,
    v_reste_nom,

    p_code_social_encrypte,
    p_date_naissance,
    v_age,
    v_est_admin,
    p_police,
    p_salaire,
    calculer_taux_revenu(p_salaire),
    p_province
  )
  returning *
  into v_row;


  return v_row;

end;
$$;


grant execute on function inscrire_citoyen(
  text,text,text,text,date,boolean,boolean,numeric,text
)
to authenticated;


-- ============================================================
-- 8. SYNCHRONISER LES ANCIENS COMPTES
-- ============================================================

update citoyens
set nom_complet = trim(
  concat_ws(
    ' ',
    nullif(trim(prenom), ''),
    nullif(trim(nom), '')
  )
)
where nom_complet is null
   or trim(nom_complet) = '';


-- ============================================================
-- FIN
-- ============================================================
