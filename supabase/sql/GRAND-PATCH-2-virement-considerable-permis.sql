-- ============================================================
-- GRAND-PATCH — partie 2 : corrections de périodes, plafond du
-- rendement, virement considérable, permis
-- À exécuter APRÈS GRAND-PATCH.sql
-- ============================================================

-- ------------------------------------------------------------
-- 1) CORRECTION — un seul compteur 60 jours (pas 30+60), reset à
--    00:00 chaque 60 jours depuis le 6 juillet 2026 ; plafond de
--    5000 R$ par personne sur le rendement
-- ------------------------------------------------------------
alter table citoyens rename column taxes_gouv_30j to taxes_gouv_60j;
alter table citoyens rename column taxe_preventive_30j to taxe_preventive_60j;
-- rendement_accumule_60j devient inutile : la base du rendement est
-- directement (taxes_gouv_60j + taxe_preventive_60j)
alter table citoyens drop column if exists rendement_accumule_60j;
alter table citoyens drop column if exists periode_30j_index;

create or replace function periode_60j_actuelle()
returns int language sql stable as $$
  select floor(extract(epoch from (now() - '2026-07-06T00:00:00Z'::timestamptz)) / (60*86400))::int;
$$;

-- Fenêtre de redevance : chaque 60 jours depuis le 5 juillet 2026,
-- de 18h00 à 23h59 (UTC) le jour de l'échéance
create or replace function dans_fenetre_redevance()
returns boolean language sql stable as $$
  select
    now() >= '2026-07-05T00:00:00Z'::timestamptz
    and mod(floor(extract(epoch from (now() - '2026-07-05T00:00:00Z'::timestamptz)) / 86400)::int, 60) = 0
    and extract(hour from (now() at time zone 'UTC')) >= 18;
$$;

drop function if exists deposer_revenu_citoyen(numeric);
create or replace function deposer_revenu_citoyen(p_minutes numeric default 1.0/60)
returns citoyens language plpgsql security definer set search_path = public as $$
declare
  v_citoyen citoyens;
  v_taux_preventif numeric;
  v_brut numeric; v_tr numeric; v_te numeric;
  v_chomage numeric; v_retraite numeric; v_parentalite numeric; v_net numeric;
  v_periode_60 int;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;

  select * into v_citoyen from citoyens where id = auth.uid();
  if v_citoyen is null then raise exception 'Citoyen introuvable.'; end if;

  select taux_preventif into v_taux_preventif from parametres_fiscaux where id = 1;

  v_periode_60 := periode_60j_actuelle();
  if v_citoyen.periode_60j_index <> v_periode_60 then
    update citoyens set taxes_gouv_60j = 0, taxe_preventive_60j = 0, periode_60j_index = v_periode_60
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
        taxes_gouv_60j = taxes_gouv_60j + v_tr,
        taxe_preventive_60j = taxe_preventive_60j + v_te,
        derniere_synchro_tresorerie = now()
    where id = auth.uid()
    returning * into v_citoyen;

  update tresor_public set solde = solde + v_tr + v_te where id = 1;
  return v_citoyen;
end;
$$;
grant execute on function deposer_revenu_citoyen(numeric) to authenticated;

