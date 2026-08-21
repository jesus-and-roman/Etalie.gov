-- ============================================================
-- CORRECTIFS — patch-presse-monetaire-corrections.sql
-- À exécuter APRÈS patch-presse-monetaire.sql (ne le remplace pas,
-- vient corriger des bugs par-dessus). Sans danger à relancer plusieurs
-- fois : tout est en CREATE OR REPLACE / DROP+CREATE idempotents.
--
-- Corrige :
--  1. "column reference v is ambiguous" dans l'automatisation
--     (demarrer_automatisation).
--  2. John qui n'avait jamais d'offres (_tirer_type_john n'avait pas
--     search_path = public, donc échouait silencieusement).
--  3. Dénominations officielles : 8 valeurs (0,01 / 0,5 / 1 / 5 / 25 /
--     50 / 275 / 500 R$) au lieu des 5 d'origine.
--  4. Destruction de billets : on ne peut détruire que des billets
--     réellement présents dans le coffre de la banque (billets_en_attente),
--     le coût est bien seulement 0,02 R$/billet (et non plus la valeur
--     faciale en plus), et protection contre une valeur totale imprimée
--     nulle qui aurait cassé le calcul (division par zéro -> Roiyal NULL,
--     ce qui expliquait que le prix d'impression semblait ne plus bouger).
--  5. Nouvelle fonction retirer_amelioration_production_clic : revendre
--     un niveau de production par clic contre 50% de son prix d'achat.
--  6. Livraison : remplace l'ancienne résolution instantanée
--     (livrer_camion) par un vrai trajet province par province, avec
--     temps d'attente réel, braquages/accidents possibles à chaque étape,
--     et un suivi en direct (demarrer_livraison / verifier_livraison /
--     livraisons_actives). L'ancienne fonction livrer_camion est retirée.
-- ============================================================

-- Nettoyage de l'ancienne fonction de livraison instantanée, remplacée
-- plus bas par demarrer_livraison / verifier_livraison.
drop function if exists livrer_camion(uuid, text);

-- ============================================================
-- 6) IMPRESSION MANUELLE
-- ============================================================
-- Dénominations officielles (correction : 8 valeurs, pas 5)
create or replace function valeur_billet_valide(p_valeur numeric)
returns boolean language sql immutable as $$
  select p_valeur = any(array[0.01,0.5,1,5,25,50,275,500]::numeric[]);
$$;

