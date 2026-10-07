-- ============================================================
-- patch-cib-entreprise-avancee-12.sql
-- À exécuter après patch-cib-entreprise-avancee-11.sql. Additif et rejouable.
--
--  1. NIP DE MAINTENANCE : l'administrateur définit un NIP à 8 chiffres ;
--     pendant la désactivation du portail, un petit champ en bas de
--     l'écran de maintenance permet d'entrer ce NIP — s'il correspond,
--     LA SESSION DE CE NAVIGATEUR charge le portail normalement, pour
--     lui seul (les autres continuent de voir le message).
--  2. CODE UNIQUE DES CONSTATS : C-[9 chiffres], généré automatiquement,
--     à fournir obligatoirement pour contester (le gouvernement peut
--     ainsi retrouver le constat par ce code).
--  3. SUPPRESSION D'ENTREPRISE PAR LE PDG : mot de passe + nom exact de
--     l'entreprise requis.
--  4. TRÉSORERIE PRIVÉE DU GOUVERNEMENT : le compte @gouvernement avait
--     sa propre trésorerie personnelle de citoyen (comme n'importe qui),
--     ce qui causait "trésorerie insuffisante" alors que l'argent existe
--     dans tresor_public.solde_prive. Les fonctions qui déplacent de
--     l'argent DEPUIS le compte connecté (virements, achat de capital,
--     paiement de constat) utilisent maintenant tresor_public.solde_prive
--     quand le compte connecté est administrateur.
--  5. TAXATION DES PROVINCES : nouvelle liste officielle (remplace
--     l'ancienne, qui ne correspond plus), avec type de territoire
--     (TP/TOM/TC) pour calculer la Taxe sur les Achats Nationaux (TAN :
--     10 % TP, 12 % TOM, 14 % TC — fixe) et un taux de Taxe sur les
--     Achats Provinciaux (TAP, 2 à 10 %, modifiable par province dans
--     l'administration).
-- ============================================================


-- ============================================================
-- 1) NIP DE MAINTENANCE
-- ============================================================
alter table parametres_fiscaux add column if not exists portail_nip_urgence text;

create or replace function gouv_definir_nip_maintenance(p_nip text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  if p_nip !~ '^[0-9]{8}$' then raise exception 'Le NIP doit comporter exactement 8 chiffres.'; end if;
  update parametres_fiscaux set portail_nip_urgence = p_nip where id = 1;
end; $$;
grant execute on function gouv_definir_nip_maintenance(text) to authenticated;

-- Callable sans connexion : vérifie seulement si le NIP correspond (jamais le NIP lui-même).
create or replace function verifier_nip_maintenance(p_nip text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select portail_nip_urgence from parametres_fiscaux where id = 1) = p_nip, false);
$$;
grant execute on function verifier_nip_maintenance(text) to authenticated, anon;


-- ============================================================
-- 2) CODE UNIQUE DES CONSTATS
-- ============================================================
alter table constats_infraction add column if not exists code_suivi text unique;

do $$
declare r record;
begin
  for r in select id from constats_infraction where code_suivi is null loop
    update constats_infraction set code_suivi = 'C-' || lpad(floor(random() * 1000000000)::text, 9, '0') where id = r.id;
  end loop;
end $$;

create or replace function _generer_code_constat()
returns text language plpgsql as $$
declare v_code text;
begin
  loop
    v_code := 'C-' || lpad(floor(random() * 1000000000)::text, 9, '0');
    exit when not exists (select 1 from constats_infraction where code_suivi = v_code);
  end loop;
  return v_code;
end; $$;

-- Génère le code automatiquement pour chaque nouveau constat.
create or replace function _constat_generer_code()
returns trigger language plpgsql as $$
begin
  if new.code_suivi is null then new.code_suivi := _generer_code_constat(); end if;
  return new;
end; $$;
drop trigger if exists trg_constat_code on constats_infraction;
create trigger trg_constat_code before insert on constats_infraction
  for each row execute function _constat_generer_code();

