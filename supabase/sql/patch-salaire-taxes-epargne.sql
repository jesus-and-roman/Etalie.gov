-- ============================================================
-- Correctif — Salaire variable, taxes sur le revenu, épargne
-- (chômage, retraite, parentalité)
-- ============================================================

-- ------------------------------------------------------------
-- 1) NOUVELLES COLONNES SUR citoyens
-- ------------------------------------------------------------
alter table citoyens add column if not exists salaire numeric not null default 12.5;
alter table citoyens add column if not exists taux_revenu numeric not null default 2;
alter table citoyens add column if not exists compte_chomage numeric not null default 0;
alter table citoyens add column if not exists compte_retraite numeric not null default 0;
alter table citoyens add column if not exists compte_parentalite numeric not null default 0;

-- ------------------------------------------------------------
-- 2) CALCUL DU TAUX DE LA TAXE SUR LES REVENUS (TR)
-- ------------------------------------------------------------
-- Salaire annuel toutouïen = salaire (R$/minute) × 39 × 30
-- Taux = 2% + 0,5% par tranche de 4500 R$ entamée, plafonné à 55%
create or replace function calculer_taux_revenu(p_salaire numeric)
returns numeric language sql immutable as $$
  select least(55, 2 + 0.5 * floor((p_salaire * 39 * 30) / 4500));
$$;

-- ------------------------------------------------------------
-- 3) INSCRIPTION — ajout de police (agent) et salaire
-- ------------------------------------------------------------
create or replace function inscrire_citoyen(
  p_username text, p_email text, p_prenom text, p_nom text,
  p_code_social_encrypte text, p_date_naissance date,
  p_protege_gouvernement boolean default false,
  p_police boolean default false,
  p_salaire numeric default 12.5
) returns citoyens
language plpgsql security definer set search_path = public as $$
declare
  v_age numeric;
  v_row citoyens;
  v_est_admin boolean;
begin
  if auth.uid() is null then raise exception 'Utilisateur non authentifié.'; end if;

  if exists (select 1 from citoyens where code_social_encrypte = p_code_social_encrypte) then
    raise exception 'Ce code d''assurance social est déjà associé à un compte.';
  end if;

  v_age := age_toutouien(p_date_naissance);
  if v_age < 20 then
    raise exception 'Majorité civile non atteinte (20 ans toutouïens requis, actuel: %).', round(v_age, 2);
  end if;

  v_est_admin := (upper(trim(p_nom)) = 'ADMIN' and upper(trim(p_prenom)) = 'ADMIN');

  insert into citoyens (
    id, username, email, prenom, nom, code_social_encrypte, date_naissance,
    age_toutouien_inscription, est_admin, est_agent_paix, salaire, taux_revenu
  )
  values (
    auth.uid(), p_username, p_email, p_prenom, p_nom, p_code_social_encrypte, p_date_naissance,
    v_age, v_est_admin, p_police, p_salaire, calculer_taux_revenu(p_salaire)
  )
  returning * into v_row;

  return v_row;
end;
$$;
grant execute on function inscrire_citoyen(text,text,text,text,text,date,boolean,boolean,numeric) to authenticated;

-- ------------------------------------------------------------
-- 4) REVENU AUTOMATIQUE — avec toutes les retenues
-- ------------------------------------------------------------
create or replace function deposer_revenu_citoyen(p_minutes numeric default 1.0/60)
returns citoyens language plpgsql security definer set search_path = public as $$
declare
  v_citoyen citoyens;
  v_brut numeric;
  v_tr numeric;
  v_chomage numeric;
  v_retraite numeric;
  v_parentalite numeric;
  v_net numeric;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;

  select * into v_citoyen from citoyens where id = auth.uid();
  if v_citoyen is null then raise exception 'Citoyen introuvable.'; end if;

  v_brut := v_citoyen.salaire * p_minutes;
  v_tr := v_brut * (v_citoyen.taux_revenu / 100.0);
  v_chomage := v_brut * 0.01;
  v_retraite := v_brut * 0.04;
  v_parentalite := v_brut * 0.0025;
  v_net := v_brut - v_tr - v_chomage - v_retraite - v_parentalite;

  update citoyens
    set tresorerie = tresorerie + v_net,
        compte_chomage = compte_chomage + v_chomage,
        compte_retraite = compte_retraite + v_retraite,
        compte_parentalite = compte_parentalite + v_parentalite,
        derniere_synchro_tresorerie = now()
    where id = auth.uid()
    returning * into v_citoyen;

  update tresor_public set solde = solde + v_tr where id = 1;

  return v_citoyen;
end;
$$;
grant execute on function deposer_revenu_citoyen(numeric) to authenticated;

