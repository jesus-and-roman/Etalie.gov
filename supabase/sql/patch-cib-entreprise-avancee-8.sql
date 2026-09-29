-- ============================================================
-- patch-cib-entreprise-avancee-8.sql
-- À exécuter après patch-cib-entreprise-avancee-7.sql. Additif et rejouable.
--
--  1. CORRECTIF Halgeberg : le bonus versé au capital de l'acheteur était
--     "créé" sans jamais être retiré de la trésorerie de l'entreprise
--     (de l'argent apparaissait de nulle part). Il est maintenant
--     RÉELLEMENT transféré : trésorerie de l'entreprise → capital de
--     l'acheteur, en plus du prix payé qui, lui, entre normalement dans
--     la trésorerie. Le bonus est plafonné à ce qui reste après l'ajout
--     du prix payé, pour ne jamais rendre la trésorerie négative.
--  2. PDG PAR CAPITAL : si un détenteur de capital (autre que l'État)
--     dépasse la part restante de l'entreprise elle-même, il est ajouté
--     automatiquement comme employé avec le rôle "pdg_capital" (droits
--     plancher non retirables : voir les 3 CIB, déposer les rapports,
--     définir le mode de paiement/l'option de défaillance — le PDG peut
--     en ajouter d'autres, jamais en retirer). Il ne peut pas être
--     changé de rôle manuellement, et n'est retiré automatiquement que
--     si sa part redescend sous celle de l'entreprise.
--  3. Aperçu conseiller SANS demande : trésorerie/dettes/capitaux du
--     client, visibles dès qu'un lien existe, pour l'aider à rédiger ses
--     demandes.
--  4. Rapport d'impôt MANUEL d'entreprise : seulement dans les 5 derniers
--     jours du mois (le rapport automatique, lui, reste inchangé).
--  5. Mode de création d'entreprise choisi par le gouvernement : liberté
--     (aucune vérification, acceptée immédiatement) ou vérification (par
--     défaut, inchangé).
-- ============================================================


-- ============================================================
-- 1) CORRECTIF DU BONUS HALGEBERG (transfert réel)
-- ============================================================
create or replace function entreprise_acheter_capital(p_entreprise_id uuid, p_pourcentage numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_ent entreprises; v_cout numeric; v_deja numeric; v_tresor numeric; v_bonus numeric; v_tresor_apres_cout numeric;
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
  select tresorerie into v_tresor from citoyens where id = auth.uid() for update;
  if v_tresor < v_cout then raise exception 'Trésorerie insuffisante (coût : % R$).', v_cout; end if;

  -- Bonus Halgeberg : % × trésorerie figée à la mise en vente, RÉELLEMENT
  -- transféré de la trésorerie de l'entreprise vers le capital de l'acheteur.
  v_bonus := round(p_pourcentage / 100.0 * coalesce(v_ent.tresorerie_mise_en_vente, 0), 2);
  v_tresor_apres_cout := v_ent.tresorerie + v_cout;
  v_bonus := least(v_bonus, greatest(v_tresor_apres_cout, 0));

  update citoyens set tresorerie = tresorerie - v_cout where id = auth.uid();
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


-- ============================================================
-- 2) PDG PAR CAPITAL
-- ============================================================
alter table entreprises_membres drop constraint if exists entreprises_membres_role_check;
alter table entreprises_membres add constraint entreprises_membres_role_check check (role in ('pdg','co_pdg','employe','pdg_capital'));

alter table entreprises add column if not exists droits_pdg_capital text[] not null default array[
  'voir_cib_impots','voir_cib_envoi','voir_cib_reception','deposer_impot','definir_mode_paiement'
]::text[];

-- Droits plancher du PDG par capital : toujours présents, jamais retirables.
create or replace function entreprise_definir_droits_pdg_capital(p_entreprise_id uuid, p_droits text[])
returns void language plpgsql security definer set search_path = public as $$
declare v_plancher text[] := array['voir_cib_impots','voir_cib_envoi','voir_cib_reception','deposer_impot','definir_mode_paiement'];
begin
  perform _exige_droit(p_entreprise_id, 'modifier_droits');
  update entreprises set droits_pdg_capital = (select array_agg(distinct d) from unnest(coalesce(p_droits, '{}') || v_plancher) d)
    where id = p_entreprise_id;
end; $$;
grant execute on function entreprise_definir_droits_pdg_capital(uuid, text[]) to authenticated;

create or replace function _entreprise_a_droit(p_entreprise_id uuid, p_droit text, p_citoyen_id uuid default null)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v_cid uuid; v_role text; v_role_id uuid; v_droits_co text[]; v_droits_role text[];
begin
  v_cid := coalesce(p_citoyen_id, auth.uid());
  select role, role_id into v_role, v_role_id from entreprises_membres
    where entreprise_id = p_entreprise_id and citoyen_id = v_cid;
  if v_role is null then return false; end if;
  if v_role = 'pdg' then return true; end if;
  if v_role = 'co_pdg' then
    select droits_co_pdg into v_droits_co from entreprises where id = p_entreprise_id;
    return p_droit = any(coalesce(v_droits_co, '{}'));
  end if;
  if v_role = 'pdg_capital' then
    select droits_pdg_capital into v_droits_co from entreprises where id = p_entreprise_id;
    return p_droit = any(coalesce(v_droits_co, '{}'));
  end if;
  if v_role_id is null then return false; end if;
  select droits into v_droits_role from entreprises_roles where id = v_role_id;
  return p_droit = any(coalesce(v_droits_role, '{}'));
end; $$;

-- Recalcule et applique automatiquement le rôle "pdg_capital" pour une entreprise.
create or replace function _entreprise_maj_pdg_capital(p_entreprise_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_tiers_total numeric; v_pct_entreprise numeric; v_top_citoyen uuid; v_top_pct numeric; v_actuel uuid; v_garde boolean;
begin
  select coalesce(sum(pourcentage), 0) into v_tiers_total from entreprises_capital_detenteurs where entreprise_id = p_entreprise_id;
  v_pct_entreprise := 100 - v_tiers_total;

  select citoyen_id into v_actuel from entreprises_membres where entreprise_id = p_entreprise_id and role = 'pdg_capital';
  if v_actuel is not null then
    select exists (select 1 from entreprises_capital_detenteurs
      where entreprise_id = p_entreprise_id and citoyen_id = v_actuel and not est_gouvernement and pourcentage > v_pct_entreprise)
      into v_garde;
    if not v_garde then
      delete from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = v_actuel and role = 'pdg_capital';
      v_actuel := null;
    end if;
  end if;

  if v_actuel is null then
    select citoyen_id, pourcentage into v_top_citoyen, v_top_pct from entreprises_capital_detenteurs
      where entreprise_id = p_entreprise_id and not est_gouvernement and citoyen_id is not null and pourcentage > v_pct_entreprise
      order by pourcentage desc limit 1;
    if v_top_citoyen is not null then
      insert into entreprises_membres (entreprise_id, citoyen_id, role) values (p_entreprise_id, v_top_citoyen, 'pdg_capital')
        on conflict (entreprise_id, citoyen_id) do update set role = 'pdg_capital'
        where entreprises_membres.role = 'employe';
    end if;
  end if;
end; $$;

-- Appliqué après chaque opération qui change la répartition du capital.
create or replace function capital_acheter_tiers(p_offre_id uuid, p_pourcentage numeric)
returns void language plpgsql security definer set search_path = public as $$
declare o capital_offres_tiers; v_cout numeric; v_tresor numeric; v_detenu_avant numeric;
  v_solde_avant numeric; v_all_time_avant numeric; v_part numeric; v_solde_transfere numeric; v_all_time_transfere numeric;
begin
  select * into o from capital_offres_tiers where id = p_offre_id for update;
  if o.id is null then raise exception 'Offre introuvable.'; end if;
  if o.vendeur_id = auth.uid() then raise exception 'Vous ne pouvez pas acheter votre propre offre.'; end if;
  if p_pourcentage <= 0 or round(p_pourcentage * 10) <> p_pourcentage * 10 then raise exception 'Le pourcentage doit être un multiple de 0,1 %%.'; end if;
  if p_pourcentage > o.pourcentage then raise exception 'Il ne reste que % %% en vente.', o.pourcentage; end if;

  v_cout := (p_pourcentage / 0.1) * o.prix_par_dixieme;
  select tresorerie into v_tresor from citoyens where id = auth.uid() for update;
  if v_tresor < v_cout then raise exception 'Trésorerie insuffisante (coût : % R$).', v_cout; end if;

  select pourcentage, solde, solde_all_time into v_detenu_avant, v_solde_avant, v_all_time_avant
    from entreprises_capital_detenteurs where entreprise_id = o.entreprise_id and citoyen_id = o.vendeur_id for update;
  v_part := case when coalesce(v_detenu_avant, 0) > 0 then p_pourcentage / v_detenu_avant else 0 end;
  v_solde_transfere := round(coalesce(v_solde_avant, 0) * v_part, 2);
  v_all_time_transfere := round(coalesce(v_all_time_avant, 0) * v_part, 2);

  update citoyens set tresorerie = tresorerie - v_cout where id = auth.uid();
  update citoyens set tresorerie = tresorerie + v_cout where id = o.vendeur_id;

  update entreprises_capital_detenteurs set
    pourcentage = pourcentage - p_pourcentage, solde = solde - v_solde_transfere, solde_all_time = solde_all_time - v_all_time_transfere
    where entreprise_id = o.entreprise_id and citoyen_id = o.vendeur_id;
  delete from entreprises_capital_detenteurs where entreprise_id = o.entreprise_id and citoyen_id = o.vendeur_id and pourcentage <= 0;

  insert into entreprises_capital_detenteurs (entreprise_id, citoyen_id, pourcentage, solde, solde_all_time)
    values (o.entreprise_id, auth.uid(), p_pourcentage, v_solde_transfere, v_all_time_transfere)
  on conflict (entreprise_id, citoyen_id) do update set
    pourcentage = entreprises_capital_detenteurs.pourcentage + p_pourcentage,
    solde = entreprises_capital_detenteurs.solde + v_solde_transfere,
    solde_all_time = entreprises_capital_detenteurs.solde_all_time + v_all_time_transfere;

  if p_pourcentage >= o.pourcentage then delete from capital_offres_tiers where id = o.id;
  else update capital_offres_tiers set pourcentage = pourcentage - p_pourcentage where id = o.id; end if;
  perform _entreprise_maj_pdg_capital(o.entreprise_id);
end; $$;
grant execute on function capital_acheter_tiers(uuid, numeric) to authenticated;

create or replace function entreprise_racheter_capital(p_entreprise_id uuid, p_offre_id uuid, p_pourcentage numeric)
returns void language plpgsql security definer set search_path = public as $$
declare o capital_offres_tiers; v_cout numeric; v_tresor numeric; v_detenu_avant numeric; v_solde_avant numeric; v_all_time_avant numeric; v_part numeric;
begin
  perform _exige_droit(p_entreprise_id, 'vendre_capital');
  select * into o from capital_offres_tiers where id = p_offre_id and entreprise_id = p_entreprise_id for update;
  if o.id is null then raise exception 'Cette offre ne concerne pas cette entreprise.'; end if;
  if p_pourcentage <= 0 or round(p_pourcentage * 10) <> p_pourcentage * 10 then raise exception 'Le pourcentage doit être un multiple de 0,1 %%.'; end if;
  if p_pourcentage > o.pourcentage then raise exception 'Il ne reste que % %% en vente.', o.pourcentage; end if;

  v_cout := (p_pourcentage / 0.1) * o.prix_par_dixieme;
  select tresorerie into v_tresor from entreprises where id = p_entreprise_id for update;
  if v_tresor < v_cout then raise exception 'Trésorerie de l''entreprise insuffisante (coût : % R$).', v_cout; end if;

  select pourcentage, solde, solde_all_time into v_detenu_avant, v_solde_avant, v_all_time_avant
    from entreprises_capital_detenteurs where entreprise_id = o.entreprise_id and citoyen_id = o.vendeur_id for update;
  v_part := case when coalesce(v_detenu_avant, 0) > 0 then p_pourcentage / v_detenu_avant else 0 end;

  update entreprises set tresorerie = tresorerie - v_cout where id = p_entreprise_id;
  update citoyens set tresorerie = tresorerie + v_cout where id = o.vendeur_id;

  update entreprises_capital_detenteurs set
    pourcentage = pourcentage - p_pourcentage,
    solde = solde - round(coalesce(v_solde_avant, 0) * v_part, 2),
    solde_all_time = solde_all_time - round(coalesce(v_all_time_avant, 0) * v_part, 2)
    where entreprise_id = o.entreprise_id and citoyen_id = o.vendeur_id;
  delete from entreprises_capital_detenteurs where entreprise_id = o.entreprise_id and citoyen_id = o.vendeur_id and pourcentage <= 0;

  if p_pourcentage >= o.pourcentage then delete from capital_offres_tiers where id = o.id;
  else update capital_offres_tiers set pourcentage = pourcentage - p_pourcentage where id = o.id; end if;
  perform _entreprise_log(p_entreprise_id, 'vente_capital',
    jsonb_build_object('acheteur_username', 'entreprise (rachat)', 'pourcentage', p_pourcentage, 'cout', v_cout, 'montant', v_cout));
  perform _entreprise_maj_pdg_capital(p_entreprise_id);
end; $$;
grant execute on function entreprise_racheter_capital(uuid, uuid, numeric) to authenticated;

create or replace function _capital_gouv_accepter(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare o capital_offres_gouvernement; v_vendu numeric; v_cout numeric; v_solde numeric;
begin
  select * into o from capital_offres_gouvernement where id = p_id for update;
  select coalesce(sum(pourcentage), 0) into v_vendu from entreprises_capital_detenteurs where entreprise_id = o.entreprise_id;
  if v_vendu + o.pourcentage > 100 then raise exception 'L''entreprise ne possède plus assez de capital.'; end if;
  v_cout := (o.pourcentage / 0.01) * o.prix_par_centieme;
  select solde into v_solde from tresor_public where id = 1 for update;
  if v_solde < v_cout then raise exception 'Trésorerie publique insuffisante (% R$ disponibles, % R$ requis).', v_solde, v_cout; end if;
  update tresor_public set solde = solde - v_cout where id = 1;
  perform _sans_partage(true);
  update entreprises set tresorerie = tresorerie + v_cout where id = o.entreprise_id;
  perform _sans_partage(false);
  insert into entreprises_capital_detenteurs (entreprise_id, citoyen_id, est_gouvernement, pourcentage)
    values (o.entreprise_id, null, true, o.pourcentage)
    on conflict (entreprise_id) where est_gouvernement do update
      set pourcentage = entreprises_capital_detenteurs.pourcentage + excluded.pourcentage;
  update capital_offres_gouvernement set statut = 'acceptee' where id = p_id;
  perform _entreprise_log(o.entreprise_id, 'capital_gouvernement',
    jsonb_build_object('acheteur_username', 'gouvernement', 'pourcentage', o.pourcentage, 'cout', v_cout, 'montant', v_cout));
  perform _entreprise_regler_dette_employes(o.entreprise_id);
  perform _entreprise_maj_pdg_capital(o.entreprise_id);
end; $$;


-- ============================================================
-- 3) APERÇU CONSEILLER SANS DEMANDE
-- ============================================================
create or replace function conseiller_apercu_client(p_client_username text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_client uuid;
begin
  select l.client_id into v_client from conseiller_liens l join citoyens c on c.id = l.client_id
    where lower(c.username) = lower(trim(p_client_username)) and l.conseiller_id = auth.uid();
  if v_client is null then raise exception 'Vous n''êtes pas le conseiller financier de ce client.'; end if;
  return jsonb_build_object(
    'tresorerie', (select tresorerie from citoyens where id = v_client),
    'dettes', (select dettes from citoyens where id = v_client),
    'prets', (select prets from citoyens where id = v_client),
    'argent_attendu', (select argent_attendu from citoyens where id = v_client),
    'compte_chomage', (select compte_chomage from citoyens where id = v_client),
    'compte_retraite', (select compte_retraite from citoyens where id = v_client),
    'compte_parentalite', (select compte_parentalite from citoyens where id = v_client),
    'entreprises', (select coalesce(jsonb_agg(jsonb_build_object('entreprise_id', e.id, 'nom', e.nom, 'role', m.role, 'salaire_horaire', m.salaire_horaire)), '[]'::jsonb)
      from entreprises_membres m join entreprises e on e.id = m.entreprise_id where m.citoyen_id = v_client),
    'capitaux', (select coalesce(jsonb_agg(jsonb_build_object('entreprise', e.nom, 'entreprise_id', e.id, 'pourcentage', d.pourcentage, 'solde', d.solde)), '[]'::jsonb)
      from entreprises_capital_detenteurs d join entreprises e on e.id = d.entreprise_id where d.citoyen_id = v_client)
  );
end; $$;
grant execute on function conseiller_apercu_client(text) to authenticated;


-- ============================================================
-- 4) RAPPORT MANUEL D'ENTREPRISE : 5 DERNIERS JOURS DU MOIS SEULEMENT
-- ============================================================
create or replace function entreprise_deposer_impot(p_entreprise_id uuid, p_periode text, p_benefices numeric, p_depenses numeric, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare v_jours_restants int;
begin
  perform _exige_droit(p_entreprise_id, 'deposer_impot');
  v_jours_restants := (date_trunc('month', current_date) + interval '1 month' - interval '1 day')::date - current_date;
  if v_jours_restants > 4 then
    raise exception 'Le rapport manuel ne peut être déposé que dans les 5 derniers jours du mois.';
  end if;
  if exists (select 1 from entreprises_depots_impots where entreprise_id = p_entreprise_id and periode = p_periode) then
    raise exception 'Un rapport existe déjà pour cette période.';
  end if;
  insert into entreprises_depots_impots (entreprise_id, periode, benefices, depenses, note, depose_par, type)
    values (p_entreprise_id, p_periode, p_benefices, p_depenses, p_note, auth.uid(), 'manuel');
  delete from entreprises_logs where entreprise_id = p_entreprise_id;
end; $$;
grant execute on function entreprise_deposer_impot(uuid, text, numeric, numeric, text) to authenticated;

create or replace function entreprise_deposer_impot_assiste(p_entreprise_id uuid, p_periode text, p_benefices numeric, p_depenses numeric, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare v_jours_restants int;
begin
  perform _exige_droit(p_entreprise_id, 'deposer_impot');
  v_jours_restants := (date_trunc('month', current_date) + interval '1 month' - interval '1 day')::date - current_date;
  if v_jours_restants > 4 then
    raise exception 'Le rapport manuel (assisté) ne peut être déposé que dans les 5 derniers jours du mois.';
  end if;
  perform _entreprise_rapport_creer(p_entreprise_id, p_periode, 'assiste', p_benefices, p_depenses, p_note, auth.uid(), true);
end; $$;
grant execute on function entreprise_deposer_impot_assiste(uuid, text, numeric, numeric, text) to authenticated;


-- ============================================================
-- 5) MODE DE CRÉATION D'ENTREPRISE (liberté / vérification)
-- ============================================================
alter table parametres_fiscaux add column if not exists mode_creation_entreprise text not null default 'verification' check (mode_creation_entreprise in ('liberte','verification'));

create or replace function gouv_definir_mode_creation_entreprise(p_mode text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  if p_mode not in ('liberte','verification') then raise exception 'Mode invalide.'; end if;
  update parametres_fiscaux set mode_creation_entreprise = p_mode where id = 1;
end; $$;
grant execute on function gouv_definir_mode_creation_entreprise(text) to authenticated;

create or replace function mode_creation_entreprise_actuel()
returns text language sql stable security definer set search_path = public as $$
  select mode_creation_entreprise from parametres_fiscaux where id = 1;
$$;
grant execute on function mode_creation_entreprise_actuel() to authenticated, anon;

create or replace function entreprise_demander(
  p_nom text, p_depenses numeric, p_achats numeric,
  p_type_vente text, p_mode_vente text, p_boutique_principale text, p_boutiques_secondaires text,
  p_sieges text, p_fondateur_cas text, p_employes jsonb default '[]'::jsonb
) returns public.entreprises language plpgsql security definer set search_path = public as $$
declare v_row public.entreprises; v_emp jsonb; v_emp_id uuid; v_mode text; v_statut text;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if p_nom is null or char_length(trim(p_nom)) = 0 then raise exception 'Nom d''entreprise requis.'; end if;
  if p_sieges is null or char_length(trim(p_sieges)) = 0 then raise exception 'Au moins un siège physique est requis.'; end if;

  select mode_creation_entreprise into v_mode from parametres_fiscaux where id = 1;
  v_statut := case when v_mode = 'liberte' then 'acceptee' else 'en_attente' end;

  insert into entreprises (code, nom, depenses_an_dernier, achats_an_dernier, type_vente, mode_vente,
    boutique_principale, boutiques_secondaires, sieges, fondateur_id, fondateur_cas, statut)
  values ('E-' || _generer_code_alnum(8), p_nom, p_depenses, p_achats, p_type_vente, p_mode_vente,
    p_boutique_principale, p_boutiques_secondaires, p_sieges, auth.uid(), p_fondateur_cas, v_statut)
  returning * into v_row;
  perform _creer_cib_entreprise(v_row.id);

  if v_statut = 'acceptee' then
    insert into entreprises_membres (entreprise_id, citoyen_id, role) values (v_row.id, auth.uid(), 'pdg')
      on conflict (entreprise_id, citoyen_id) do update set role = 'pdg';
  end if;

  for v_emp in select * from jsonb_array_elements(coalesce(p_employes, '[]'::jsonb)) loop
    select id into v_emp_id from citoyens where code_social_encrypte = (v_emp->>'cas');
    if v_emp_id is not null then
      insert into entreprises_membres (entreprise_id, citoyen_id, role) values (v_row.id, v_emp_id, 'employe')
        on conflict do nothing;
    end if;
  end loop;
  return v_row;
end; $$;
grant execute on function entreprise_demander(text,numeric,numeric,text,text,text,text,text,text,jsonb) to authenticated;

-- ============================================================
-- FIN
-- ============================================================