-- Contester par code de suivi (en plus de l'id, pour que le gouvernement
-- puisse toujours retrouver le constat par ce code précis).
create or replace function contester_constat_par_code(p_code_suivi text, p_motif text, p_preuve_chemin text default null)
returns constats_contestations language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  select id into v_id from constats_infraction where code_suivi = trim(p_code_suivi) and destinataire_id = auth.uid();
  if v_id is null then raise exception 'Constat introuvable pour ce code de suivi.'; end if;
  return contester_constat(v_id, p_motif, p_preuve_chemin);
end; $$;
grant execute on function contester_constat_par_code(text, text, text) to authenticated;

-- Le code de suivi est ajouté à la fiche visible par le gouvernement.
create or replace function gouv_liste_contestations_constats(p_statut text default 'en_attente')
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not est_admin_actuel() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
    'id', k.id, 'username', c.username, 'motif', k.motif, 'preuve_chemin', k.preuve_chemin, 'cree_le', k.cree_le,
    'constat_code', ci.code_suivi, 'constat_infraction', ci.infraction, 'constat_raison', ci.raison, 'constat_prix_total', ci.prix_total
  ) order by k.cree_le), '[]'::jsonb) end
  from constats_contestations k join citoyens c on c.id = k.citoyen_id join constats_infraction ci on ci.id = k.constat_id
  where k.statut = p_statut;
$$;
grant execute on function gouv_liste_contestations_constats(text) to authenticated;


-- ============================================================
-- 3) SUPPRESSION D'ENTREPRISE PAR LE PDG
-- ============================================================
create or replace function entreprise_supprimer(p_entreprise_id uuid, p_nom text, p_mdp text)
returns void language plpgsql security definer set search_path = public as $$
declare v_role text; v_nom_reel text;
begin
  select role into v_role from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_role is distinct from 'pdg' then raise exception 'Réservé au PDG.'; end if;
  select nom into v_nom_reel from entreprises where id = p_entreprise_id;
  if v_nom_reel is null or lower(trim(p_nom)) <> lower(v_nom_reel) then raise exception 'Le nom de l''entreprise ne correspond pas.'; end if;
  if not _verifier_mdp(p_mdp) then raise exception 'Mot de passe incorrect.'; end if;
  delete from entreprises where id = p_entreprise_id;
end; $$;
grant execute on function entreprise_supprimer(uuid, text, text) to authenticated;


-- ============================================================
-- 4) TRÉSORERIE PRIVÉE DU GOUVERNEMENT
-- ============================================================
create or replace function _ma_tresorerie()
returns numeric language sql stable security definer set search_path = public as $$
  select case when est_admin_actuel() then (select solde_prive from tresor_public where id = 1)
    else (select tresorerie from citoyens where id = auth.uid()) end;
$$;