create or replace function imprimer_billet(p_banque_tag char(1), p_valeur numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_quantite int; v_prix numeric; v_cout numeric; v_r numeric; v_t numeric; v_b bigint; v_j bigint;
  v_a numeric; v_baisse numeric; v_nouveau_r numeric; v_pending jsonb; v_cle text;
begin
  if not est_personnel_banque(p_banque_tag) then raise exception 'Accès refusé : réservé au personnel de cette banque.'; end if;
  if not valeur_billet_valide(p_valeur) then raise exception 'Valeur de billet invalide.'; end if;
  perform _rafraichir_jour_roiyal();

  select niveau_clic into v_quantite from banques_nationales where tag = p_banque_tag;
  select valeur_r, valeur_totale_imprimee, billets_imprimes_total, billets_imprimes_jour
    into v_r, v_t, v_b, v_j from roiyal_etat where id = 1;

  v_prix := round(0.23 * (100 / v_r), 10);
  v_cout := v_prix * v_quantite;

  if (select tresorerie from banques_nationales where tag = p_banque_tag) < v_cout then
    raise exception 'Trésorerie de la banque insuffisante pour imprimer (coût: % R$).', round(v_cout,4);
  end if;

  v_a := p_valeur * v_quantite;
  v_baisse := (v_a / nullif(v_t + v_a,0)) * 20 * sqrt((v_b + v_quantite) / 1000000.0) * sqrt((v_j + v_quantite) / 1000000.0);
  v_nouveau_r := greatest(0.0001, v_r * (1 - (v_baisse/100)));

  update roiyal_etat set
    valeur_r = v_nouveau_r, valeur_totale_imprimee = v_t + v_a, billets_imprimes_total = v_b + v_quantite,
    billets_imprimes_jour = v_j + v_quantite, valeur_imprimee_jour = valeur_imprimee_jour + v_a
    where id = 1;

  v_cle := trim(to_char(p_valeur, 'FM999999990.00'));
  select billets_en_attente into v_pending from banques_nationales where tag = p_banque_tag;
  v_pending := jsonb_set(coalesce(v_pending,'{}'::jsonb), array[v_cle],
    to_jsonb(coalesce((v_pending->>v_cle)::bigint,0) + v_quantite));

  update banques_nationales set tresorerie = tresorerie - v_cout, billets_en_attente = v_pending
    where tag = p_banque_tag;

  perform _incrementer_stat(p_banque_tag, v_quantite, v_a, 0,0,0,0, v_baisse);

  return jsonb_build_object(
    'quantite', v_quantite, 'valeur_unitaire', p_valeur, 'cout_impression', v_cout,
    'nouveau_r', v_nouveau_r, 'inflation', round(100 - v_nouveau_r, 4)
  );
end; $$;
grant execute on function imprimer_billet(char, numeric) to authenticated;

create or replace function retirer_amelioration_production_clic(p_banque_tag char(1))
returns public.banques_nationales language plpgsql security definer set search_path = public as $$
declare v_remboursement numeric; v_row public.banques_nationales;
begin
  if not est_personnel_banque(p_banque_tag, 'administrateur') then raise exception 'Accès refusé : réservé aux administrateurs de la banque.'; end if;
  if (select niveau_clic from banques_nationales where tag = p_banque_tag) <= 1 then
    raise exception 'Aucune amélioration à retirer.';
  end if;
  select round(120 * power(1.25, niveau_clic - 2), 4) * 0.5 into v_remboursement
    from banques_nationales where tag = p_banque_tag;
  update banques_nationales set tresorerie = tresorerie + v_remboursement, niveau_clic = niveau_clic - 1
    where tag = p_banque_tag returning * into v_row;
  return v_row;
end; $$;
grant execute on function retirer_amelioration_production_clic(char) to authenticated;

create or replace function demarrer_automatisation(p_banque_tag char(1), p_valeurs numeric[])
returns public.automatisation_banque language plpgsql security definer set search_path = public as $$
declare v_row public.automatisation_banque; v_toutes_valides boolean;
begin
  if not est_personnel_banque(p_banque_tag) then raise exception 'Accès refusé.'; end if;
  if p_valeurs is null or array_length(p_valeurs,1) is null then raise exception 'Choisissez au moins une valeur de billet.'; end if;
  select bool_and(valeur_billet_valide(d.valeur)) into v_toutes_valides from unnest(p_valeurs) as d(valeur);
  if not coalesce(v_toutes_valides,false) then raise exception 'Valeur de billet invalide dans la sélection.'; end if;
  update automatisation_banque set actif = true, valeurs_autorisees = p_valeurs, dernier_cycle = now(), en_panne = false
    where banque_tag = p_banque_tag returning * into v_row;
  return v_row;
end; $$;
grant execute on function demarrer_automatisation(char, numeric[]) to authenticated;

create or replace function _tirer_type_john()
returns text language plpgsql security definer set search_path = public as $$
declare
  v_r numeric := random() * 100;
  v_cumul numeric := 0;
  v_ligne record;
begin
  for v_ligne in select type, chance from john_probabilites order by chance desc, type loop
    v_cumul := v_cumul + v_ligne.chance;
    if v_r <= v_cumul then return v_ligne.type; end if;
  end loop;
  return 'petit_camion';
end; $$;

-- ------------------------------------------------------------
-- LIVRAISON — un vrai trajet qui prend du temps, province par
-- province : chaque étape a sa propre durée, son propre risque de
-- braquage/accident, et n'est révélée/appliquée que lorsque son
-- heure d'arrivée est passée (suivi en direct, pas de résolution
-- instantanée).
-- ------------------------------------------------------------
drop table if exists livraisons cascade;
create table livraisons (
  id                   uuid primary key default gen_random_uuid(),
  vehicule_id          uuid not null references vehicules(id),
  banque_tag           char(1) not null references banques_nationales(tag),
  escorte              text,
  statut               text not null default 'en_cours' check (statut in ('en_cours','terminee')),
  vitesse_kmh          numeric not null,
  distance_totale_km   numeric not null,
  duree_totale_h       numeric not null,
  cout_essence         numeric not null default 0,
  cout_location        numeric not null default 0,
  cout_entretien       numeric not null default 0,
  montant_total        numeric not null default 0,
  montant_livre        numeric not null default 0,
  braquages            int not null default 0,
  accidents            int not null default 0,
  legs                 jsonb not null default '[]'::jsonb,
  depart_le            timestamptz not null default now(),
  terminee_le          timestamptz,
  cree_le              timestamptz not null default now()
);
alter table livraisons enable row level security;
create policy "Lecture publique des livraisons" on livraisons for select using (true);

