-- ============================================================
-- patch-fix-urgent.sql
-- Correction ciblée, rien d'autre. À exécuter après tous les patches
-- précédents.
-- ============================================================

-- ------------------------------------------------------------
-- 1) gouv_transferer_depuis_banque — recréée en isolation (drop d'abord,
--    pour éliminer toute ambiguïté de signature), puis rechargement forcé
--    du cache PostgREST.
-- ------------------------------------------------------------
drop function if exists gouv_transferer_depuis_banque(char, numeric, text);

create function gouv_transferer_depuis_banque(p_banque_tag char(1), p_montant numeric, p_treasorerie_cible text default 'publique')
returns void language plpgsql security definer set search_path = public as $$
declare v_solde numeric;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if p_montant <= 0 then raise exception 'Montant invalide.'; end if;
  select tresorerie into v_solde from banques_nationales where tag = p_banque_tag for update;
  if v_solde is null then raise exception 'Banque invalide.'; end if;
  if v_solde < p_montant then raise exception 'Trésorerie de la banque insuffisante.'; end if;
  update banques_nationales set tresorerie = tresorerie - p_montant where tag = p_banque_tag;
  if p_treasorerie_cible = 'privee' then
    update tresor_public set solde_prive = solde_prive + p_montant where id = 1;
  else
    update tresor_public set solde = solde + p_montant where id = 1;
  end if;
end; $$;
grant execute on function gouv_transferer_depuis_banque(char, numeric, text) to authenticated;

notify pgrst, 'reload schema';

-- SI L'ERREUR "Could not find the function ... in the schema cache"
-- PERSISTE APRÈS AVOIR EXÉCUTÉ CE BLOC :
--   1. Allez dans Supabase → Project Settings → API
--   2. Cliquez sur "Reload schema cache" (ou redémarrez le service API)
--   3. Ou exécutez seulement les 15 lignes ci-dessus, seules, dans une
--      requête à part, pour éliminer toute chance qu'une erreur ailleurs
--      dans un gros fichier ait empêché la création de la fonction.
-- Vérification rapide (doit retourner 1 ligne) :
--   select proname from pg_proc where proname = 'gouv_transferer_depuis_banque';


-- ------------------------------------------------------------
-- 2) LE VRAI BUG : l'aide sociale (option 4) payait TOUJOURS jusqu'à
--    5000 R$ à un citoyen dont la trésorerie tombe à 0, SANS jamais
--    vérifier si le gouvernement avait réellement les fonds — la moitié
--    "privée" du paiement n'était pas plafonnée par ce qui restait
--    vraiment dans la trésorerie privée, elle payait le plein montant
--    peu importe le solde. Corrigé : si les deux trésoreries n'ont pas
--    assez, seule la portion disponible est payée, et le reste retourne
--    dans l'argent attendu (jamais crédité dans le compte du citoyen).
-- ------------------------------------------------------------
create or replace function _aide_sociale_argent_attendu()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_option int; v_cible numeric; v_solde numeric; v_solde_prive numeric;
  v_pris_pub numeric; v_pris_priv numeric; v_paye numeric; v_reste numeric; v_log record;
begin
  select option_paiement_attendu into v_option from tresor_public where id = 1;
  if v_option <> 4 then return new; end if;
  if new.tresorerie > 0 or old.tresorerie <= 0 then return new; end if;
  if new.argent_attendu <= 0 then return new; end if;

  v_cible := least(5000, new.argent_attendu);
  select solde, solde_prive into v_solde, v_solde_prive from tresor_public where id = 1 for update;

  -- Moitié-moitié, mais JAMAIS plus que ce qui existe réellement dans
  -- chaque trésorerie (c'est ici qu'était le bug : aucun plafond).
  v_pris_pub := least(v_cible / 2.0, greatest(0, v_solde));
  v_pris_priv := least(v_cible - v_pris_pub, greatest(0, v_solde_prive));
  -- S'il reste un manque après la moitié publique (parce que la privée
  -- ne suffisait pas non plus), on retente sur la publique s'il en reste.
  if v_pris_pub + v_pris_priv < v_cible then
    v_pris_pub := least(v_cible - v_pris_priv, greatest(0, v_solde));
  end if;

  v_paye := v_pris_pub + v_pris_priv;
  if v_paye <= 0 then return new; end if; -- rien de disponible : aucun paiement, l'argent attendu reste tel quel

  update tresor_public set solde = solde - v_pris_pub, solde_prive = solde_prive - v_pris_priv where id = 1;
  update citoyens set tresorerie = tresorerie + v_paye, argent_attendu = argent_attendu - v_paye where id = new.id;

  v_reste := v_paye;
  for v_log in select * from argent_attendu_log where citoyen_id = new.id and montant_restant > 0 order by cree_le loop
    exit when v_reste <= 0;
    update argent_attendu_log set montant_restant = montant_restant - least(v_reste, montant_restant) where id = v_log.id;
    v_reste := v_reste - least(v_reste, v_log.montant_restant);
  end loop;
  delete from argent_attendu_log where citoyen_id = new.id and montant_restant <= 0;

  return new;
end; $$;