create or replace function _debiter_ma_tresorerie(p_montant numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  if est_admin_actuel() then update tresor_public set solde_prive = solde_prive - p_montant where id = 1;
  else update citoyens set tresorerie = tresorerie - p_montant where id = auth.uid(); end if;
end; $$;

create or replace function _crediter_ma_tresorerie(p_montant numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  if est_admin_actuel() then update tresor_public set solde_prive = solde_prive + p_montant where id = 1;
  else update citoyens set tresorerie = tresorerie + p_montant where id = auth.uid(); end if;
end; $$;

-- Retouches : les fonctions à moi qui débitent explicitement citoyens.tresorerie
-- pour auth.uid() utilisent maintenant ces helpers (donc @gouvernement pioche dans
-- sa trésorerie privée, pas dans une trésorerie personnelle de civil).
create or replace function virement_famille(p_destinataire_username text, p_montant numeric)
returns transferts language plpgsql security definer set search_path = public as $$
declare v_dest_id uuid; v_ent_id uuid; v_taxe numeric; v_total numeric; v_row transferts; v_dispo numeric;
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  if p_montant > 2000 then raise exception 'Le virement familial est limité à 2000 R$.'; end if;

  v_dest_id := _resoudre_citoyen_ou_cib(p_destinataire_username);
  if v_dest_id is null then v_ent_id := _resoudre_entreprise_reception(p_destinataire_username); end if;
  if v_dest_id is null and v_ent_id is null then raise exception 'Destinataire introuvable (nom d''utilisateur ou CIB).'; end if;
  if v_dest_id = auth.uid() then raise exception 'Impossible de se virer de l''argent à soi-même.'; end if;

  v_taxe := p_montant * 0.0125;
  v_total := p_montant + v_taxe;
  v_dispo := _ma_tresorerie();
  if v_dispo < v_total then raise exception 'Trésorerie insuffisante (total avec taxe: %).', v_total; end if;

  perform _debiter_ma_tresorerie(v_total);
  if v_ent_id is not null then
    update entreprises set tresorerie = tresorerie + p_montant where id = v_ent_id;
    perform _entreprise_regler_dette_employes(v_ent_id);
    perform _entreprise_log(v_ent_id, 'ajout_fonds', jsonb_build_object('citoyen_id', auth.uid(), 'montant', p_montant));
  else
    update citoyens set tresorerie = tresorerie + p_montant where id = v_dest_id;
  end if;
  update tresor_public set solde = solde + v_taxe where id = 1;

  insert into transferts (type, expediteur_id, destinataires, montant_par_personne, taxe_pourcentage, taxe_totale, total_debite, remboursable, entreprise_destinataire_id)
  values ('famille', auth.uid(), case when v_dest_id is not null then array[v_dest_id] else '{}'::uuid[] end, p_montant, 1.25, v_taxe, v_total, false, v_ent_id)
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function virement_famille(text, numeric) to authenticated;

create or replace function virement_econome(p_destinataire_username text, p_montant numeric)
returns transferts language plpgsql security definer set search_path = public as $$
declare v_dest_id uuid; v_ent_id uuid; v_taxe numeric; v_total numeric; v_row transferts; v_dispo numeric;
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  if p_montant < 6000 or p_montant > 500000 then raise exception 'Le virement économe est réservé aux montants entre 6 000 R$ et 500 000 R$.'; end if;

  v_dest_id := _resoudre_citoyen_ou_cib(p_destinataire_username);
  if v_dest_id is null then v_ent_id := _resoudre_entreprise_reception(p_destinataire_username); end if;
  if v_dest_id is null and v_ent_id is null then raise exception 'Destinataire introuvable (nom d''utilisateur ou CIB).'; end if;
  if v_dest_id = auth.uid() then raise exception 'Impossible de se virer de l''argent à soi-même.'; end if;

  v_taxe := p_montant * 0.0035;
  v_total := p_montant + v_taxe;
  v_dispo := _ma_tresorerie();
  if v_dispo < v_total then raise exception 'Trésorerie insuffisante (total avec taxe: %).', v_total; end if;

  perform _debiter_ma_tresorerie(v_total);
  if v_ent_id is not null then
    update entreprises set tresorerie = tresorerie + p_montant where id = v_ent_id;
    perform _entreprise_regler_dette_employes(v_ent_id);
    perform _entreprise_log(v_ent_id, 'ajout_fonds', jsonb_build_object('citoyen_id', auth.uid(), 'montant', p_montant));
  else
    update citoyens set tresorerie = tresorerie + p_montant where id = v_dest_id;
  end if;
  update tresor_public set solde = solde + v_taxe where id = 1;

  insert into transferts (type, expediteur_id, destinataires, montant_par_personne, taxe_pourcentage, taxe_totale, total_debite, remboursable, entreprise_destinataire_id)
  values ('econome', auth.uid(), case when v_dest_id is not null then array[v_dest_id] else '{}'::uuid[] end, p_montant, 0.35, v_taxe, v_total, false, v_ent_id)
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function virement_econome(text, numeric) to authenticated;

create or replace function virement_vers_entreprise(p_cib text, p_montant numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_ent_id uuid; v_dispo numeric;
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select c.entreprise_id into v_ent_id from entreprises_cib c join entreprises e on e.id = c.entreprise_id
    where c.cib_reception = p_cib and e.statut = 'acceptee';
  if v_ent_id is null then raise exception 'CIB de réception introuvable.'; end if;
  v_dispo := _ma_tresorerie();
  if v_dispo < p_montant then raise exception 'Trésorerie insuffisante.'; end if;

  perform _debiter_ma_tresorerie(p_montant);
  update entreprises set tresorerie = tresorerie + p_montant where id = v_ent_id;
  perform _entreprise_regler_dette_employes(v_ent_id);
  perform _entreprise_log(v_ent_id, 'ajout_fonds', jsonb_build_object('citoyen_id', auth.uid(), 'montant', p_montant));
end; $$;
grant execute on function virement_vers_entreprise(text, numeric) to authenticated;

create or replace function entreprise_acheter_capital(p_entreprise_id uuid, p_pourcentage numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_ent entreprises; v_cout numeric; v_deja numeric; v_dispo numeric; v_bonus numeric; v_tresor_apres_cout numeric;
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
  v_dispo := _ma_tresorerie();
  if v_dispo < v_cout then raise exception 'Trésorerie insuffisante (coût : % R$).', v_cout; end if;

  v_bonus := round(p_pourcentage / 100.0 * coalesce(v_ent.tresorerie_mise_en_vente, 0), 2);
  v_tresor_apres_cout := v_ent.tresorerie + v_cout;
  v_bonus := least(v_bonus, greatest(v_tresor_apres_cout, 0));

  perform _debiter_ma_tresorerie(v_cout);
  perform _sans_partage(true);
  update entreprises set tresorerie = tresorerie + v_cout - v_bonus, capital_en_vente_pct = capital_en_vente_pct - p_pourcentage where id = p_entreprise_id;
  perform _sans_partage(false);
  insert into entreprises_capital_detenteurs (entreprise_id, citoyen_id, pourcentage, solde, solde_all_time)
    values (p_entreprise_id, auth.uid(), p_pourcentage, v_bonus, v_bonus)
    on conflict (entreprise_id, citoyen_id) do update set
      pourcentage = entreprises_capital_detenteurs.pourcentage + p_pourcentage,
      solde = entreprises_capital_detenteurs.solde + v_bonus,
      solde_all_time = entreprises_capital_detenteurs.solde_all_time + v_bonus;
  perform _entreprise_regler_dette_employes(p_entreprise_id);
  perform _entreprise_log(p_entreprise_id, 'vente_capital',
    jsonb_build_object('acheteur_username', (select username from citoyens where id = auth.uid()), 'pourcentage', p_pourcentage, 'cout', v_cout, 'montant', v_cout, 'bonus_halgeberg', v_bonus));
  perform _entreprise_maj_pdg_capital(p_entreprise_id);
end; $$;
grant execute on function entreprise_acheter_capital(uuid, numeric) to authenticated;

create or replace function payer_constat(p_id uuid)
returns constats_infraction language plpgsql security definer set search_path = public as $$
declare v_constat constats_infraction; v_dispo numeric;
begin
  select * into v_constat from constats_infraction where id = p_id and destinataire_id = auth.uid();
  if v_constat.id is null then raise exception 'Constat introuvable.'; end if;
  if v_constat.paye then raise exception 'Ce constat a déjà été payé.'; end if;
  if v_constat.annule then raise exception 'Ce constat a été annulé (contestation acceptée).'; end if;
  if exists (select 1 from constats_contestations where constat_id = p_id and statut = 'en_attente') then
    raise exception 'Une contestation est en attente pour ce constat : paiement bloqué jusqu''à la décision.';
  end if;

  v_dispo := _ma_tresorerie();
  if v_dispo < v_constat.prix_total then raise exception 'Trésorerie insuffisante.'; end if;

  perform _debiter_ma_tresorerie(v_constat.prix_total);
  update tresor_public set solde_prive = solde_prive + v_constat.prix_total where id = 1;
  update constats_infraction set paye = true, paye_le = now() where id = p_id returning * into v_constat;
  return v_constat;
end; $$;
grant execute on function payer_constat(uuid) to authenticated;


-- ============================================================
-- 5) TAXATION DES PROVINCES (TAP / TAN)
-- ============================================================
create table if not exists provinces_taxation (
  province        text primary key,
  type_territoire text not null check (type_territoire in ('TP','TOM','TC')),
  taux_tap        numeric not null default 5 check (taux_tap >= 2 and taux_tap <= 10)
);

-- Remplace l'ancienne liste (différente, obsolète) par la liste officielle actuelle.
truncate table provinces_taxation;
insert into provinces_taxation (province, type_territoire) values
  ('Gibaltage', 'TOM'), ('Talon Étalien', 'TP'), ('Talon Andrien', 'TP'), ('Fleury', 'TP'),
  ('Baxe', 'TP'), ('Vénésie', 'TP'), ('Marcio', 'TP'), ('Romagna', 'TP'),
  ('Grâdes-Tivainne', 'TP'), ('Aloies', 'TP'), ('Balques', 'TP'), ('Alanbie-Brien-Jance', 'TP'),
  ('Île Saint-Étienne', 'TOM'), ('Ombrie', 'TP'), ('Vénéz', 'TP'), ('Milela', 'TP'),
  ('Pruxe', 'TOM'), ('Quoueta-Et-Milenniar-Étalois', 'TP'), ('Tonawa', 'TP'), ('Côte-Anglaise', 'TP'),
  ('Grande-Capitale', 'TP'), ('Zone Haute-Romanie', 'TP'), ('Île-de-L''île', 'TP'), ('Bushard Bay', 'TP'),
  ('Braume', 'TP'), ('Nouvelle-Braume-Chiranie', 'TP'), ('Haute-Étalie-du-Glaive', 'TP'), ('Zone Dovintski', 'TC'),
  ('Grand-Nord', 'TP'), ('Hors-Orremaux', 'TP'), ('Nouvelle-Étalie', 'TP'), ('Alten', 'TP'),
  ('Basse-Alten', 'TP'), ('Waterland', 'TP');

alter table provinces_taxation enable row level security;
drop policy if exists "Lecture publique de la taxation des provinces" on provinces_taxation;
create policy "Lecture publique de la taxation des provinces" on provinces_taxation for select using (true);

create or replace function gouv_definir_taux_tap(p_province text, p_taux numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  if p_taux < 2 or p_taux > 10 then raise exception 'Le taux TAP doit être entre 2 %% et 10 %%.'; end if;
  update provinces_taxation set taux_tap = p_taux where province = p_province;
  if not found then raise exception 'Province introuvable.'; end if;
end; $$;
grant execute on function gouv_definir_taux_tap(text, numeric) to authenticated;

create or replace function liste_provinces_taxation()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('province', province, 'type_territoire', type_territoire, 'taux_tap', taux_tap) order by province), '[]'::jsonb)
  from provinces_taxation;
$$;
grant execute on function liste_provinces_taxation() to authenticated, anon;

-- Taux TAN fixe selon le type de territoire (10 % TP, 12 % TOM, 14 % TC).
create or replace function taux_tan_province(p_province text)
returns numeric language sql stable security definer set search_path = public as $$
  select case type_territoire when 'TP' then 10 when 'TOM' then 12 when 'TC' then 14 end from provinces_taxation where province = p_province;
$$;
grant execute on function taux_tan_province(text) to authenticated, anon;

-- ============================================================
-- FIN
-- ============================================================
