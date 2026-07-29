-- ============================================================
-- GRAND-PATCH — Correctifs + Taxes gouvernementales, Taxe
-- Préventive, Rendement des contribuables
-- ============================================================

-- ------------------------------------------------------------
-- 1) CORRECTIF — relation demandes_epargne -> citoyens
-- ------------------------------------------------------------
alter table demandes_epargne drop constraint if exists demandes_epargne_citoyen_id_fkey;
alter table demandes_epargne
  add constraint demandes_epargne_citoyen_id_fkey
  foreign key (citoyen_id) references citoyens(id) on delete cascade;

-- ------------------------------------------------------------
-- 2) CORRECTIF — mise à jour du salaire/police à la connexion
-- ------------------------------------------------------------
create or replace function mettre_a_jour_salaire(p_salaire numeric, p_police boolean)
returns citoyens language plpgsql security definer set search_path = public as $$
declare v_row citoyens;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  update citoyens
    set salaire = p_salaire,
        taux_revenu = calculer_taux_revenu(p_salaire),
        est_agent_paix = p_police
    where id = auth.uid()
    returning * into v_row;
  return v_row;
end;
$$;
grant execute on function mettre_a_jour_salaire(numeric, boolean) to authenticated;

-- ------------------------------------------------------------
-- 3) CORRECTIF — documents : seul l'expéditeur signe à l'envoi,
--    le destinataire doit signer explicitement ensuite
-- ------------------------------------------------------------
alter table documents_contractuels alter column signe_destinataire set default false;
alter table documents_contractuels add column if not exists expediteur_username text;
alter table documents_contractuels add column if not exists destinataire_username text;

create or replace function envoyer_document(p_destinataire_username text, p_titre text, p_contenu text, p_date_debut date, p_date_expiration text)
returns documents_contractuels language plpgsql security definer set search_path = public as $$
declare v_dest uuid; v_row documents_contractuels; v_mon_username text;
begin
  if char_length(p_contenu) > 3000 then raise exception 'Document limité à 3000 caractères.'; end if;
  select id into v_dest from citoyens where lower(username) = lower(p_destinataire_username);
  if v_dest is null then raise exception 'Destinataire introuvable.'; end if;
  if v_dest = auth.uid() then raise exception 'Impossible de s''envoyer un document à soi-même.'; end if;
  select username into v_mon_username from citoyens where id = auth.uid();

  insert into documents_contractuels (expediteur_id, destinataire_id, expediteur_username, destinataire_username, titre, contenu, date_debut, date_expiration, signe_expediteur, signe_destinataire)
  values (auth.uid(), v_dest, v_mon_username, lower(p_destinataire_username), p_titre, p_contenu, p_date_debut, p_date_expiration, true, false)
  returning * into v_row;
  return v_row;
end;
$$;
grant execute on function envoyer_document(text, text, text, date, text) to authenticated;

create or replace function signer_document(p_id uuid)
returns documents_contractuels language plpgsql security definer set search_path = public as $$
declare v_row documents_contractuels;
begin
  update documents_contractuels set signe_destinataire = true
    where id = p_id and destinataire_id = auth.uid() and not signe_destinataire
    returning * into v_row;
  if v_row is null then raise exception 'Document introuvable ou déjà signé.'; end if;
  return v_row;
end;
$$;
grant execute on function signer_document(uuid) to authenticated;

-- ------------------------------------------------------------
-- 4) CORRECTIF — constats : seul l'admin choisit le pourcentage
--    de commission ; le citoyen ne fait que retirer (masquer)
--    de sa propre liste, une fois payé, sans déclencher de commission
-- ------------------------------------------------------------
drop function if exists retirer_constat_paye(uuid, numeric);