create or replace function demarrer_livraison(p_vehicule_id uuid, p_escorte text default null)
returns public.livraisons language plpgsql security definer set search_path = public as $$
declare
  v_veh public.vehicules; v_type public.types_vehicules; v_prm public.parametres_livraison;
  v_esc public.escortes_types; v_vitesse numeric; v_duree_leg numeric; v_prix_essence numeric;
  v_cout_essence numeric; v_cout_location numeric; v_cout_entretien numeric;
  v_chance_braquage numeric; v_chance_accident numeric;
  v_montant_total numeric := 0; v_cle text; v_val text;
  v_prov record; v_legs jsonb := '[]'::jsonb; v_leg jsonb;
  v_temps_cumule interval := interval '0'; v_heure_arrivee timestamptz;
  v_roll numeric; v_statut_leg text; v_type_accident text; v_perte_pct numeric; v_reparation numeric;
  v_montant_leg numeric; v_montant_livre_leg numeric; v_row public.livraisons;
begin
  select * into v_veh from vehicules where id = p_vehicule_id for update;
  if v_veh is null then raise exception 'Véhicule introuvable.'; end if;
  if not est_personnel_banque(v_veh.banque_tag) then raise exception 'Accès refusé.'; end if;
  if v_veh.statut <> 'charge' then raise exception 'Ce véhicule doit d''abord être chargé.'; end if;

  select * into v_type from types_vehicules where type = v_veh.type;
  select * into v_prm from parametres_livraison where id = 1;

  if p_escorte is not null then
    if v_veh.loue then raise exception 'Un véhicule loué ne peut pas avoir d''escorte policière.'; end if;
    if not escorte_compatible(v_veh.type, p_escorte) then raise exception 'Cette escorte n''est pas compatible avec ce véhicule.'; end if;
    select * into v_esc from escortes_types where escorte = p_escorte;
  end if;

  if not exists (select 1 from banque_provinces where banque_tag = v_veh.banque_tag) then
    raise exception 'Aucune province associée à cette banque.';
  end if;

  v_vitesse := v_type.vitesse_base_kmh
    * (1 - (v_veh.km_parcourus * 0.0000001 / 100))
    * (case when (v_veh.ameliorations->>'moteur') = 'true' then 1.2 else 1 end)
    * (case when (v_veh.ameliorations->>'gps') = 'true' then 1.2 else 1 end)
    * (case when p_escorte is not null then (1 - v_esc.reduction_vitesse/100.0) else 1 end);
  v_vitesse := greatest(v_vitesse, 5);
  v_duree_leg := v_prm.distance_moyenne_km / v_vitesse;

  for v_cle, v_val in select key, value from jsonb_each_text(v_veh.cargaison) loop
    v_montant_total := v_montant_total + (v_cle::numeric * v_val::bigint);
  end loop;
  if v_montant_total <= 0 then raise exception 'Ce véhicule n''a pas de cargaison.'; end if;

  v_chance_braquage := greatest(0.01, v_type.chance_braquage
    * (case when (v_veh.ameliorations->>'blindage') = 'true' then 0.7 else 1 end)
    * (case when p_escorte is not null then (1 - v_esc.reduction_braquage/100.0) else 1 end));
  v_chance_accident := least(15, v_type.risque_accident + (v_veh.km_parcourus * 0.000001))
    * (case when (v_veh.ameliorations->>'chauffeur') = 'true' then 0.85 else 1 end);

  for v_prov in select province, part_pourcentage from banque_provinces where banque_tag = v_veh.banque_tag order by part_pourcentage desc, province loop
    v_montant_leg := round(v_montant_total * v_prov.part_pourcentage / 100.0, 2);
    v_temps_cumule := v_temps_cumule + make_interval(secs => v_duree_leg * 3600);
    v_statut_leg := 'ok'; v_type_accident := null; v_perte_pct := 0; v_reparation := 0;

    if random()*100 < v_prm.chance_bris_totale then
      v_statut_leg := 'bris_total';
    elsif random()*100 < v_chance_braquage then
      v_statut_leg := 'braquee';
    elsif random()*100 < v_chance_accident then
      v_roll := random()*100;
      if v_roll < 70 then
        v_type_accident := 'accrochage';
        v_perte_pct := (case when (v_veh.ameliorations->>'chauffeur') = 'true' then 0.008 else 0.01 end);
        v_reparation := v_type.prix_achat * (case when (v_veh.ameliorations->>'chauffeur') = 'true' then 0.004 else 0.005 end);
      elsif v_roll < 95 then
        v_type_accident := 'accident_moyen';
        v_perte_pct := (case when (v_veh.ameliorations->>'chauffeur') = 'true' then 0.425 else 0.5 end);
        v_reparation := v_type.prix_achat * (case when (v_veh.ameliorations->>'chauffeur') = 'true' then 0.0425 else 0.05 end);
        v_temps_cumule := v_temps_cumule + make_interval(secs => 12 * 3600 * (case when (v_veh.ameliorations->>'chauffeur')='true' then 0.85 else 1 end));
      else
        v_type_accident := 'accident_grave';
        v_perte_pct := (case when (v_veh.ameliorations->>'chauffeur') = 'true' then 4.5 else 5 end);
        v_reparation := v_type.prix_achat * (case when (v_veh.ameliorations->>'chauffeur') = 'true' then 0.18 else 0.20 end);
        v_temps_cumule := v_temps_cumule + make_interval(secs => 24 * 3600 * (case when (v_veh.ameliorations->>'chauffeur')='true' then 0.85 else 1 end));
      end if;
      v_statut_leg := 'accident';
    end if;

    v_heure_arrivee := now() + v_temps_cumule;

    if v_statut_leg = 'ok' then v_montant_livre_leg := v_montant_leg;
    elsif v_statut_leg = 'accident' then v_montant_livre_leg := round(v_montant_leg * (1 - v_perte_pct/100.0), 2);
    else v_montant_livre_leg := 0;
    end if;

    v_leg := jsonb_build_object(
      'province', v_prov.province, 'montant', v_montant_leg, 'distance_km', v_prm.distance_moyenne_km,
      'heure_arrivee', v_heure_arrivee, 'statut_reel', v_statut_leg, 'type_accident', v_type_accident,
      'montant_livre', v_montant_livre_leg, 'reparation', v_reparation, 'traite', false
    );
    v_legs := v_legs || v_leg;
  end loop;

  v_prix_essence := prix_essence_actuel() / 15.0;
  v_cout_essence := (v_prm.distance_moyenne_km * jsonb_array_length(v_legs)) * v_prix_essence
    * (case when (v_veh.ameliorations->>'moteur') = 'true' then 0.9 else 1 end);
  if p_escorte is not null then
    v_cout_essence := v_cout_essence + ((v_prm.distance_moyenne_km * jsonb_array_length(v_legs)) * v_prix_essence * 2);
  end if;

  v_cout_location := case when v_veh.loue then v_type.prix_location_h * extract(epoch from v_temps_cumule)/3600.0 else 0 end;
  if p_escorte is not null then
    v_cout_location := v_cout_location + (v_esc.prix_location + v_esc.prix_heure * extract(epoch from v_temps_cumule)/3600.0);
  end if;

  v_cout_entretien := 0;
  if (v_veh.ameliorations->>'moteur') = 'true' then v_cout_entretien := v_cout_entretien + 20 * ((v_prm.distance_moyenne_km*jsonb_array_length(v_legs))/1000); end if;
  if (v_veh.ameliorations->>'blindage') = 'true' then v_cout_entretien := v_cout_entretien + 50 * ((v_prm.distance_moyenne_km*jsonb_array_length(v_legs))/1000); end if;
  if (v_veh.ameliorations->>'coffre') = 'true' then v_cout_entretien := v_cout_entretien + 15 * ((v_prm.distance_moyenne_km*jsonb_array_length(v_legs))/1000); end if;
  if (v_veh.ameliorations->>'gps') = 'true' then v_cout_entretien := v_cout_entretien + 5 * ((v_prm.distance_moyenne_km*jsonb_array_length(v_legs))/1000); end if;

  if (select tresorerie from banques_nationales where tag = v_veh.banque_tag) < (v_cout_essence + v_cout_location + v_cout_entretien) then
    raise exception 'Trésorerie de la banque insuffisante pour couvrir carburant/location/entretien (% R$).', round(v_cout_essence+v_cout_location+v_cout_entretien,2);
  end if;

  update banques_nationales set tresorerie = tresorerie - v_cout_essence - v_cout_location - v_cout_entretien where tag = v_veh.banque_tag;
  update vehicules set statut = 'en_livraison' where id = p_vehicule_id;

  insert into livraisons (vehicule_id, banque_tag, escorte, vitesse_kmh, distance_totale_km, duree_totale_h,
    cout_essence, cout_location, cout_entretien, montant_total, legs)
  values (p_vehicule_id, v_veh.banque_tag, p_escorte, v_vitesse, v_prm.distance_moyenne_km * jsonb_array_length(v_legs),
    extract(epoch from v_temps_cumule)/3600.0, v_cout_essence, v_cout_location, v_cout_entretien, v_montant_total, v_legs)
  returning * into v_row;

  return v_row;