-- ------------------------------------------------------------
-- 5) DEMANDES D'ÉPARGNE (chômage / retraite)
-- ------------------------------------------------------------
create table if not exists demandes_epargne (
  id           uuid primary key default gen_random_uuid(),
  citoyen_id   uuid not null references auth.users(id) on delete cascade,
  type         text not null check (type in ('chomage','retraite')),
  preuve_texte text not null,
  statut       text not null default 'en_attente' check (statut in ('en_attente','approuvee','refusee')),
  cree_le      timestamptz not null default now(),
  traite_le    timestamptz
);
alter table demandes_epargne enable row level security;

create policy "Voir ses propres demandes d'épargne ou tout si admin"
  on demandes_epargne for select
  using (auth.uid() = citoyen_id or est_admin_actuel());

create or replace function demander_epargne(p_type text, p_preuve text)
returns demandes_epargne language plpgsql security definer set search_path = public as $$
declare v_row demandes_epargne; v_age numeric; v_naissance date;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if p_type not in ('chomage','retraite') then raise exception 'Type de demande invalide.'; end if;
  if p_preuve is null or char_length(trim(p_preuve)) = 0 then raise exception 'Une preuve est requise.'; end if;

  if p_type = 'retraite' then
    select date_naissance into v_naissance from citoyens where id = auth.uid();
    v_age := age_toutouien(v_naissance);
    if v_age < 37 then
      raise exception 'Retraite non applicable : moins de 37 ans toutouïens d''ancienneté (actuel: %).', round(v_age, 2);
    end if;
  end if;

  if exists (select 1 from demandes_epargne where citoyen_id = auth.uid() and type = p_type and statut = 'en_attente') then
    raise exception 'Une demande de ce type est déjà en attente.';
  end if;

  insert into demandes_epargne (citoyen_id, type, preuve_texte)
  values (auth.uid(), p_type, p_preuve)
  returning * into v_row;
  return v_row;
end;
$$;
grant execute on function demander_epargne(text, text) to authenticated;

create or replace function admin_traiter_demande_epargne(p_id uuid, p_approuver boolean)
returns demandes_epargne language plpgsql security definer set search_path = public as $$
declare v_demande demandes_epargne; v_montant numeric;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé à l''administrateur.'; end if;

  select * into v_demande from demandes_epargne where id = p_id;
  if v_demande is null then raise exception 'Demande introuvable.'; end if;
  if v_demande.statut <> 'en_attente' then raise exception 'Cette demande a déjà été traitée.'; end if;

  if p_approuver then
    if v_demande.type = 'chomage' then
      select compte_chomage into v_montant from citoyens where id = v_demande.citoyen_id;
      update citoyens set tresorerie = tresorerie + v_montant, compte_chomage = 0 where id = v_demande.citoyen_id;
    else
      select compte_retraite into v_montant from citoyens where id = v_demande.citoyen_id;
      update citoyens set tresorerie = tresorerie + v_montant, compte_retraite = 0 where id = v_demande.citoyen_id;
    end if;
    update demandes_epargne set statut = 'approuvee', traite_le = now() where id = p_id returning * into v_demande;
    insert into paiements_historique (citoyen_id, type, montant, reference_id) values (v_demande.citoyen_id, v_demande.type, v_montant, p_id);
  else
    update demandes_epargne set statut = 'refusee', traite_le = now() where id = p_id returning * into v_demande;
  end if;

  return v_demande;
end;
$$;
grant execute on function admin_traiter_demande_epargne(uuid, boolean) to authenticated;

-- ------------------------------------------------------------
-- 6) TRANSFERT DU COMPTE PARENTALITÉ (admin seulement)
-- ------------------------------------------------------------
create or replace function admin_transferer_parentalite(p_citoyen_uuid uuid, p_destinataire_username text)
returns void language plpgsql security definer set search_path = public as $$
declare v_montant numeric; v_dest_id uuid;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé à l''administrateur.'; end if;

  select compte_parentalite into v_montant from citoyens where id = p_citoyen_uuid;
  if v_montant is null then raise exception 'Citoyen introuvable.'; end if;
  if v_montant <= 0 then raise exception 'Le compte parentalité de ce citoyen est vide.'; end if;

  select id into v_dest_id from citoyens where lower(username) = lower(p_destinataire_username);
  if v_dest_id is null then raise exception 'Destinataire introuvable.'; end if;

  update citoyens set compte_parentalite = 0 where id = p_citoyen_uuid;
  update citoyens set tresorerie = tresorerie + v_montant where id = v_dest_id;
  insert into paiements_historique (citoyen_id, type, montant, reference_id) values (p_citoyen_uuid, 'emprunt', v_montant, null);
end;
$$;
grant execute on function admin_transferer_parentalite(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 7) EXISTANTS — rattraper le taux/salaire des comptes déjà créés
-- ------------------------------------------------------------
-- Les comptes créés avant ce correctif ont salaire=12.5 par défaut
-- (déjà appliqué par le "default" ci-dessus) ; on recalcule leur taux
-- une bonne fois pour qu'il soit cohérent avec la formule officielle.
update citoyens set taux_revenu = calculer_taux_revenu(salaire);