create or replace function citoyen_retirer_constat_paye(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_constat constats_infraction;
begin
  select * into v_constat from constats_infraction where id = p_id and destinataire_id = auth.uid();
  if v_constat is null then raise exception 'Constat introuvable.'; end if;
  if not v_constat.paye then raise exception 'Le constat doit être payé avant de pouvoir être retiré.'; end if;
  update constats_infraction set supprime_par_citoyen = true where id = p_id;
end;
$$;
grant execute on function citoyen_retirer_constat_paye(uuid) to authenticated;

create or replace function admin_retirer_constat_avec_commission(p_id uuid, p_pourcentage numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_constat constats_infraction; v_montant numeric; v_uid uuid;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé à l''administration.'; end if;
  select * into v_constat from constats_infraction where id = p_id;
  if v_constat is null then raise exception 'Constat introuvable.'; end if;
  if not v_constat.paye then raise exception 'Le constat doit être payé avant de pouvoir être retiré.'; end if;
  if p_pourcentage < 0.25 or p_pourcentage > 2.25 then
    raise exception 'Le pourcentage de commission doit être entre 0,25%% et 2,25%%.';
  end if;

  v_montant := round(v_constat.prix_total * (p_pourcentage / 100.0), 2);

  if v_constat.username_agent_vu is not null then
    select id into v_uid from citoyens where lower(username) = v_constat.username_agent_vu;
    if v_uid is not null then
      update citoyens set tresorerie = tresorerie + v_montant where id = v_uid;
      update tresor_public set solde = greatest(0, solde - v_montant) where id = 1;
    end if;
  end if;
  if v_constat.username_agent_donne is not null and v_constat.username_agent_donne <> v_constat.username_agent_vu then
    select id into v_uid from citoyens where lower(username) = v_constat.username_agent_donne;
    if v_uid is not null then
      update citoyens set tresorerie = tresorerie + v_montant where id = v_uid;
      update tresor_public set solde = greatest(0, solde - v_montant) where id = 1;
    end if;
  end if;
  if v_constat.username_agent_assiste is not null
     and v_constat.username_agent_assiste <> v_constat.username_agent_vu
     and v_constat.username_agent_assiste <> v_constat.username_agent_donne then
    select id into v_uid from citoyens where lower(username) = v_constat.username_agent_assiste;
    if v_uid is not null then
      update citoyens set tresorerie = tresorerie + v_montant where id = v_uid;
      update tresor_public set solde = greatest(0, solde - v_montant) where id = 1;
    end if;
  end if;

  -- Ne touche jamais supprime_par_citoyen : le versement de la commission
  -- par l'admin ne fait pas disparaître le constat de la liste du citoyen.
  update constats_infraction set supprime_par_agent = true where id = p_id;
end;
$$;
grant execute on function admin_retirer_constat_avec_commission(uuid, numeric) to authenticated;

-- ------------------------------------------------------------
-- 5) TRANSFERT PARENTALITÉ — consultation du solde par UUID
-- ------------------------------------------------------------
create or replace function admin_consulter_parentalite(p_citoyen_uuid uuid)
returns numeric language plpgsql security definer set search_path = public as $$
declare v_montant numeric;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  select compte_parentalite into v_montant from citoyens where id = p_citoyen_uuid;
  if v_montant is null then raise exception 'Citoyen introuvable.'; end if;
  return v_montant;
end;
$$;
grant execute on function admin_consulter_parentalite(uuid) to authenticated;

-- ============================================================
-- 6) TAXES GOUVERNEMENTALES (30j) + TAXE PRÉVENTIVE (30j)
-- ============================================================
alter table citoyens add column if not exists taxes_gouv_30j numeric not null default 0;
alter table citoyens add column if not exists taxe_preventive_30j numeric not null default 0;
alter table citoyens add column if not exists periode_30j_index int not null default -1;
alter table citoyens add column if not exists rendement_accumule_60j numeric not null default 0;
alter table citoyens add column if not exists periode_60j_index int not null default -1;

create table if not exists parametres_fiscaux (
  id int primary key default 1,
  taux_preventif numeric not null default 0 check (taux_preventif >= 0 and taux_preventif <= 2),
  constraint une_seule_ligne_param check (id = 1)
);
insert into parametres_fiscaux (id, taux_preventif) values (1, 0) on conflict (id) do nothing;
alter table parametres_fiscaux enable row level security;
create policy "Tout le monde peut lire le taux préventif"
  on parametres_fiscaux for select using (true);