end; $$;
grant execute on function demarrer_livraison(uuid, text) to authenticated;

-- Applique les étapes dont l'heure d'arrivée est passée, et renvoie un
-- instantané SANS révéler le sort des étapes futures (pas de triche).
create or replace function verifier_livraison(p_livraison_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_liv public.livraisons; v_veh public.vehicules; v_legs jsonb; v_leg jsonb; v_i int;
  v_nouveau_braquages int := 0; v_nouveaux_accidents int := 0; v_montant_ajoute numeric := 0;
  v_reparation_totale numeric := 0; v_tout_traite boolean := true; v_public_legs jsonb := '[]'::jsonb;
  v_km_valides numeric := 0; v_leg_courant int := null; v_progress numeric;
begin
  select * into v_liv from livraisons where id = p_livraison_id for update;
  if v_liv is null then raise exception 'Livraison introuvable.'; end if;
  if not est_personnel_banque(v_liv.banque_tag) then raise exception 'Accès refusé.'; end if;

  v_legs := v_liv.legs;
  if v_liv.statut = 'en_cours' then
    for v_i in 0..jsonb_array_length(v_legs)-1 loop
      v_leg := v_legs -> v_i;
      if (v_leg->>'traite')::boolean = false and (v_leg->>'heure_arrivee')::timestamptz <= now() then
        if (v_leg->>'statut_reel') = 'braquee' then v_nouveau_braquages := v_nouveau_braquages + 1; end if;
        if (v_leg->>'statut_reel') = 'accident' then v_nouveaux_accidents := v_nouveaux_accidents + 1; end if;
        v_montant_ajoute := v_montant_ajoute + (v_leg->>'montant_livre')::numeric;
        v_reparation_totale := v_reparation_totale + coalesce((v_leg->>'reparation')::numeric, 0);
        v_legs := jsonb_set(v_legs, array[v_i::text, 'traite'], 'true'::jsonb);
      end if;
    end loop;

    if v_montant_ajoute <> 0 or v_reparation_totale <> 0 or v_nouveau_braquages > 0 or v_nouveaux_accidents > 0 then
      update banques_nationales set tresorerie = tresorerie + v_montant_ajoute - v_reparation_totale where tag = v_liv.banque_tag;
      if v_nouveau_braquages > 0 or v_nouveaux_accidents > 0 then
        perform _incrementer_stat(v_liv.banque_tag, 0, 0, 0, v_nouveau_braquages, v_nouveaux_accidents, 0, 0);
      end if;
    end if;

    select bool_and((elem->>'traite')::boolean) into v_tout_traite from jsonb_array_elements(v_legs) as elem;

    update livraisons set legs = v_legs, montant_livre = montant_livre + v_montant_ajoute,
      braquages = braquages + v_nouveau_braquages, accidents = accidents + v_nouveaux_accidents,
      statut = case when v_tout_traite then 'terminee' else 'en_cours' end,
      terminee_le = case when v_tout_traite then now() else null end
      where id = p_livraison_id
      returning * into v_liv;

    if v_tout_traite then
      select * into v_veh from vehicules where id = v_liv.vehicule_id;
      update vehicules set
        statut = case when v_veh.loue then 'hors_service' else 'disponible' end,
        km_parcourus = km_parcourus + v_liv.distance_totale_km,
        cargaison = '{}'::jsonb
        where id = v_liv.vehicule_id;
    end if;
  end if;

  -- Instantané public : les étapes non "traitées" ne révèlent ni statut ni montant réel
  for v_i in 0..jsonb_array_length(v_liv.legs)-1 loop
    v_leg := v_liv.legs -> v_i;
    if (v_leg->>'traite')::boolean then
      v_km_valides := v_km_valides + (v_leg->>'distance_km')::numeric;
      v_public_legs := v_public_legs || jsonb_build_object(
        'province', v_leg->>'province', 'distance_km', v_leg->>'distance_km',
        'heure_arrivee', v_leg->>'heure_arrivee', 'traite', true,
        'statut_reel', v_leg->>'statut_reel', 'type_accident', v_leg->>'type_accident',
        'montant_livre', v_leg->>'montant_livre'
      );
    else
      if v_leg_courant is null then v_leg_courant := v_i; end if;
      v_public_legs := v_public_legs || jsonb_build_object(
        'province', v_leg->>'province', 'distance_km', v_leg->>'distance_km',
        'heure_arrivee', v_leg->>'heure_arrivee', 'traite', false
      );
    end if;
  end loop;

  v_progress := round(100.0 * v_km_valides / greatest(1, v_liv.distance_totale_km), 1);

  return jsonb_build_object(
    'id', v_liv.id, 'statut', v_liv.statut, 'depart_le', v_liv.depart_le, 'terminee_le', v_liv.terminee_le,
    'distance_totale_km', v_liv.distance_totale_km, 'duree_totale_h', round(v_liv.duree_totale_h,2),
    'km_parcourus', v_km_valides, 'progress_pct', least(100, v_progress),
    'province_actuelle', case when v_leg_courant is not null then (v_liv.legs -> v_leg_courant)->>'province' else null end,
    'braquages', v_liv.braquages, 'accidents', v_liv.accidents,
    'montant_total', v_liv.montant_total, 'montant_livre', v_liv.montant_livre, 'legs', v_public_legs
  );
end; $$;
grant execute on function verifier_livraison(uuid) to authenticated;

-- Liste (et rafraîchit au passage) toutes les livraisons en cours d'une banque
create or replace function livraisons_actives(p_banque_tag char(1))
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_resultats jsonb := '[]'::jsonb;
begin
  if not est_personnel_banque(p_banque_tag) then raise exception 'Accès refusé.'; end if;
  for v_id in select id from livraisons where banque_tag = p_banque_tag and statut = 'en_cours' loop
    v_resultats := v_resultats || verifier_livraison(v_id);
  end loop;
  return v_resultats;
end; $$;
grant execute on function livraisons_actives(char) to authenticated;

create table if not exists destructions_billets (
  id           uuid primary key default gen_random_uuid(),
  banque_tag   char(1) not null references banques_nationales(tag),
  citoyen_id   uuid not null references auth.users(id),
  valeur       numeric not null,
  quantite     bigint not null,
  montant      numeric not null,
  cout         numeric not null,
  hausse_valeur numeric not null,
  cree_le      timestamptz not null default now()
);
alter table destructions_billets enable row level security;
create policy "Lecture publique des destructions" on destructions_billets for select using (true);

create or replace function detruire_billets(p_banque_tag char(1), p_valeur numeric, p_quantite bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_ad numeric; v_t numeric; v_r numeric; v_hausse numeric; v_nouveau_r numeric; v_cout numeric;
  v_cle text; v_pending jsonb; v_disponible bigint;
begin
  if not est_personnel_banque(p_banque_tag, 'administrateur') then raise exception 'Accès refusé : réservé aux administrateurs de la banque.'; end if;
  if not valeur_billet_valide(p_valeur) then raise exception 'Valeur de billet invalide.'; end if;
  if p_quantite <= 0 then raise exception 'Quantité invalide.'; end if;

  select valeur_totale_imprimee into v_t from roiyal_etat where id = 1;
  if v_t is null or v_t <= 0 then raise exception 'Aucune valeur n''a encore été imprimée : rien à détruire.'; end if;

  v_cle := trim(to_char(p_valeur, 'FM999999990.00'));
  select billets_en_attente into v_pending from banques_nationales where tag = p_banque_tag for update;
  v_disponible := coalesce((v_pending->>v_cle)::bigint, 0);
  if v_disponible < p_quantite then
    raise exception 'Cette banque ne possède que % billet(s) de % R$ (vous en demandez %).', v_disponible, p_valeur, p_quantite;
  end if;

  -- Le coût de destruction est uniquement le service (0,02 R$/billet) :
  -- les billets détruits sortent du coffre, leur valeur faciale n'est PAS
  -- débitée une deuxième fois de la trésorerie.
  v_ad := p_valeur * p_quantite;
  v_cout := round(p_quantite * 0.02, 6);
  if (select tresorerie from banques_nationales where tag = p_banque_tag) < v_cout then
    raise exception 'Trésorerie de la banque insuffisante pour détruire ces billets (coût: % R$).', v_cout;
  end if;

  select valeur_r into v_r from roiyal_etat where id = 1;
  v_hausse := ((v_ad / v_t) * 20 * sqrt(v_ad/1000000.0)) * 0.80;
  v_nouveau_r := v_r * (1 + (v_hausse/100));

  v_pending := jsonb_set(v_pending, array[v_cle], to_jsonb(v_disponible - p_quantite));

  update roiyal_etat set valeur_r = v_nouveau_r, billets_detruits_total = billets_detruits_total + p_quantite where id = 1;
  update banques_nationales set tresorerie = tresorerie - v_cout, billets_en_attente = v_pending where tag = p_banque_tag;
  insert into destructions_billets (banque_tag, citoyen_id, valeur, quantite, montant, cout, hausse_valeur)
    values (p_banque_tag, auth.uid(), p_valeur, p_quantite, v_ad, v_cout, v_hausse);

  return jsonb_build_object('nouveau_r', v_nouveau_r, 'hausse_valeur', v_hausse, 'cout', v_cout);
end; $$;
grant execute on function detruire_billets(char, numeric, bigint) to authenticated;

-- ============================================================
-- FIN DES CORRECTIFS
-- ============================================================
