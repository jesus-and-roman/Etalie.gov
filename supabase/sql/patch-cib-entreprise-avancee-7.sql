-- ============================================================
-- patch-cib-entreprise-avancee-7.sql
-- À exécuter après patch-cib-entreprise-avancee-6.sql. Additif et rejouable.
--
-- REFONTE DU CAPITAL ("système Halgeberg") :
--  1. Bonus unique à l'achat direct depuis l'entreprise : au moment de la
--     mise en vente, on fige la trésorerie de l'entreprise
--     (tresorerie_mise_en_vente). Un acheteur direct reçoit alors, UNE
--     SEULE FOIS, pourcentage × cette trésorerie figée, ajouté à son
--     capital (pas à sa trésorerie personnelle).
--  2. Le partage des profits (déjà en place depuis le patch 2, trigger
--     _entreprise_repartir_capital) continue de s'appliquer à CHAQUE
--     entrée d'argent dans la trésorerie de l'entreprise, au prorata du
--     pourcentage détenu — inchangé, c'est déjà exactement ce qui était
--     redemandé ici.
--  3. Revente à un tiers (marché extérieur) : PAS de bonus Halgeberg (ce
--     n'est pas l'entreprise qui vend), mais le solde ACCUMULÉ du vendeur
--     est transféré à l'acheteur au PRORATA du pourcentage vendu par
--     rapport à ce que le vendeur détenait avant la vente. Le montant
--     "all-time" est transféré de la même façon (sert au calcul d'aide à
--     l'achat).
--  4. Une entreprise peut racheter SES PROPRES capitaux mis en vente par
--     un tiers (jamais ceux d'une autre entreprise) : le pourcentage
--     revient alors à l'entreprise (retiré des détenteurs tiers).
--  5. Graphique à 13 points et calculatrice d'aide à l'achat.
--
-- HYPOTHÈSE (limite honnête) : je n'ai pas de journal historique de la
-- trésorerie ou du capital mois par mois avant ce patch — seules les
-- dépenses/bénéfices des relevés mensuels existants sont réels pour les
-- 12 points passés. Les courbes trésorerie/capital de tiers ne sont
-- fiables qu'au 13e point (maintenant) ; les points passés pour ces deux
-- courbes sont marqués "non disponible" plutôt que d'inventer des
-- chiffres. Uniquement les dépenses et profits sont réels sur 12 mois.
-- ============================================================

alter table entreprises add column if not exists tresorerie_mise_en_vente numeric;
alter table entreprises_capital_detenteurs add column if not exists solde_all_time numeric not null default 0;

-- Snapshot de la trésorerie au moment de la mise en vente (nécessaire au bonus Halgeberg).
create or replace function entreprise_mettre_capital_en_vente(p_entreprise_id uuid, p_pourcentage numeric, p_max_par_individu numeric, p_prix_par_centieme numeric, p_min_achat_pct numeric default 0.01, p_description text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_deja_vendu numeric; v_tresor numeric;
begin
  perform _exige_droit(p_entreprise_id, 'vendre_capital');
  if p_pourcentage < 0 or p_pourcentage > 100 then raise exception 'Pourcentage invalide.'; end if;
  if p_description is not null and char_length(p_description) > 3000 then raise exception 'Description limitée à 3000 caractères.'; end if;
  select coalesce(sum(pourcentage), 0) into v_deja_vendu from entreprises_capital_detenteurs where entreprise_id = p_entreprise_id;
  if p_pourcentage + v_deja_vendu > 100 then raise exception 'Le total des capitaux vendus dépasserait 100 %%.'; end if;
  select tresorerie into v_tresor from entreprises where id = p_entreprise_id;
  update entreprises set capital_en_vente_pct = p_pourcentage, capital_max_par_individu = p_max_par_individu,
    capital_prix_par_centieme = p_prix_par_centieme, capital_min_achat_pct = coalesce(p_min_achat_pct, 0.01),
    capital_description = nullif(trim(coalesce(p_description, '')), ''),
    tresorerie_mise_en_vente = case when capital_en_vente_pct = 0 then v_tresor else tresorerie_mise_en_vente end
    where id = p_entreprise_id;
end; $$;
grant execute on function entreprise_mettre_capital_en_vente(uuid, numeric, numeric, numeric, numeric, text) to authenticated;

-- Achat direct : ajoute le bonus Halgeberg (une fois) au capital de l'acheteur.
create or replace function entreprise_acheter_capital(p_entreprise_id uuid, p_pourcentage numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_ent entreprises; v_cout numeric; v_deja numeric; v_tresor numeric; v_bonus numeric;
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
  v_bonus := round(p_pourcentage / 100.0 * coalesce(v_ent.tresorerie_mise_en_vente, 0), 2);

  update citoyens set tresorerie = tresorerie - v_cout where id = auth.uid();
  perform _sans_partage(true);
  update entreprises set tresorerie = tresorerie + v_cout, capital_en_vente_pct = capital_en_vente_pct - p_pourcentage where id = p_entreprise_id;
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
end; $$;
grant execute on function entreprise_acheter_capital(uuid, numeric) to authenticated;

-- Le trigger de partage des profits alimente aussi solde_all_time (jamais décrémenté).
create or replace function _entreprise_repartir_capital()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_delta numeric; v_tiers numeric; v_d record;
begin
  if coalesce(current_setting('app.sans_partage_capital', true), '0') = '1' then return new; end if;
  v_delta := new.tresorerie - old.tresorerie;
  select coalesce(sum(pourcentage), 0) into v_tiers from entreprises_capital_detenteurs where entreprise_id = new.id;
  if v_tiers <= 0 then return new; end if;
  for v_d in select id, pourcentage, est_gouvernement from entreprises_capital_detenteurs where entreprise_id = new.id loop
    if v_d.est_gouvernement then
      update tresor_public set solde = solde + v_delta * v_d.pourcentage / 100.0 where id = 1;
    else
      update entreprises_capital_detenteurs set
        solde = solde + v_delta * v_d.pourcentage / 100.0,
        solde_all_time = solde_all_time + greatest(v_delta, 0) * v_d.pourcentage / 100.0
        where id = v_d.id;
    end if;
  end loop;
  new.tresorerie := old.tresorerie + v_delta * (1 - v_tiers / 100.0);
  return new;
end; $$;

-- Revente à un tiers : transfère le pourcentage ET une part proportionnelle du solde/all-time du vendeur.
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
end; $$;
grant execute on function capital_acheter_tiers(uuid, numeric) to authenticated;

-- L'entreprise rachète UN DE SES PROPRES capitaux mis en vente par un tiers.
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
  -- Le pourcentage racheté n'est PAS réattribué à un détenteur : il revient implicitement à l'entreprise
  -- (la part de l'entreprise = 100 % − somme des détenteurs tiers, y compris le gouvernement).

  if p_pourcentage >= o.pourcentage then delete from capital_offres_tiers where id = o.id;
  else update capital_offres_tiers set pourcentage = pourcentage - p_pourcentage where id = o.id; end if;
  perform _entreprise_log(p_entreprise_id, 'vente_capital',
    jsonb_build_object('acheteur_username', 'entreprise (rachat)', 'pourcentage', p_pourcentage, 'cout', v_cout, 'montant', v_cout));
end; $$;
grant execute on function entreprise_racheter_capital(uuid, uuid, numeric) to authenticated;

-- Calculatrice d'aide à l'achat : estimation Halgeberg + estimation de revenu récurrent.
create or replace function entreprise_estimation_achat(p_entreprise_id uuid, p_pourcentage numeric)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_ent entreprises; v_moyenne_all_time numeric; v_nb int; v_bonus numeric; v_estime_halgeberg numeric;
begin
  select * into v_ent from entreprises where id = p_entreprise_id;
  if v_ent.id is null then raise exception 'Entreprise introuvable.'; end if;
  v_bonus := round(p_pourcentage / 100.0 * coalesce(v_ent.tresorerie_mise_en_vente, v_ent.tresorerie), 2);

  select avg(solde_all_time), count(*) into v_moyenne_all_time, v_nb from entreprises_capital_detenteurs where entreprise_id = p_entreprise_id and not est_gouvernement;
  v_estime_halgeberg := round(coalesce(v_moyenne_all_time, 0) * p_pourcentage, 2);

  return jsonb_build_object(
    'bonus_halgeberg_unique', v_bonus,
    'estimation_capital_accumule', v_estime_halgeberg,
    'nb_investisseurs_references', coalesce(v_nb, 0),
    'moyenne_all_time_par_pourcent', round(coalesce(v_moyenne_all_time, 0), 2),
    'detail', format('Bonus unique : %s %% × %s R$ (trésorerie à la mise en vente) = %s R$. Estimation d''accumulation : moyenne all-time des détenteurs (%s R$/%%) × %s %% = %s R$.',
      p_pourcentage, coalesce(v_ent.tresorerie_mise_en_vente, v_ent.tresorerie), v_bonus, round(coalesce(v_moyenne_all_time, 0), 2), p_pourcentage, v_estime_halgeberg)
  );
end; $$;
grant execute on function entreprise_estimation_achat(uuid, numeric) to authenticated, anon;

-- 13 points : 12 relevés mensuels (dépenses/profits réels) + le point "actuel" (temps réel).
create or replace function entreprise_graphique_capital(p_entreprise_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'historique', coalesce((select jsonb_agg(jsonb_build_object(
        'periode', periode, 'depenses', depenses, 'profits', benefices, 'tresorerie', null, 'capital_tiers_all_time', null, 'capital_tiers_actuel', null
      ) order by periode) from (
        select periode, depenses, benefices from entreprises_depots_impots where entreprise_id = p_entreprise_id order by periode desc limit 12
      ) x), '[]'::jsonb),
    'actuel', (select jsonb_build_object(
      'periode', 'actuel', 'depenses', (select coalesce(sum((donnees->>'montant')::numeric), 0) from entreprises_logs
          where entreprise_id = p_entreprise_id and type in ('depense','paiement_employe','virement_tiers','virement_entreprise')
          and cree_le >= date_trunc('month', now())),
      'profits', null, 'tresorerie', tresorerie,
      'capital_tiers_all_time', (select coalesce(sum(solde_all_time), 0) from entreprises_capital_detenteurs where entreprise_id = p_entreprise_id and not est_gouvernement),
      'capital_tiers_actuel', (select coalesce(sum(solde), 0) from entreprises_capital_detenteurs where entreprise_id = p_entreprise_id and not est_gouvernement)
    ) from entreprises where id = p_entreprise_id)
  );
$$;
grant execute on function entreprise_graphique_capital(uuid) to authenticated, anon;

-- Marché intérieur : mes capitaux + évolution des 12 derniers mois de chacun (dépenses/profits de l'entreprise).
create or replace function mes_capitaux()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'entreprise_id', e.id, 'nom', e.nom, 'pourcentage', d.pourcentage, 'solde', d.solde, 'solde_all_time', d.solde_all_time,
    'valeur_tresorerie', round(e.tresorerie * d.pourcentage / 100.0, 2),
    'en_vente_pct', coalesce((select sum(o.pourcentage) from capital_offres_tiers o where o.entreprise_id = e.id and o.vendeur_id = auth.uid()), 0)
  ) order by e.nom), '[]'::jsonb)
  from entreprises_capital_detenteurs d join entreprises e on e.id = d.entreprise_id
  where d.citoyen_id = auth.uid();
$$;
grant execute on function mes_capitaux() to authenticated;

-- Détails complets d'une entreprise pour la fiche du marché extérieur (aide à l'achat).
create or replace function entreprise_fiche_capital(p_entreprise_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'nom', e.nom, 'code', e.code, 'sieges', e.sieges, 'type_vente', e.type_vente, 'mode_vente', e.mode_vente,
    'tresorerie', e.tresorerie, 'description', e.capital_description,
    'pdg', (select c.username from entreprises_membres m join citoyens c on c.id = m.citoyen_id where m.entreprise_id = e.id and m.role = 'pdg' limit 1),
    'co_pdg', coalesce((select jsonb_agg(c.username) from entreprises_membres m join citoyens c on c.id = m.citoyen_id where m.entreprise_id = e.id and m.role = 'co_pdg'), '[]'::jsonb),
    'employes', coalesce((select jsonb_agg(c.username) from entreprises_membres m join citoyens c on c.id = m.citoyen_id where m.entreprise_id = e.id and m.role = 'employe'), '[]'::jsonb),
    'capital', entreprise_capital_public(e.id), 'graphique', entreprise_graphique_capital(e.id),
    'dernier_relevé_periode', (select periode from entreprises_depots_impots where entreprise_id = e.id order by periode desc limit 1)
  )
  from entreprises e where e.id = p_entreprise_id;
$$;
grant execute on function entreprise_fiche_capital(uuid) to authenticated, anon;

-- ============================================================
-- FIN
-- ============================================================
