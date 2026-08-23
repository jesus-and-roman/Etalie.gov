-- ============================================================
-- patch-gouvernement-tresoreries.sql
-- Système complet des deux trésoreries du gouvernement, argent
-- attendu (4 options), PIB réel, Palamöss, trésoreries provinciales.
-- À exécuter après tous les fichiers précédents (order.txt +
-- patch-presse-monetaire*.sql). Idempotent.
--
-- IMPORTANT — ce que ce patch NE CHANGE PAS :
--  - Le processus de rendement des contribuables reste au vote du
--    Congrès + pourcentage entré manuellement par l'admin (0-5%) :
--    je n'ai PAS remplacé ça par un pourcentage Palamöss automatique,
--    pour ne rien casser dans ce mécanisme politique déjà en place.
--    Le Palamöss est calculé et affiché comme repère informatif.
--  - Le salaire par seconde (déjà géré par un patch précédent) est ici
--    corrigé pour venir du gouvernement (et plus d'une banque nationale,
--    comme demandé) au lieu d'être créé de nulle part.
-- ============================================================


-- ============================================================
-- 1) LES DEUX TRÉSORERIES DU GOUVERNEMENT
-- ============================================================
alter table tresor_public add column if not exists solde_prive numeric not null default 0;
alter table tresor_public add column if not exists taxes_totales_periode numeric not null default 0;
alter table tresor_public add column if not exists option_paiement_attendu int not null default 1;
do $$ begin
  alter table tresor_public add constraint tresor_public_option_check check (option_paiement_attendu between 1 and 4);
exception when duplicate_object then null;
end $$;

alter table citoyens add column if not exists argent_attendu numeric not null default 0;

create table if not exists argent_attendu_log (
  id               uuid primary key default gen_random_uuid(),
  citoyen_id       uuid not null references auth.users(id) on delete cascade,
  montant_initial  numeric not null,
  montant_restant  numeric not null,
  cree_le          timestamptz not null default now()
);
alter table argent_attendu_log enable row level security;
drop policy if exists "Un citoyen voit son propre journal d'argent attendu" on argent_attendu_log;
create policy "Un citoyen voit son propre journal d'argent attendu" on argent_attendu_log
  for select using (auth.uid() = citoyen_id or est_admin_actuel());