-- Redevance : plafond 5000 R$/personne, reset immédiat sans toucher
-- à l'échéance programmée (periode_60j_index n'est pas modifié, donc
-- le prochain passage de période réelle continuera de fonctionner)
create or replace function admin_traiter_redevance(
  p_nip text, p_decision text,
  p_congres_oui int default null, p_congres_non int default null, p_pourcentage numeric default null
) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_mon_username text; v_montant numeric; v_mot text; v_majorite numeric;
  v_gouv numeric; v_prev numeric;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé à l''administrateur.'; end if;
  if p_decision not in ('oui','non') then raise exception 'Décision invalide.'; end if;

  if not dans_fenetre_redevance() then
    if p_nip is null or p_nip <> '7000' then raise exception 'NIP invalide.'; end if;
  end if;

  select username into v_mon_username from citoyens where id = auth.uid();

  if p_decision = 'non' then
    update citoyens set taxes_gouv_60j = 0, taxe_preventive_60j = 0;
    delete from transferts;
    return 'Redevance refusée : compteurs et historique de virements réinitialisés.';
  end if;

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

  for v_id, v_gouv, v_prev in select id, taxes_gouv_60j, taxe_preventive_60j from citoyens loop
    v_montant := least(5000, round((v_gouv + v_prev) * (p_pourcentage / 100.0), 2));
    if v_montant > 0 then
      update citoyens set tresorerie = tresorerie + v_montant where id = v_id;
      insert into messages (type, expediteur_id, expediteur_username, destinataire_id, titre, contenu)
      values ('gouvernemental', auth.uid(), v_mon_username, v_id,
              'Rendement des contribuables',
              'Le rendement a été attribué par ' || p_congres_oui || ' chambres du Congrès (' || v_majorite || '%), vous avez été envoyé par le gouvernement : ' ||
              v_montant || ' R$ pour vous remercier de votre soutien et parce que la trésorerie du pays a fait un bénéfice ' || v_mot || '.');
    end if;
  end loop;

  update citoyens set taxes_gouv_60j = 0, taxe_preventive_60j = 0;
  return 'Redevance attribuée à ' || p_pourcentage || '% (plafond 5000 R$/personne).';
end;
$$;
grant execute on function admin_traiter_redevance(text, text, int, int, numeric) to authenticated;

-- ============================================================
-- 2) VIREMENT CONSIDÉRABLE (500 000 R$ à 6 000 000 R$)
-- ============================================================
alter table citoyens add column if not exists deblocage_virement_considerable boolean not null default false;
alter table citoyens add column if not exists virements_illimites boolean not null default false;
alter table citoyens add column if not exists virements_illimites_jusqua timestamptz;

create table if not exists virements_considerables (
  id                  uuid primary key default gen_random_uuid(),
  expediteur_id       uuid not null references auth.users(id) on delete cascade,
  destinataire_id     uuid not null references auth.users(id) on delete cascade,
  montant             numeric not null,
  taux_total          numeric not null,
  taxe_montant        numeric not null,
  don_pourcentage     numeric not null,
  message_explicatif  text not null,
  nip_acceptation     text not null,
  tentatives          int not null default 0,
  statut              text not null default 'en_attente' check (statut in ('en_attente','accepte','bloque_1h','bloque_15j','supprime')),
  bloque_jusqua       timestamptz,
  cree_le             timestamptz not null default now(),
  traite_le           timestamptz
);
alter table virements_considerables enable row level security;
create policy "Voir ses virements considérables ou tout si admin"
  on virements_considerables for select
  using (auth.uid() = expediteur_id or auth.uid() = destinataire_id or est_admin_actuel());

create or replace function periode_30j_virements()
returns int language sql stable as $$
  select floor(extract(epoch from (now() - '2026-07-06T00:00:00Z'::timestamptz)) / (30*86400))::int;
$$;

create or replace function calculer_taux_virement_considerable(p_montant numeric)
returns numeric language sql immutable as $$
  select 1.99 + least(0.99, floor(greatest(0, p_montant - 500000) / 4607.78) * 0.01);
$$;

create or replace function compte_virements_considerables_ce_mois(p_uid uuid)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from virements_considerables
  where statut = 'accepte'
    and (expediteur_id = p_uid or destinataire_id = p_uid)
    and floor(extract(epoch from (cree_le - '2026-07-06T00:00:00Z'::timestamptz)) / (30*86400))::int = periode_30j_virements();
$$;
grant execute on function compte_virements_considerables_ce_mois(uuid) to authenticated;