-- ------------------------------------------------------------
-- 3) Vérification défensive supplémentaire : si votre test concerne le
--    SALAIRE normal (pas l'option 4), sachez que le paiement peut
--    légitimement réussir via la trésorerie de la BANQUE NATIONALE de
--    la province de résidence du citoyen (une 3e source, distincte des
--    deux trésoreries "publique"/"privée" affichées) — c'est voulu,
--    vous me l'aviez demandé. Si CETTE banque a encore de l'argent, le
--    salaire se paie même si publique+privée sont à 0. Pour vérifier :
--    select tag, tresorerie from banques_nationales;
--    Si vous voulez que le salaire ignore complètement les banques et
--    ne dépende QUE de publique+privée, dites-le moi et je l'enlève.


-- ============================================================
-- 4) NOUVEAU SYSTEME DE NOM LEGAL ETALIEN
--    auf nam (mot 1, nom de famille) + dwai nam (mot 2, prenom) +
--    optionnellement (hwol|hw.) + trius nam (mot 4, complet ou abrege
--    a 1 lettre). 2 a 4 mots. Remplace prenom/nom comme champs de saisie
--    (prenom/nom restent en base = mot1/mot2, pour compatibilite avec
--    tout ce qui les affiche deja ailleurs sur le site).
-- ============================================================
alter table citoyens add column if not exists nom_complet text;
update citoyens set nom_complet = coalesce(nom_complet, prenom || ' ' || nom);

create or replace function nom_legal_valide(p_nom text)
returns boolean language plpgsql immutable as $$
declare
  v_mots text[]; v_n int;
  v_maj text := 'ABCDEGHIKMNOPRSTUVWYZÄÖÍÜËŔ';
  v_maj_simple text := 'ABCDEGHIKMNOPRSTUVWYZ';
  v_min text := 'abcdeghikmnoprstuvwyzäöíüëŕ';
  v_mot text;
begin
  if p_nom is null then return false; end if;
  v_mots := regexp_split_to_array(trim(p_nom), '\s+');
  v_n := array_length(v_mots, 1);
  if v_n is null or v_n < 2 or v_n > 4 then return false; end if;

  v_mot := v_mots[1];
  if length(v_mot) < 1 or position(substr(v_mot,1,1) in v_maj) = 0 then return false; end if;
  if length(v_mot) > 1 and substr(v_mot,2) !~ ('^[' || v_min || ']+$') then return false; end if;

  v_mot := v_mots[2];
  if length(v_mot) < 1 or position(substr(v_mot,1,1) in v_maj) = 0 then return false; end if;
  if length(v_mot) > 1 and substr(v_mot,2) !~ ('^[' || v_min || ']+$') then return false; end if;

  if v_n = 2 then return true; end if;
  if v_n = 3 then return false; end if;

  if v_mots[3] not in ('hwol','hw.') then return false; end if;

  v_mot := v_mots[4];
  if length(v_mot) = 2 and position(substr(v_mot,1,1) in v_maj_simple) > 0 and substr(v_mot,2,1) = '.' then
    return true;
  end if;
  if length(v_mot) >= 1 and position(substr(v_mot,1,1) in v_maj) > 0
     and (length(v_mot) = 1 or substr(v_mot,2) ~ ('^[' || v_min || ']+$')) then
    return true;
  end if;
  return false;
end; $$;
grant execute on function nom_legal_valide(text) to authenticated, anon;

-- inscrire_citoyen : remplace p_prenom + p_nom par p_nom_complet.
drop function if exists inscrire_citoyen(text,text,text,text,text,date,boolean,boolean,numeric,text);
create or replace function inscrire_citoyen(
  p_username text, p_email text, p_nom_complet text,
  p_code_social_encrypte text, p_date_naissance date,
  p_protege_gouvernement boolean default false,
  p_police boolean default false,
  p_salaire numeric default 12.5,
  p_province text default null
) returns public.citoyens
language plpgsql security definer set search_path = public as $$
declare
  v_age numeric;
  v_row public.citoyens;
  v_est_admin boolean;
  v_mots text[];
begin
  if auth.uid() is null then raise exception 'Utilisateur non authentifie.'; end if;

  if not nom_legal_valide(p_nom_complet) then
    raise exception 'Le nom legal ne respecte pas le format requis (2 a 4 mots : auf nam, dwai nam, puis "hwol"/"hw." et trius nam si marie).';
  end if;
  v_mots := regexp_split_to_array(trim(p_nom_complet), '\s+');

  if exists (select 1 from citoyens where code_social_encrypte = p_code_social_encrypte) then
    raise exception 'Ce code d''assurance social est deja associe a un compte.';
  end if;

  v_age := age_toutouien(p_date_naissance);
  if v_age < 20 then
    raise exception 'Majorite civile non atteinte (20 ans toutouiens requis, actuel: %).', round(v_age, 2);
  end if;

  if p_province is not null and not exists (select 1 from province_residence_banque where province = p_province) then
    raise exception 'Province de residence invalide.';
  end if;

  v_est_admin := (upper(v_mots[1]) = 'ADMIN' and upper(v_mots[2]) = 'ADMIN');

  insert into citoyens (
    id, username, email, prenom, nom, nom_complet, code_social_encrypte, date_naissance,
    age_toutouien_inscription, est_admin, est_agent_paix, salaire, taux_revenu, province_residence
  )
  values (
    auth.uid(), p_username, p_email, v_mots[2], v_mots[1], p_nom_complet, p_code_social_encrypte, p_date_naissance,
    v_age, v_est_admin, p_police, p_salaire, calculer_taux_revenu(p_salaire), p_province
  )
  returning * into v_row;

  return v_row;
end;
$$;
grant execute on function inscrire_citoyen(text,text,text,text,date,boolean,boolean,numeric,text) to authenticated;

-- ============================================================
-- FIN
-- ============================================================