-- ------------------------------------------------------------
-- Fonctions internes (jamais accordées à authenticated/anon —
-- uniquement appelables depuis d'autres fonctions SECURITY DEFINER).
-- ------------------------------------------------------------

-- Débit "administratif" (n'appartient pas à un paiement à un civil) :
-- toujours autorisé à passer en négatif.
create or replace function gouv_puiser_interne(p_montant numeric, p_treasorerie_preferee text default 'publique')
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_montant is null or p_montant <= 0 then return; end if;
  if p_treasorerie_preferee = 'privee' then
    update tresor_public set solde_prive = solde_prive - p_montant where id = 1;
  else
    update tresor_public set solde = solde - p_montant where id = 1;
  end if;
end; $$;
revoke all on function gouv_puiser_interne(numeric, text) from public;

-- Paiement à un civil (jamais négatif) : pige d'abord dans la trésorerie
-- provinciale de p_province si fournie, puis dans la trésorerie
-- nationale préférée, puis dans l'autre trésorerie nationale. Ce qui
-- manque part dans argent_attendu (jamais dans la trésorerie du civil
-- directement) et est journalisé pour l'option 2 (préférence temporelle).
create or replace function gouv_payer_civil(
  p_citoyen_id uuid, p_montant numeric,
  p_treasorerie_preferee text default 'publique', p_province text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_solde_prov numeric; v_obtenu_prov numeric := 0;
  v_solde numeric; v_solde_prive numeric; v_home numeric; v_other numeric;
  v_pris_home numeric; v_pris_other numeric; v_obtenu_nat numeric := 0;
  v_reste numeric; v_total_obtenu numeric; v_manque numeric;
begin
  if p_montant is null or p_montant <= 0 then
    return jsonb_build_object('obtenu', 0, 'manque', 0);
  end if;
  v_reste := p_montant;

  if p_province is not null then
    select solde into v_solde_prov from tresoreries_provinciales where province = p_province for update;
    if v_solde_prov is not null and v_solde_prov > 0 then
      v_obtenu_prov := least(v_reste, v_solde_prov);
      update tresoreries_provinciales set solde = solde - v_obtenu_prov where province = p_province;
      v_reste := v_reste - v_obtenu_prov;
    end if;
  end if;

  if v_reste > 0 then
    select solde, solde_prive into v_solde, v_solde_prive from tresor_public where id = 1 for update;
    if p_treasorerie_preferee = 'privee' then v_home := v_solde_prive; v_other := v_solde;
    else v_home := v_solde; v_other := v_solde_prive; end if;

    v_pris_home := least(v_reste, greatest(0, v_home));
    v_pris_other := least(v_reste - v_pris_home, greatest(0, v_other));
    v_obtenu_nat := v_pris_home + v_pris_other;

    if p_treasorerie_preferee = 'privee' then
      update tresor_public set solde_prive = solde_prive - v_pris_home, solde = solde - v_pris_other where id = 1;
    else
      update tresor_public set solde = solde - v_pris_home, solde_prive = solde_prive - v_pris_other where id = 1;
    end if;
    v_reste := v_reste - v_obtenu_nat;
  end if;

  v_total_obtenu := p_montant - v_reste;
  v_manque := v_reste;

  if v_total_obtenu > 0 then
    update citoyens set tresorerie = tresorerie + v_total_obtenu where id = p_citoyen_id;
  end if;
  if v_manque > 0 then
    update citoyens set argent_attendu = argent_attendu + v_manque where id = p_citoyen_id;
    insert into argent_attendu_log (citoyen_id, montant_initial, montant_restant) values (p_citoyen_id, v_manque, v_manque);
  end if;

  return jsonb_build_object('obtenu', v_total_obtenu, 'manque', v_manque);
end; $$;
revoke all on function gouv_payer_civil(uuid, numeric, text, text) from public;

-- Règle (rembourse) l'argent déjà en attente d'un citoyen, jusqu'à
-- p_plafond (ou la totalité s'il n'y en a pas), selon les fonds
-- disponibles. Retourne le montant réellement payé.
create or replace function gouv_regler_argent_attendu(
  p_citoyen_id uuid, p_treasorerie_preferee text default 'publique', p_plafond numeric default null
) returns numeric language plpgsql security definer set search_path = public as $$
declare
  v_du numeric; v_cible numeric; v_solde numeric; v_solde_prive numeric; v_home numeric; v_other numeric;
  v_pris_home numeric; v_pris_other numeric; v_paye numeric; v_reste_log numeric; v_log record;
begin
  select argent_attendu into v_du from citoyens where id = p_citoyen_id for update;
  if v_du is null or v_du <= 0 then return 0; end if;
  v_cible := least(v_du, coalesce(p_plafond, v_du));
  if v_cible <= 0 then return 0; end if;

  select solde, solde_prive into v_solde, v_solde_prive from tresor_public where id = 1 for update;
  if p_treasorerie_preferee = 'privee' then v_home := v_solde_prive; v_other := v_solde;
  else v_home := v_solde; v_other := v_solde_prive; end if;

  v_pris_home := least(v_cible, greatest(0, v_home));
  v_pris_other := least(v_cible - v_pris_home, greatest(0, v_other));
  v_paye := v_pris_home + v_pris_other;
  if v_paye <= 0 then return 0; end if;

  if p_treasorerie_preferee = 'privee' then
    update tresor_public set solde_prive = solde_prive - v_pris_home, solde = solde - v_pris_other where id = 1;
  else
    update tresor_public set solde = solde - v_pris_home, solde_prive = solde_prive - v_pris_other where id = 1;
  end if;

  update citoyens set tresorerie = tresorerie + v_paye, argent_attendu = argent_attendu - v_paye where id = p_citoyen_id;

  v_reste_log := v_paye;
  for v_log in select * from argent_attendu_log where citoyen_id = p_citoyen_id and montant_restant > 0 order by cree_le loop
    exit when v_reste_log <= 0;
    update argent_attendu_log set montant_restant = montant_restant - least(v_reste_log, montant_restant) where id = v_log.id;
    v_reste_log := v_reste_log - least(v_reste_log, v_log.montant_restant);
  end loop;
  delete from argent_attendu_log where citoyen_id = p_citoyen_id and montant_restant <= 0;

  return v_paye;
end; $$;
revoke all on function gouv_regler_argent_attendu(uuid, text, numeric) from public;


-- ============================================================
-- 2) LES 4 OPTIONS DE PAIEMENT DE L'ARGENT ATTENDU
-- ============================================================
create or replace function gouv_definir_option_paiement(p_option int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if p_option not between 1 and 4 then raise exception 'Option invalide (1 à 4).'; end if;
  update tresor_public set option_paiement_attendu = p_option where id = 1;
end; $$;
grant execute on function gouv_definir_option_paiement(int) to authenticated;

-- Option 1 (égal) / Option 2 (FIFO) — appelée automatiquement dès que le
-- gouvernement encaisse de l'argent (voir section 4, functions revenus).
create or replace function gouv_distribuer_argent_attendu()
returns void language plpgsql security definer set search_path = public as $$
declare v_option int; v_id uuid; v_nb int; v_disponible numeric; v_part numeric; v_i int;
begin
  select option_paiement_attendu into v_option from tresor_public where id = 1;
  if v_option not in (1,2) then return; end if;

  if v_option = 2 then
    for v_id in
      select citoyen_id from argent_attendu_log where montant_restant > 0
      group by citoyen_id order by min(cree_le)
    loop
      perform gouv_regler_argent_attendu(v_id, 'publique');
    end loop;
  else
    for v_i in 1..5 loop
      select count(*) into v_nb from citoyens where argent_attendu > 0;
      exit when v_nb = 0;
      select greatest(0,solde) + greatest(0,solde_prive) into v_disponible from tresor_public where id = 1;
      exit when v_disponible <= 0.01;
      v_part := v_disponible / v_nb;
      for v_id in select id from citoyens where argent_attendu > 0 loop
        perform gouv_regler_argent_attendu(v_id, 'publique', v_part);
      end loop;
    end loop;
  end if;
end; $$;
revoke all on function gouv_distribuer_argent_attendu() from public;

-- Option 3 / 4 — paiement manuel choisi par le gouvernement (liste cochée).
create or replace function gouv_payer_dus_selection(p_citoyen_ids uuid[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_paye numeric; v_resultats jsonb := '[]'::jsonb;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  foreach v_id in array p_citoyen_ids loop
    v_paye := gouv_regler_argent_attendu(v_id, 'publique');
    v_resultats := v_resultats || jsonb_build_object('citoyen_id', v_id, 'paye', v_paye);
  end loop;
  return v_resultats;
end; $$;
grant execute on function gouv_payer_dus_selection(uuid[]) to authenticated;

-- Dette nationale = somme de l'argent attendu de tout le monde.
create or replace function dette_nationale_argent_attendu()
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(argent_attendu), 0) from citoyens;
$$;
grant execute on function dette_nationale_argent_attendu() to authenticated;

create or replace function gouv_liste_argent_attendu()
returns table(citoyen_id uuid, username text, prenom text, nom text, argent_attendu numeric)
language sql stable security definer set search_path = public as $$
  select c.id, c.username, c.prenom, c.nom, c.argent_attendu
  from citoyens c
  where c.argent_attendu > 0 and est_admin_actuel()
  order by c.argent_attendu desc;
$$;
grant execute on function gouv_liste_argent_attendu() to authenticated;

-- Option 4 : dès que la trésorerie d'un citoyen tombe à 0 (ou moins), on
-- lui rembourse jusqu'à 5000 R$ de son argent attendu, 50/50 entre les
-- deux trésoreries du gouvernement (sauf s'il faut piger dans l'autre),
-- quitte à les mettre en négatif.
create or replace function _aide_sociale_argent_attendu()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_option int; v_montant numeric; v_moitie numeric; v_solde numeric; v_solde_prive numeric;
  v_pris_pub numeric; v_pris_priv numeric; v_reste numeric; v_log record;
begin
  select option_paiement_attendu into v_option from tresor_public where id = 1;
  if v_option <> 4 then return new; end if;
  if new.tresorerie > 0 or old.tresorerie <= 0 then return new; end if;
  if new.argent_attendu <= 0 then return new; end if;

  v_montant := least(5000, new.argent_attendu);
  select solde, solde_prive into v_solde, v_solde_prive from tresor_public where id = 1 for update;
  v_moitie := v_montant / 2.0;
  v_pris_pub := least(v_moitie, greatest(0, v_solde));
  v_pris_priv := v_montant - v_pris_pub;

  update tresor_public set solde = solde - v_pris_pub, solde_prive = solde_prive - v_pris_priv where id = 1;
  update citoyens set tresorerie = tresorerie + v_montant, argent_attendu = argent_attendu - v_montant where id = new.id;

  v_reste := v_montant;
  for v_log in select * from argent_attendu_log where citoyen_id = new.id and montant_restant > 0 order by cree_le loop
    exit when v_reste <= 0;
    update argent_attendu_log set montant_restant = montant_restant - least(v_reste, montant_restant) where id = v_log.id;
    v_reste := v_reste - least(v_reste, v_log.montant_restant);
  end loop;
  delete from argent_attendu_log where citoyen_id = new.id and montant_restant <= 0;

  return new;
end; $$;
drop trigger if exists trg_aide_sociale on citoyens;
create trigger trg_aide_sociale after update of tresorerie on citoyens
  for each row execute function _aide_sociale_argent_attendu();


-- ============================================================
-- 3) TRÉSORERIES PROVINCIALES
-- ============================================================
create table if not exists tresoreries_provinciales (
  province text primary key references province_residence_banque(province),
  solde    numeric not null default 0
);
insert into tresoreries_provinciales (province) select province from province_residence_banque
  on conflict (province) do nothing;
alter table tresoreries_provinciales enable row level security;
drop policy if exists "Lecture publique des trésoreries provinciales" on tresoreries_provinciales;
create policy "Lecture publique des trésoreries provinciales" on tresoreries_provinciales for select using (true);

-- Renfloue automatiquement à 50 000 R$ dès qu'une trésorerie provinciale
-- atteint 0 (ou moins) — même si ça met une trésorerie nationale en dette.
create or replace function _renflouer_tresorerie_provinciale()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.solde <= 0 then
    perform gouv_puiser_interne(50000, 'publique');
    new.solde := new.solde + 50000;
  end if;
  return new;
end; $$;
drop trigger if exists trg_renflouer_provinciale on tresoreries_provinciales;
create trigger trg_renflouer_provinciale before insert or update on tresoreries_provinciales
  for each row execute function _renflouer_tresorerie_provinciale();

create or replace function gouv_transferer_vers_provinciale(p_province text, p_montant numeric, p_treasorerie_preferee text default 'publique')
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if p_montant <= 0 then raise exception 'Montant invalide.'; end if;
  perform gouv_puiser_interne(p_montant, p_treasorerie_preferee);
  update tresoreries_provinciales set solde = solde + p_montant where province = p_province;
end; $$;
grant execute on function gouv_transferer_vers_provinciale(text, numeric, text) to authenticated;

create or replace function gouv_transferer_depuis_provinciale(p_province text, p_montant numeric, p_treasorerie_cible text default 'publique')
returns void language plpgsql security definer set search_path = public as $$
declare v_solde numeric;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  select solde into v_solde from tresoreries_provinciales where province = p_province for update;
  if v_solde is null then raise exception 'Province invalide.'; end if;
  if v_solde < p_montant then raise exception 'Trésorerie provinciale insuffisante.'; end if;
  update tresoreries_provinciales set solde = solde - p_montant where province = p_province;
  if p_treasorerie_cible = 'privee' then
    update tresor_public set solde_prive = solde_prive + p_montant where id = 1;
  else
    update tresor_public set solde = solde + p_montant where id = 1;
  end if;
end; $$;
grant execute on function gouv_transferer_depuis_provinciale(text, numeric, text) to authenticated;


-- ============================================================
-- 4) REDIRECTION DES REVENUS EXISTANTS VERS LA BONNE TRÉSORERIE
--    (même signature partout : CREATE OR REPLACE suffit)
-- ============================================================

-- Permis -> privée ("l'argent des permis")
create or replace function acheter_permis(p_type text, p_adresse_livraison text)
returns permis_citoyens language plpgsql security definer set search_path = public as $$
declare
  v_base numeric; v_total numeric; v_citoyen citoyens; v_expire date; v_row permis_citoyens;
begin
  if p_type not in ('peche','chasse','travail') then raise exception 'Type de permis invalide.'; end if;
  if p_adresse_livraison is null or char_length(trim(p_adresse_livraison)) = 0 then
    raise exception 'Une adresse de livraison est requise.';
  end if;

  if exists (
    select 1 from permis_citoyens
    where citoyen_id = auth.uid() and type = p_type and (expire_le is null or expire_le >= current_date)
  ) then
    raise exception 'Vous détenez déjà un permis de ce type, encore valide.';
  end if;

  v_base := case p_type when 'peche' then 65.59 when 'chasse' then 178.59 else 0 end;
  v_total := round(v_base * 1.15, 2);
  v_expire := case when p_type = 'travail' then null else (current_date + interval '1 year')::date end;

  select * into v_citoyen from citoyens where id = auth.uid();
  if v_citoyen.tresorerie < v_total then raise exception 'Trésorerie insuffisante.'; end if;

  if v_total > 0 then
    update citoyens set tresorerie = tresorerie - v_total where id = auth.uid();
    update tresor_public set solde_prive = solde_prive + v_total where id = 1;
  end if;

  insert into permis_citoyens (citoyen_id, type, prix_paye, expire_le, adresse_livraison)
  values (auth.uid(), p_type, v_total, v_expire, p_adresse_livraison)
  returning * into v_row;

  perform gouv_distribuer_argent_attendu();
  return v_row;
end;
$$;
grant execute on function acheter_permis(text, text) to authenticated;

-- Constats -> privée ("les constats d'infractions")
create or replace function payer_constat(p_id uuid)
returns constats_infraction language plpgsql security definer set search_path = public as $$
declare v_constat constats_infraction; v_citoyen citoyens;
begin
  select * into v_constat from constats_infraction where id = p_id and destinataire_id = auth.uid();
  if v_constat is null then raise exception 'Constat introuvable.'; end if;
  if v_constat.paye then raise exception 'Ce constat a déjà été payé.'; end if;
  select * into v_citoyen from citoyens where id = auth.uid();
  if v_citoyen.tresorerie < v_constat.prix_total then raise exception 'Trésorerie insuffisante.'; end if;

  update citoyens set tresorerie = tresorerie - v_constat.prix_total where id = auth.uid();
  update tresor_public set solde_prive = solde_prive + v_constat.prix_total where id = 1;
  update constats_infraction set paye = true, paye_le = now() where id = p_id returning * into v_constat;
  insert into paiements_historique (citoyen_id, type, montant, reference_id) values (auth.uid(), 'constat', v_constat.prix_total, p_id);
  perform gouv_distribuer_argent_attendu();
  return v_constat;
end; $$;
grant execute on function payer_constat(uuid) to authenticated;

-- Remboursement de dettes/prêts -> privée (n'était crédité nulle part avant)
create or replace function payer_dette(p_montant numeric)
returns citoyens language plpgsql security definer set search_path = public as $$
declare v_row citoyens;
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select * into v_row from citoyens where id = auth.uid();
  if v_row.tresorerie < p_montant then raise exception 'Trésorerie insuffisante.'; end if;
  update citoyens set tresorerie = tresorerie - p_montant, dettes = greatest(0, dettes - p_montant)
    where id = auth.uid() returning * into v_row;
  update tresor_public set solde_prive = solde_prive + p_montant where id = 1;
  insert into paiements_historique (citoyen_id, type, montant) values (auth.uid(), 'dette', p_montant);
  perform gouv_distribuer_argent_attendu();
  return v_row;
end; $$;
grant execute on function payer_dette(numeric) to authenticated;

create or replace function payer_pret(p_montant numeric)
returns citoyens language plpgsql security definer set search_path = public as $$
declare v_row citoyens;
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select * into v_row from citoyens where id = auth.uid();
  if v_row.tresorerie < p_montant then raise exception 'Trésorerie insuffisante.'; end if;
  update citoyens set tresorerie = tresorerie - p_montant, prets = greatest(0, prets - p_montant)
    where id = auth.uid() returning * into v_row;
  update tresor_public set solde_prive = solde_prive + p_montant where id = 1;
  insert into paiements_historique (citoyen_id, type, montant) values (auth.uid(), 'pret', p_montant);
  perform gouv_distribuer_argent_attendu();
  return v_row;
end; $$;
grant execute on function payer_pret(numeric) to authenticated;

-- Virements normaux -> la taxe va en privée ("la taxe sur les virements")
create or replace function virement_famille(p_destinataire_username text, p_montant numeric)
returns transferts language plpgsql security definer set search_path = public as $$
declare v_dest_id uuid; v_expediteur citoyens; v_taxe numeric; v_total numeric; v_row transferts;
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  if p_montant > 2000 then raise exception 'Le virement familial est limité à 2000 R$.'; end if;
  select id into v_dest_id from citoyens where lower(username) = lower(p_destinataire_username);
  if v_dest_id is null then raise exception 'Destinataire introuvable.'; end if;
  if v_dest_id = auth.uid() then raise exception 'Impossible de se virer de l''argent à soi-même.'; end if;

  select * into v_expediteur from citoyens where id = auth.uid();
  v_taxe := p_montant * 0.0125;
  v_total := p_montant + v_taxe;
  if v_expediteur.tresorerie < v_total then raise exception 'Trésorerie insuffisante (total avec taxe: %).', v_total; end if;

  update citoyens set tresorerie = tresorerie - v_total where id = auth.uid();
  update citoyens set tresorerie = tresorerie + p_montant where id = v_dest_id;
  update tresor_public set solde_prive = solde_prive + v_taxe where id = 1;

  insert into transferts (type, expediteur_id, destinataires, montant_par_personne, taxe_pourcentage, taxe_totale, total_debite, remboursable)
  values ('famille', auth.uid(), array[v_dest_id], p_montant, 1.25, v_taxe, v_total, false)
  returning * into v_row;
  perform gouv_distribuer_argent_attendu();
  return v_row;
end; $$;
grant execute on function virement_famille(text, numeric) to authenticated;

create or replace function virement_business(p_destinataires_usernames text[], p_montant_par_personne numeric)
returns transferts language plpgsql security definer set search_path = public as $$
declare v_dest_ids uuid[]; v_expediteur citoyens; v_total_verse numeric; v_taxe numeric; v_total_debite numeric; v_id uuid; v_row transferts;
begin
  if p_montant_par_personne <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select array_agg(id) into v_dest_ids from citoyens where lower(username) = any (select lower(u) from unnest(p_destinataires_usernames) as u);
  if v_dest_ids is null or array_length(v_dest_ids, 1) is null then raise exception 'Aucun destinataire valide.'; end if;
  if auth.uid() = any(v_dest_ids) then raise exception 'Impossible de s''inclure soi-même comme destinataire.'; end if;

  v_total_verse := p_montant_par_personne * array_length(v_dest_ids, 1);
  if v_total_verse > 6000 then raise exception 'Le virement business est limité à 6000 R$ au total.'; end if;

  select * into v_expediteur from citoyens where id = auth.uid();
  v_taxe := v_total_verse * 0.0165;
  v_total_debite := v_total_verse + v_taxe;
  if v_expediteur.tresorerie < v_total_debite then raise exception 'Trésorerie insuffisante (total avec taxe: %).', v_total_debite; end if;

  update citoyens set tresorerie = tresorerie - v_total_debite where id = auth.uid();
  foreach v_id in array v_dest_ids loop
    update citoyens set tresorerie = tresorerie + p_montant_par_personne where id = v_id;
  end loop;
  update tresor_public set solde_prive = solde_prive + v_taxe where id = 1;

  insert into transferts (type, expediteur_id, destinataires, montant_par_personne, taxe_pourcentage, taxe_totale, total_debite, remboursable)
  values ('business', auth.uid(), v_dest_ids, p_montant_par_personne, 1.65, v_taxe, v_total_debite, true)
  returning * into v_row;
  perform gouv_distribuer_argent_attendu();
  return v_row;
end; $$;
grant execute on function virement_business(text[], numeric) to authenticated;

create or replace function virement_econome(p_destinataire_username text, p_montant numeric)
returns transferts language plpgsql security definer set search_path = public as $$
declare v_dest_id uuid; v_expediteur citoyens; v_taxe numeric; v_total numeric; v_row transferts;
begin
  if p_montant < 6000 or p_montant > 500000 then
    raise exception 'Le virement économe doit être entre 6 000 R$ et 500 000 R$.';
  end if;
  select id into v_dest_id from citoyens where lower(username) = lower(p_destinataire_username);
  if v_dest_id is null then raise exception 'Destinataire introuvable.'; end if;
  if v_dest_id = auth.uid() then raise exception 'Impossible de se virer de l''argent à soi-même.'; end if;

  select * into v_expediteur from citoyens where id = auth.uid();
  v_taxe := p_montant * 0.0035;
  v_total := p_montant + v_taxe;
  if v_expediteur.tresorerie < v_total then raise exception 'Trésorerie insuffisante (total avec taxe: %).', v_total; end if;

  update citoyens set tresorerie = tresorerie - v_total where id = auth.uid();
  update citoyens set tresorerie = tresorerie + p_montant where id = v_dest_id;
  update tresor_public set solde_prive = solde_prive + v_taxe where id = 1;

  insert into transferts (type, expediteur_id, destinataires, montant_par_personne, taxe_pourcentage, taxe_totale, total_debite, remboursable)
  values ('econome', auth.uid(), array[v_dest_id], p_montant, 0.35, v_taxe, v_total, false)
  returning * into v_row;
  perform gouv_distribuer_argent_attendu();
  return v_row;
end; $$;
grant execute on function virement_econome(text, numeric) to authenticated;

-- Virements considérables -> la taxe/don va en privée
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
    update tresor_public set solde_prive = solde_prive + v_row.taxe_montant where id = 1;
    update virements_considerables set statut = 'accepte', traite_le = now() where id = p_id;
    perform gouv_distribuer_argent_attendu();
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

-- Déblocage des virements illimités -> privée (assimilé à l'achat d'un privilège)
create or replace function payer_virements_illimites()
returns void language plpgsql security definer set search_path = public as $$
declare v_citoyen citoyens;
begin
  select * into v_citoyen from citoyens where id = auth.uid();
  if v_citoyen.tresorerie < 50000000 then raise exception 'Trésorerie insuffisante (50 000 000 R$ requis).'; end if;
  update citoyens set tresorerie = tresorerie - 50000000, virements_illimites_jusqua = now() + interval '60 days'
    where id = auth.uid();
  update tresor_public set solde_prive = solde_prive + 50000000 where id = 1;
  perform gouv_distribuer_argent_attendu();
end; $$;
grant execute on function payer_virements_illimites() to authenticated;

-- Paiement des agents de la paix pour constat -> DÉBIT de la privée,
-- via gouv_payer_civil (jamais tronqué en silence : bascule sur la
-- publique si besoin, puis en argent attendu si les deux manquent).
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
    if v_uid is not null then perform gouv_payer_civil(v_uid, v_montant, 'privee'); end if;
  end if;
  if v_constat.username_agent_donne is not null and v_constat.username_agent_donne <> v_constat.username_agent_vu then
    select id into v_uid from citoyens where lower(username) = v_constat.username_agent_donne;
    if v_uid is not null then perform gouv_payer_civil(v_uid, v_montant, 'privee'); end if;
  end if;
  if v_constat.username_agent_assiste is not null
     and v_constat.username_agent_assiste <> v_constat.username_agent_vu
     and v_constat.username_agent_assiste <> v_constat.username_agent_donne then
    select id into v_uid from citoyens where lower(username) = v_constat.username_agent_assiste;
    if v_uid is not null then perform gouv_payer_civil(v_uid, v_montant, 'privee'); end if;
  end if;

  update constats_infraction set supprime_par_agent = true where id = p_id;
end;
$$;
grant execute on function admin_retirer_constat_avec_commission(uuid, numeric) to authenticated;


-- ============================================================
-- 5) SALAIRE — vient désormais du gouvernement (plus d'une banque)
-- ============================================================
-- Remplace le débit "banque nationale de la province de résidence" posé
-- par un patch précédent (le demandeur a annulé cette décision) : la
-- paie NETTE est maintenant financée par le gouvernement, en tentant
-- d'abord la trésorerie provinciale de résidence, puis les deux
-- trésoreries nationales (publique -> privée). Ce qui manque part en
-- argent attendu au lieu d'être créé de nulle part.
drop function if exists deposer_revenu_citoyen(numeric);
create or replace function deposer_revenu_citoyen(p_minutes numeric default 1.0/60)
returns public.citoyens language plpgsql security definer set search_path = public as $$
declare
  v_citoyen public.citoyens;
  v_taux_preventif numeric;
  v_brut numeric; v_tr numeric; v_te numeric;
  v_chomage numeric; v_retraite numeric; v_parentalite numeric; v_net numeric;
  v_periode_60 int;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;

  select * into v_citoyen from citoyens where id = auth.uid();
  if v_citoyen is null then raise exception 'Citoyen introuvable.'; end if;

  if est_jour_ferie(current_date) then
    update citoyens set derniere_synchro_tresorerie = now() where id = auth.uid() returning * into v_citoyen;
    return v_citoyen;
  end if;

  select taux_preventif into v_taux_preventif from parametres_fiscaux where id = 1;

  v_periode_60 := periode_60j_actuelle();
  if v_citoyen.periode_60j_index <> v_periode_60 then
    update citoyens set taxes_gouv_60j = 0, taxe_preventive_60j = 0, periode_60j_index = v_periode_60
      where id = auth.uid() returning * into v_citoyen;
  end if;

  v_brut := v_citoyen.salaire * p_minutes;
  v_tr := v_brut * (v_citoyen.taux_revenu / 100.0);
  v_te := v_brut * (v_taux_preventif / 100.0);
  v_chomage := v_brut * 0.0275;
  v_retraite := v_brut * 0.0675;
  v_parentalite := v_brut * 0.0025;
  v_net := v_brut - v_tr - v_te - v_chomage - v_retraite - v_parentalite;

  -- Les retenues (taxes + comptes d'épargne du citoyen) sont toujours
  -- appliquées, même si le gouvernement ne peut pas payer le net en
  -- entier : ce sont des obligations, pas un versement discrétionnaire.
  update citoyens
    set compte_chomage = compte_chomage + v_chomage,
        compte_retraite = compte_retraite + v_retraite,
        compte_parentalite = compte_parentalite + v_parentalite,
        taxes_gouv_60j = taxes_gouv_60j + v_tr,
        taxe_preventive_60j = taxe_preventive_60j + v_te,
        derniere_synchro_tresorerie = now()
    where id = auth.uid()
    returning * into v_citoyen;

  update tresor_public set solde = solde + v_tr + v_te, taxes_totales_periode = taxes_totales_periode + v_tr + v_te where id = 1;

  -- Le salaire net vient du gouvernement (trésorerie provinciale de
  -- résidence en premier, puis publique, puis privée) ; ce qui manque
  -- part dans l'argent attendu du citoyen.
  perform gouv_payer_civil(auth.uid(), v_net, 'publique', v_citoyen.province_residence);

  select * into v_citoyen from citoyens where id = auth.uid();
  perform gouv_distribuer_argent_attendu();
  return v_citoyen;
end;
$$;
grant execute on function deposer_revenu_citoyen(numeric) to authenticated;


-- ============================================================
-- 6) RENDEMENT DES CONTRIBUABLES — financé par la trésorerie publique
-- ============================================================
-- Même processus politique qu'avant (vote du Congrès + pourcentage
-- manuel 0-5%) : seul changement, l'argent sort réellement de la
-- trésorerie publique (via gouv_payer_civil, avec repli en argent
-- attendu si jamais elle ne suffit pas) au lieu d'être créé, et le
-- compteur de taxes de la période est remis à zéro.
create or replace function admin_traiter_redevance(
  p_nip text, p_decision text,
  p_congres_oui int default null, p_congres_non int default null, p_pourcentage numeric default null
) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_mon_username text; v_montant numeric; v_mot text; v_majorite numeric;
  v_gouv numeric; v_prev numeric; v_res jsonb;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé à l''administrateur.'; end if;
  if p_decision not in ('oui','non') then raise exception 'Décision invalide.'; end if;

  if not dans_fenetre_redevance() then
    if p_nip is null or p_nip <> '7000' then raise exception 'NIP invalide.'; end if;
  end if;

  select username into v_mon_username from citoyens where id = auth.uid();

  if p_decision = 'non' then
    update citoyens set taxes_gouv_60j = 0, taxe_preventive_60j = 0 where true;
    delete from transferts where true;
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
      v_res := gouv_payer_civil(v_id, v_montant, 'publique');
      insert into messages (type, expediteur_id, expediteur_username, destinataire_id, titre, contenu)
      values ('gouvernemental', auth.uid(), v_mon_username, v_id,
              'Rendement des contribuables',
              'Le rendement a été attribué par ' || p_congres_oui || ' chambres du Congrès (' || v_majorite || '%), vous avez été envoyé par le gouvernement : ' ||
              v_montant || ' R$ pour vous remercier de votre soutien et parce que la trésorerie du pays a fait un bénéfice ' || v_mot || '.' ||
              case when (v_res->>'manque')::numeric > 0 then ' (' || (v_res->>'manque') || ' R$ de ce montant a été placé en argent attendu, faute de fonds suffisants.)' else '' end);
    end if;
  end loop;

  update citoyens set taxes_gouv_60j = 0, taxe_preventive_60j = 0 where true;
  update tresor_public set taxes_totales_periode = 0 where id = 1;
  perform gouv_distribuer_argent_attendu();
  return 'Redevance attribuée à ' || p_pourcentage || '% (plafond 5000 R$/personne).';
end;
$$;
grant execute on function admin_traiter_redevance(text, text, int, int, numeric) to authenticated;


-- ============================================================
-- 7) PIB (réel) ET PALAMÖSS
-- ============================================================
create or replace function pib_actuel()
returns numeric language sql stable security definer set search_path = public as $$
  select
    coalesce((select solde + solde_prive from tresor_public where id = 1), 0)
    + coalesce((select sum(tresorerie + dettes + prets + argent_attendu + compte_chomage + compte_parentalite + compte_retraite) from citoyens), 0)
    + coalesce((select sum(tresorerie) from banques_nationales), 0);
$$;
grant execute on function pib_actuel() to authenticated, anon;

create or replace function palamoss_pourcentage()
returns numeric language plpgsql stable security definer set search_path = public as $$
declare
  v_pib numeric; v_ref numeric; v_croissance numeric; v_indice_croissance numeric;
  v_taxes numeric; v_taux_taxes numeric; v_indice_fiscal numeric; v_score numeric;
begin
  v_pib := pib_actuel();
  select pib_reference into v_ref from pib_historique where id = 1;
  if v_ref is null or v_ref = 0 then return 0; end if;

  v_croissance := ((v_pib - v_ref) / v_ref) * 100;
  v_indice_croissance := greatest(0, least(5, v_croissance));

  select taxes_totales_periode into v_taxes from tresor_public where id = 1;
  v_taux_taxes := case when v_pib = 0 then 0 else (v_taxes / v_pib) * 100 end;
  v_indice_fiscal := greatest(0, least(5, v_taux_taxes / 10));

  if v_indice_croissance = 0 or v_indice_fiscal = 0 then return 0; end if;

  v_score := (v_indice_croissance * 0.70) + (v_indice_fiscal * 0.30);
  return round(least(5, v_score), 2);
end; $$;
grant execute on function palamoss_pourcentage() to authenticated, anon;

-- Remplace tableau_de_bord_national() (posée par un patch précédent) pour
-- y ajouter le Palamöss et les taxes de la période en cours.
create or replace function tableau_de_bord_national()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_pib numeric; v_ref numeric; v_date timestamptz; v_variation numeric; v_taxes numeric;
begin
  perform _rafraichir_pib_historique();
  v_pib := pib_actuel();
  select pib_reference, date_reference into v_ref, v_date from pib_historique where id = 1;
  v_variation := case when v_ref = 0 then 0 else round(((v_pib - v_ref)/v_ref)*100, 4) end;
  select taxes_totales_periode into v_taxes from tresor_public where id = 1;
  return jsonb_build_object(
    'pib_actuel', v_pib, 'pib_reference', v_ref, 'date_reference', v_date, 'variation_pct', v_variation,
    'palamoss_pct', palamoss_pourcentage(), 'taxes_totales_periode', v_taxes,
    'dette_nationale', dette_nationale_argent_attendu()
  );
end; $$;
grant execute on function tableau_de_bord_national() to authenticated, anon;


-- ============================================================
-- 8) VUE GOUVERNEMENT DES TRÉSORERIES (pour l'onglet Administration)
-- ============================================================
create or replace function gouv_etat_tresoreries()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  return (
    select jsonb_build_object(
      'solde_prive', solde_prive, 'solde_publique', solde, 'option_paiement_attendu', option_paiement_attendu,
      'taxes_totales_periode', taxes_totales_periode
    ) from tresor_public where id = 1
  );
end; $$;
grant execute on function gouv_etat_tresoreries() to authenticated;

create or replace function gouv_liste_tresoreries_provinciales()
returns setof public.tresoreries_provinciales language sql stable security definer set search_path = public as $$
  select * from tresoreries_provinciales order by province;
$$;
grant execute on function gouv_liste_tresoreries_provinciales() to authenticated;

-- ============================================================
-- FIN
-- ============================================================