create or replace function debloquer_virement_considerable(p_nip text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_nip <> '6500' then raise exception 'NIP invalide.'; end if;
  update citoyens set deblocage_virement_considerable = true where id = auth.uid();
end; $$;
grant execute on function debloquer_virement_considerable(text) to authenticated;

create or replace function debloquer_virements_illimites_nip(p_nip text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_nip <> '7042' then raise exception 'NIP invalide.'; end if;
  update citoyens set virements_illimites = true where id = auth.uid();
end; $$;
grant execute on function debloquer_virements_illimites_nip(text) to authenticated;

create or replace function payer_virements_illimites()
returns void language plpgsql security definer set search_path = public as $$
declare v_citoyen citoyens;
begin
  select * into v_citoyen from citoyens where id = auth.uid();
  if v_citoyen.tresorerie < 50000000 then raise exception 'Trésorerie insuffisante (50 000 000 R$ requis).'; end if;
  update citoyens set tresorerie = tresorerie - 50000000, virements_illimites_jusqua = now() + interval '60 days'
    where id = auth.uid();
  update tresor_public set solde = solde + 50000000 where id = 1;
end; $$;
grant execute on function payer_virements_illimites() to authenticated;

create or replace function envoyer_virement_considerable(
  p_destinataire_username text, p_montant numeric, p_message text,
  p_don_pourcentage numeric, p_nip_acceptation text
) returns virements_considerables
language plpgsql security definer set search_path = public as $$
declare
  v_expediteur citoyens; v_dest_id uuid; v_taux numeric; v_taxe numeric; v_total numeric; v_row virements_considerables;
  v_illimite boolean;
begin
  select * into v_expediteur from citoyens where id = auth.uid();
  if v_expediteur is null then raise exception 'Non authentifié.'; end if;

  v_illimite := v_expediteur.virements_illimites or (v_expediteur.virements_illimites_jusqua is not null and v_expediteur.virements_illimites_jusqua > now());

  if not v_expediteur.deblocage_virement_considerable then
    raise exception 'Virements considérables non débloqués (NIP requis).';
  end if;
  if not v_illimite and compte_virements_considerables_ce_mois(auth.uid()) >= 3 then
    raise exception 'Limite de 3 virements considérables atteinte pour cette période de 30 jours.';
  end if;
  if p_montant < 500000 or p_montant > 6000000 then
    raise exception 'Le virement considérable doit être entre 500 000 R$ et 6 000 000 R$.';
  end if;
  if char_length(p_message) < 100 then
    raise exception 'Le message explicatif doit faire au moins 100 caractères.';
  end if;
  if p_don_pourcentage < 0.02 or p_don_pourcentage > 10 then
    raise exception 'Le don au gouvernement doit être entre 0,02%% et 10%%.';
  end if;
  if p_nip_acceptation !~ '^\d{8}$' then
    raise exception 'Le NIP d''acceptation doit comporter exactement 8 chiffres.';
  end if;

  select id into v_dest_id from citoyens where lower(username) = lower(p_destinataire_username);
  if v_dest_id is null then raise exception 'Destinataire introuvable.'; end if;
  if v_dest_id = auth.uid() then raise exception 'Impossible de se virer de l''argent à soi-même.'; end if;

  v_taux := calculer_taux_virement_considerable(p_montant) + p_don_pourcentage;
  v_taxe := round(p_montant * (v_taux / 100.0), 2);
  v_total := p_montant + v_taxe;

  if v_expediteur.tresorerie < v_total then
    raise exception 'Trésorerie insuffisante (total avec taxes: %).', v_total;
  end if;

  update citoyens set tresorerie = tresorerie - v_total where id = auth.uid();

  insert into virements_considerables (expediteur_id, destinataire_id, montant, taux_total, taxe_montant, don_pourcentage, message_explicatif, nip_acceptation)
  values (auth.uid(), v_dest_id, p_montant, v_taux, v_taxe, p_don_pourcentage, p_message, p_nip_acceptation)
  returning * into v_row;

  return v_row;
end;
$$;
grant execute on function envoyer_virement_considerable(text, numeric, text, numeric, text) to authenticated;

create or replace function tenter_accepter_virement_considerable(p_id uuid, p_nip text)
returns text language plpgsql security definer set search_path = public as $$
declare v_row virements_considerables; v_mon_username text;
begin
  select * into v_row from virements_considerables where id = p_id and destinataire_id = auth.uid();
  if v_row is null then raise exception 'Virement introuvable.'; end if;
  if v_row.statut = 'accepte' then raise exception 'Ce virement a déjà été accepté.'; end if;
  if v_row.statut = 'supprime' then raise exception 'Ce virement a été annulé.'; end if;
  if v_row.bloque_jusqua is not null and v_row.bloque_jusqua > now() then
    raise exception 'Virement temporairement bloqué jusqu''à %.', v_row.bloque_jusqua;
  end if;

  if p_nip = v_row.nip_acceptation then
    update citoyens set tresorerie = tresorerie + v_row.montant where id = auth.uid();
    update tresor_public set solde = solde + v_row.taxe_montant where id = 1;
    update virements_considerables set statut = 'accepte', traite_le = now() where id = p_id;
    return 'accepte';
  end if;

  update virements_considerables set tentatives = tentatives + 1 where id = p_id returning * into v_row;

  if v_row.tentatives = 1 then
    return 'echec_1';
  elsif v_row.tentatives = 2 then
    update virements_considerables set statut = 'bloque_1h', bloque_jusqua = now() + interval '1 hour' where id = p_id;
    return 'bloque_1h';
  elsif v_row.tentatives = 3 then
    update virements_considerables set statut = 'bloque_15j', bloque_jusqua = now() + interval '15 days' where id = p_id;
    return 'bloque_15j';
  else
    update citoyens set tresorerie = tresorerie + v_row.montant + v_row.taxe_montant where id = v_row.expediteur_id;
    update virements_considerables set statut = 'supprime', traite_le = now() where id = p_id;
    select username into v_mon_username from citoyens where id = auth.uid();
    insert into messages (type, expediteur_id, expediteur_username, destinataire_id, titre, contenu)
    values ('normal', v_row.destinataire_id, v_mon_username, v_row.expediteur_id,
            'Virement considérable annulé',
            'Le destinataire a échoué 4 fois à entrer le NIP d''acceptation. Le virement de ' || v_row.montant || ' R$ (+ taxes) vous a été remboursé intégralement.');
    return 'supprime';
  end if;
end;
$$;
grant execute on function tenter_accepter_virement_considerable(uuid, text) to authenticated;

-- ============================================================
-- 3) PERMIS
-- ============================================================
create table if not exists permis_citoyens (
  id           uuid primary key default gen_random_uuid(),
  citoyen_id   uuid not null references citoyens(id) on delete cascade,
  type         text not null check (type in ('peche','chasse','travail')),
  prix_paye    numeric not null,
  achete_le    timestamptz not null default now(),
  expire_le    date
);
alter table permis_citoyens enable row level security;
create policy "Voir ses propres permis ou tout si admin"
  on permis_citoyens for select using (auth.uid() = citoyen_id or est_admin_actuel());

create or replace function acheter_permis(p_type text)
returns permis_citoyens language plpgsql security definer set search_path = public as $$
declare
  v_base numeric; v_total numeric; v_citoyen citoyens; v_expire date; v_row permis_citoyens;
begin
  if p_type not in ('peche','chasse','travail') then raise exception 'Type de permis invalide.'; end if;

  if exists (
    select 1 from permis_citoyens
    where citoyen_id = auth.uid() and type = p_type and (expire_le is null or expire_le >= current_date)
  ) then
    raise exception 'Vous détenez déjà un permis de ce type, encore valide.';
  end if;

  v_base := case p_type when 'peche' then 65.59 when 'chasse' then 178.59 else 0 end;
  v_total := round(v_base * 1.15, 2); -- 10% TAN + 5% TAN-TD, nul pour le permis de travail (base 0)
  v_expire := case when p_type = 'travail' then null else (current_date + interval '1 year')::date end;

  select * into v_citoyen from citoyens where id = auth.uid();
  if v_citoyen.tresorerie < v_total then raise exception 'Trésorerie insuffisante.'; end if;

  if v_total > 0 then
    update citoyens set tresorerie = tresorerie - v_total where id = auth.uid();
    update tresor_public set solde = solde + v_total where id = 1;
  end if;

  insert into permis_citoyens (citoyen_id, type, prix_paye, expire_le)
  values (auth.uid(), p_type, v_total, v_expire)
  returning * into v_row;

  return v_row;
end;
$$;
grant execute on function acheter_permis(text) to authenticated;