grant select on parametres_fiscaux to anon, authenticated;

create or replace function periode_30j_actuelle()
returns int language sql stable as $$
  select floor(extract(epoch from (now() - '2026-07-07T00:00:00Z'::timestamptz)) / (30*86400))::int;
$$;

create or replace function periode_60j_actuelle()
returns int language sql stable as $$
  select floor(extract(epoch from (now() - '2026-07-06T19:00:00Z'::timestamptz)) / (60*86400))::int;
$$;

create or replace function dans_fenetre_redevance()
returns boolean language sql stable as $$
  select mod(extract(epoch from (now() - '2026-07-06T19:00:00Z'::timestamptz))::numeric, 60*86400) < 2*3600
         and now() >= '2026-07-06T19:00:00Z'::timestamptz;
$$;

-- ------------------------------------------------------------
-- Admin définit le taux préventif (0 à 2%) + avertit tout le monde
-- ------------------------------------------------------------
create or replace function admin_definir_taux_preventif(p_taux numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_mon_username text;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé à l''administrateur.'; end if;
  if p_taux < 0 or p_taux > 2 then raise exception 'Le taux préventif doit être entre 0%% et 2%%.'; end if;
  update parametres_fiscaux set taux_preventif = p_taux where id = 1;

  select username into v_mon_username from citoyens where id = auth.uid();
  for v_id in select id from citoyens loop
    insert into messages (type, expediteur_id, expediteur_username, destinataire_id, titre, contenu)
    values ('gouvernemental', auth.uid(), v_mon_username, v_id,
            'Taxe Préventive ajustée',
            'La Taxe Préventive (Taxe d''Équilibre) est maintenant fixée à ' || p_taux || '%. Ce taux s''applique automatiquement sur vos revenus jusqu''à nouvel ajustement.');
  end loop;
end;
$$;
grant execute on function admin_definir_taux_preventif(numeric) to authenticated;

-- ------------------------------------------------------------
-- Revenu automatique — version finale avec Taxe Préventive et
-- suivi des compteurs 30j / 60j (avec réinitialisation automatique
-- au passage d'une période, y compris pour ceux qui n'étaient pas
-- connectés au moment exact du changement de période)
-- ------------------------------------------------------------
drop function if exists deposer_revenu_citoyen(numeric);

create or replace function deposer_revenu_citoyen(p_minutes numeric default 1.0/60)
returns citoyens language plpgsql security definer set search_path = public as $$
declare
  v_citoyen citoyens;
  v_taux_preventif numeric;
  v_brut numeric;
  v_tr numeric;
  v_te numeric;
  v_chomage numeric;
  v_retraite numeric;
  v_parentalite numeric;
  v_net numeric;
  v_periode_30 int;
  v_periode_60 int;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;

  select * into v_citoyen from citoyens where id = auth.uid();
  if v_citoyen is null then raise exception 'Citoyen introuvable.'; end if;

  select taux_preventif into v_taux_preventif from parametres_fiscaux where id = 1;

  v_periode_30 := periode_30j_actuelle();
  v_periode_60 := periode_60j_actuelle();

  -- Réinitialisation des compteurs si on a changé de période depuis la dernière visite
  if v_citoyen.periode_30j_index <> v_periode_30 then
    update citoyens set taxes_gouv_30j = 0, taxe_preventive_30j = 0, periode_30j_index = v_periode_30
      where id = auth.uid() returning * into v_citoyen;
  end if;
  if v_citoyen.periode_60j_index <> v_periode_60 then
    update citoyens set rendement_accumule_60j = 0, periode_60j_index = v_periode_60
      where id = auth.uid() returning * into v_citoyen;
  end if;

  v_brut := v_citoyen.salaire * p_minutes;
  v_tr := v_brut * (v_citoyen.taux_revenu / 100.0);
  v_te := v_brut * (v_taux_preventif / 100.0);
  v_chomage := v_brut * 0.01;
  v_retraite := v_brut * 0.04;
  v_parentalite := v_brut * 0.0025;
  v_net := v_brut - v_tr - v_te - v_chomage - v_retraite - v_parentalite;

  update citoyens
    set tresorerie = tresorerie + v_net,
        compte_chomage = compte_chomage + v_chomage,
        compte_retraite = compte_retraite + v_retraite,
        compte_parentalite = compte_parentalite + v_parentalite,
        taxes_gouv_30j = taxes_gouv_30j + v_tr,
        taxe_preventive_30j = taxe_preventive_30j + v_te,
        rendement_accumule_60j = rendement_accumule_60j + v_tr + v_te,
        derniere_synchro_tresorerie = now()
    where id = auth.uid()
    returning * into v_citoyen;

  update tresor_public set solde = solde + v_tr + v_te where id = 1;

  return v_citoyen;
end;
$$;
grant execute on function deposer_revenu_citoyen(numeric) to authenticated;

-- ============================================================
-- 7) RENDEMENT DES CONTRIBUABLES (redevance tous les 60 jours)
-- ============================================================
create or replace function admin_traiter_redevance(
  p_nip text,
  p_decision text,          -- 'oui' ou 'non'
  p_congres_oui int default null,
  p_congres_non int default null,
  p_pourcentage numeric default null
) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_mon_username text; v_montant numeric; v_mot text; v_majorite numeric;
  v_gouv numeric; v_prev numeric;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé à l''administrateur.'; end if;
  if p_decision not in ('oui','non') then raise exception 'Décision invalide.'; end if;

  if not dans_fenetre_redevance() then
    if p_nip is null or p_nip <> '7000' then
      raise exception 'NIP invalide.';
    end if;
  end if;

  select username into v_mon_username from citoyens where id = auth.uid();

  if p_decision = 'non' then
    update citoyens set taxes_gouv_30j = 0, taxe_preventive_30j = 0, rendement_accumule_60j = 0;
    delete from transferts;
    return 'Redevance refusée : compteurs et historique de virements réinitialisés.';
  end if;

  -- p_decision = 'oui'
  if p_congres_oui is null or p_congres_non is null or p_pourcentage is null then
    raise exception 'Votes du Congrès et pourcentage requis pour attribuer une redevance.';
  end if;
  if p_pourcentage < 0 or p_pourcentage > 5 then
    raise exception 'Le pourcentage de rendement doit être entre 0%% et 5%%.';
  end if;

  v_majorite := round((p_congres_oui::numeric / nullif(p_congres_oui + p_congres_non, 0)) * 100, 2);

  if p_pourcentage <= 0.50 then v_mot := 'significatif';
  elsif p_pourcentage <= 3.00 then v_mot := 'conséquent';
  elsif p_pourcentage <= 4.51 then v_mot := 'considérable';
  else v_mot := 'exceptionnel';
  end if;

  for v_id, v_gouv, v_prev in
    select id, taxes_gouv_30j, taxe_preventive_30j from citoyens
  loop
    v_montant := round((v_gouv + v_prev) * (p_pourcentage / 100.0), 2);
    if v_montant > 0 then
      update citoyens set tresorerie = tresorerie + v_montant where id = v_id;
      insert into messages (type, expediteur_id, expediteur_username, destinataire_id, titre, contenu)
      values ('gouvernemental', auth.uid(), v_mon_username, v_id,
              'Rendement des contribuables',
              'Le rendement a été attribué par ' || p_congres_oui || ' chambres du Congrès (' || v_majorite || '%), vous avez été envoyé par le gouvernement : ' ||
              v_montant || ' R$ pour vous remercier de votre soutien et parce que la trésorerie du pays a fait un bénéfice ' || v_mot || '.');
    end if;
  end loop;

  update citoyens set taxes_gouv_30j = 0, taxe_preventive_30j = 0, rendement_accumule_60j = 0;

  return 'Redevance attribuée à ' || p_pourcentage || '%.';
end;
$$;
grant execute on function admin_traiter_redevance(text, text, int, int, numeric) to authenticated;
