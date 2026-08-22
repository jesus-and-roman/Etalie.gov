-- ============================================================
-- CORRECTIFS 2 — patch-presse-monetaire-corrections-2.sql
-- À exécuter APRÈS patch-presse-monetaire.sql ET
-- patch-presse-monetaire-corrections.sql. Idempotent (relançable).
--
-- Contenu :
--  1. Bug "function round(double precision, integer) does not exist"
--     dans les offres de John (prix_heure).
--  2. Rafraîchissement immédiat de la trésorerie/coffre après tout
--     achat/amélioration/location (plus besoin d'actualiser) — voir
--     aussi les changements côté portail-citoyen.html.
--  3. Automatisation : quantité de billets par cycle réellement
--     configurable (plus seulement liée à la production par clic
--     manuel), et petites solidifications du calcul des cycles.
--  4. Nouveau système de 4 rôles pour le personnel de banque :
--       niveau 1 = Travailleur de banque (presse à billets seulement)
--       niveau 2 = Manager (+ automatisation, flotte, livraisons)
--       niveau 3 = Dirigeant de la banque (tout, SAUF détruire un billet)
--       @gouvernement (est_admin) = seul habilité à détruire des billets
--       et à assigner les rôles avec le nom d'utilisateur.
--  5. Numéro de suivi unique par VÉHICULE (pas par amélioration),
--     affiché dans la flotte et dans le suivi de livraison en cours.
--  6. PIB national + variation % par rapport à l'ancien PIB (rouge si
--     en baisse, vert si en hausse, gris entre -0,05% et 0,05%),
--     exposé via tableau_de_bord_national(), visible par tous les
--     citoyens dans le nouvel onglet « Tableau de bord ».
--     Simplification assumée : le PIB additionne le trésor public
--     (table tresor_public existante), la trésorerie/dettes/prêts/
--     comptes chômage-retraite-parentalité de chaque citoyen, et la
--     trésorerie de chaque banque nationale. (« Argent attendu » et
--     la scission trésor public/privé du gouvernement ne sont pas
--     encore implémentés dans le site — hors périmètre de cette
--     demande.)
-- ============================================================


-- ============================================================
-- 1) OFFRES DE JOHN — correction du bug round(double precision, integer)
-- ============================================================
create or replace function obtenir_offres_john(p_banque_tag char(1))
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_row public.offres_john; v_offres jsonb := '[]'::jsonb; v_type text; v_t public.types_vehicules; v_i int;
begin
  select * into v_row from offres_john where banque_tag = p_banque_tag;
  if v_row is not null and v_row.genere_le > now() - interval '396 hours' then
    return v_row.offres;
  end if;
  for v_i in 1..3 loop
    v_type := _tirer_type_john();
    select * into v_t from types_vehicules where type = v_type;
    v_offres := v_offres || jsonb_build_object(
      'type', v_type,
      'prix_heure', round((v_t.prix_location_h * (0.9 + random()*0.4))::numeric, 2),
      'km_compteur', floor(random() * (v_t.km_max * 0.7))::bigint,
      'risque', v_t.chance_braquage + round((random()*2 - 1)::numeric, 2)
    );
  end loop;
  insert into offres_john (banque_tag, genere_le, offres) values (p_banque_tag, now(), v_offres)
    on conflict (banque_tag) do update set genere_le = now(), offres = v_offres;
  return v_offres;
end; $$;
grant execute on function obtenir_offres_john(char) to authenticated;


-- ============================================================
-- 2) NIVEAUX DE PERSONNEL DE BANQUE (remplace employe/administrateur)
-- ============================================================
alter table personnel_banque add column if not exists niveau int;
update personnel_banque set niveau = case when role = 'administrateur' then 3 else 1 end where niveau is null;
alter table personnel_banque alter column niveau set not null;
alter table personnel_banque alter column niveau set default 1;
do $$ begin
  alter table personnel_banque add constraint personnel_banque_niveau_check check (niveau between 1 and 3);
exception when duplicate_object then null;
end $$;

drop function if exists est_personnel_banque(char, text);
create or replace function est_personnel_banque(p_banque_tag char(1), p_niveau_min int default 1)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from personnel_banque
    where citoyen_id = auth.uid() and banque_tag = p_banque_tag and niveau >= p_niveau_min
  ) or est_admin_actuel();
$$;

-- Assignation des rôles : réservé à @gouvernement (est_admin), par username.
drop function if exists gouv_assigner_personnel_banque(text, char, text);
create or replace function gouv_assigner_personnel_banque(p_username text, p_banque_tag char(1), p_niveau int)
returns public.personnel_banque language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_row public.personnel_banque;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if p_niveau not between 1 and 3 then raise exception 'Niveau invalide (1 = travailleur, 2 = manager, 3 = dirigeant).'; end if;
  select id into v_id from citoyens where lower(username) = lower(p_username);
  if v_id is null then raise exception 'Citoyen introuvable.'; end if;
  insert into personnel_banque (citoyen_id, banque_tag, role, niveau)
    values (v_id, p_banque_tag, case when p_niveau = 3 then 'administrateur' else 'employe' end, p_niveau)
    on conflict (citoyen_id, banque_tag) do update set niveau = excluded.niveau, role = excluded.role
    returning * into v_row;
  return v_row;
end; $$;
grant execute on function gouv_assigner_personnel_banque(text,char,int) to authenticated;

create or replace function gouv_lister_personnel_banque(p_banque_tag char(1))
returns table(username text, prenom text, nom text, niveau int) language sql stable security definer set search_path = public as $$
  select c.username, c.prenom, c.nom, p.niveau
  from personnel_banque p join citoyens c on c.id = p.citoyen_id
  where p.banque_tag = p_banque_tag and est_admin_actuel()
  order by p.niveau desc, c.username;
$$;
grant execute on function gouv_lister_personnel_banque(char) to authenticated;

-- ---- Mise à jour des contrôles d'accès dans chaque fonction ----
-- (même signature partout : CREATE OR REPLACE suffit, sauf demarrer_automatisation
-- qui gagne un paramètre et doit donc être supprimée puis recréée.)

create or replace function ameliorer_production_clic(p_banque_tag char(1))
returns public.banques_nationales language plpgsql security definer set search_path = public as $$
declare v_prix numeric; v_row public.banques_nationales;
begin
  if not est_personnel_banque(p_banque_tag, 2) then raise exception 'Accès refusé : réservé aux managers et dirigeants de la banque.'; end if;
  select round(120 * power(1.25, niveau_clic - 1), 4) into v_prix from banques_nationales where tag = p_banque_tag;
  update banques_nationales set tresorerie = tresorerie - v_prix, niveau_clic = niveau_clic + 1
    where tag = p_banque_tag and tresorerie >= v_prix
    returning * into v_row;
  if v_row is null then raise exception 'Trésorerie de la banque insuffisante (coût: % R$).', v_prix; end if;
  return v_row;
end; $$;
grant execute on function ameliorer_production_clic(char) to authenticated;

create or replace function retirer_amelioration_production_clic(p_banque_tag char(1))
returns public.banques_nationales language plpgsql security definer set search_path = public as $$
declare v_remboursement numeric; v_row public.banques_nationales;
begin
  if not est_personnel_banque(p_banque_tag, 2) then raise exception 'Accès refusé : réservé aux managers et dirigeants de la banque.'; end if;
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

create or replace function arreter_automatisation(p_banque_tag char(1))
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_personnel_banque(p_banque_tag, 2) then raise exception 'Accès refusé : réservé aux managers et dirigeants de la banque.'; end if;
  update automatisation_banque set actif = false where banque_tag = p_banque_tag;
end; $$;
grant execute on function arreter_automatisation(char) to authenticated;

create or replace function reparer_automatisation(p_banque_tag char(1))
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_personnel_banque(p_banque_tag, 2) then raise exception 'Accès refusé : réservé aux managers et dirigeants de la banque.'; end if;
  update automatisation_banque set en_panne = false, dernier_cycle = now() where banque_tag = p_banque_tag;
end; $$;
grant execute on function reparer_automatisation(char) to authenticated;

create or replace function embaucher_employe_maintenance(p_banque_tag char(1), p_actif boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_personnel_banque(p_banque_tag, 2) then raise exception 'Accès refusé : réservé aux managers et dirigeants de la banque.'; end if;
  update banques_nationales set employe_anti_bug = p_actif where tag = p_banque_tag;
end; $$;
grant execute on function embaucher_employe_maintenance(char, boolean) to authenticated;

create or replace function acheter_vehicule(p_banque_tag char(1), p_type text)
returns public.vehicules language plpgsql security definer set search_path = public as $$
declare v_prix numeric; v_cat text; v_max int; v_actuel int; v_row public.vehicules;
begin
  if not est_personnel_banque(p_banque_tag, 2) then raise exception 'Accès refusé : réservé aux managers et dirigeants de la banque.'; end if;
  select prix_achat, categorie into v_prix, v_cat from types_vehicules where type = p_type;
  if v_prix is null then raise exception 'Type de véhicule invalide.'; end if;

  select case v_cat when 'camion' then camions_max when 'bateau' then bateaux_max else avions_max end
    into v_max from banques_nationales where tag = p_banque_tag;
  select count(*) into v_actuel from vehicules where banque_tag = p_banque_tag and achete
    and type in (select type from types_vehicules where categorie = v_cat);
  if v_actuel >= v_max then raise exception 'Flotte au maximum pour cette catégorie (% / %).', v_actuel, v_max; end if;

  if (select tresorerie from banques_nationales where tag = p_banque_tag) < v_prix then
    raise exception 'Trésorerie de la banque insuffisante (coût: % R$).', v_prix;
  end if;

  update banques_nationales set tresorerie = tresorerie - v_prix where tag = p_banque_tag;
  insert into vehicules (banque_tag, type, achete) values (p_banque_tag, p_type, true) returning * into v_row;
  return v_row;
end; $$;
grant execute on function acheter_vehicule(char, text) to authenticated;

create or replace function ameliorer_vehicule(p_vehicule_id uuid, p_amelioration text)
returns public.vehicules language plpgsql security definer set search_path = public as $$
declare v_veh public.vehicules; v_prix numeric; v_row public.vehicules;
begin
  select * into v_veh from vehicules where id = p_vehicule_id;
  if v_veh is null then raise exception 'Véhicule introuvable.'; end if;
  if not est_personnel_banque(v_veh.banque_tag, 2) then raise exception 'Accès refusé : réservé aux managers et dirigeants de la banque.'; end if;
  if not v_veh.achete then raise exception 'Un véhicule loué ne peut pas être amélioré.'; end if;
  v_prix := case p_amelioration
    when 'moteur' then 25000 when 'blindage' then 60000 when 'coffre' then 40000
    when 'gps' then 15000 when 'chauffeur' then 10000 else null end;
  if v_prix is null then raise exception 'Amélioration invalide.'; end if;
  if (v_veh.ameliorations->>p_amelioration) = 'true' then raise exception 'Déjà installée.'; end if;
  if (select tresorerie from banques_nationales where tag = v_veh.banque_tag) < v_prix then
    raise exception 'Trésorerie de la banque insuffisante (coût: % R$).', v_prix;
  end if;
  update banques_nationales set tresorerie = tresorerie - v_prix where tag = v_veh.banque_tag;
  update vehicules set ameliorations = jsonb_set(ameliorations, array[p_amelioration], 'true'::jsonb)
    where id = p_vehicule_id returning * into v_row;
  return v_row;
end; $$;
grant execute on function ameliorer_vehicule(uuid, text) to authenticated;

create or replace function charger_camion(p_vehicule_id uuid, p_composition jsonb)
returns public.vehicules language plpgsql security definer set search_path = public as $$
declare
  v_veh public.vehicules; v_type public.types_vehicules; v_cle text; v_qte bigint; v_total_billets bigint := 0;
  v_poids_g numeric := 0; v_capacite bigint; v_row public.vehicules; v_pending jsonb;
begin
  select * into v_veh from vehicules where id = p_vehicule_id for update;
  if v_veh is null then raise exception 'Véhicule introuvable.'; end if;
  if not est_personnel_banque(v_veh.banque_tag, 2) then raise exception 'Accès refusé : réservé aux managers et dirigeants de la banque.'; end if;
  if v_veh.statut <> 'disponible' then raise exception 'Ce véhicule n''est pas disponible.'; end if;

  select * into v_type from types_vehicules where type = v_veh.type;
  v_capacite := v_type.capacite_billets * (case when (v_veh.ameliorations->>'coffre') = 'true' then 1.5 else 1 end);

  select billets_en_attente into v_pending from banques_nationales where tag = v_veh.banque_tag for update;

  for v_cle, v_qte in select key, value::bigint from jsonb_each_text(p_composition) loop
    if v_qte <= 0 then continue; end if;
    if coalesce((v_pending->>v_cle)::bigint, 0) < v_qte then
      raise exception 'Pas assez de billets de % R$ en attente dans le coffre de la banque.', v_cle;
    end if;
    v_pending := jsonb_set(v_pending, array[v_cle], to_jsonb((v_pending->>v_cle)::bigint - v_qte));
    v_total_billets := v_total_billets + v_qte;
    v_poids_g := v_poids_g + v_qte;
  end loop;

  if v_total_billets = 0 then raise exception 'Aucune cargaison sélectionnée.'; end if;
  if v_total_billets > v_capacite then raise exception 'Capacité du véhicule dépassée (% / % billets).', v_total_billets, v_capacite; end if;
  if v_poids_g > v_type.poids_max_kg * 1000 then raise exception 'Poids maximal du véhicule dépassé.'; end if;

  update banques_nationales set billets_en_attente = v_pending where tag = v_veh.banque_tag;
  update vehicules set cargaison = p_composition, statut = 'charge' where id = p_vehicule_id returning * into v_row;
  return v_row;
end; $$;
grant execute on function charger_camion(uuid, jsonb) to authenticated;

create or replace function louer_vehicule_john(p_banque_tag char(1), p_index int)
returns public.vehicules language plpgsql security definer set search_path = public as $$
declare v_offres jsonb; v_off jsonb; v_row public.vehicules;
begin
  if not est_personnel_banque(p_banque_tag, 2) then raise exception 'Accès refusé : réservé aux managers et dirigeants de la banque.'; end if;
  v_offres := obtenir_offres_john(p_banque_tag);
  if p_index < 0 or p_index >= jsonb_array_length(v_offres) then raise exception 'Offre invalide.'; end if;
  v_off := v_offres -> p_index;
  insert into vehicules (banque_tag, type, achete, loue)
    values (p_banque_tag, v_off->>'type', false, true)
  returning * into v_row;
  update vehicules set km_parcourus = (v_off->>'km_compteur')::numeric where id = v_row.id;
  select * into v_row from vehicules where id = v_row.id;
  return v_row;
end; $$;
grant execute on function louer_vehicule_john(char, int) to authenticated;

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
  if not est_personnel_banque(v_veh.banque_tag, 2) then raise exception 'Accès refusé : réservé aux managers et dirigeants de la banque.'; end if;
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
    v_legs := v_legs || jsonb_build_array(v_leg);
  end loop;

  v_prix_essence := prix_essence_actuel() / 15.0;
  v_cout_essence := (v_prm.distance_moyenne_km * jsonb_array_length(v_legs)) * v_prix_essence
    * (case when (v_veh.ameliorations->>'moteur') = 'true' then 0.9 else 1 end);
  if p_escorte is not null then
    v_cout_essence := v_cout_essence + ((v_prm.distance_moyenne_km * jsonb_array_length(v_legs)) * v_prix_essence * 2);
  end if;

  v_cout_location := case when v_veh.loue then v_type.prix_location_h * extract(epoch from v_temps_cumule)/3600.0 else 0 end;
  if p_escorte is not null then
    v_cout_location := v_cout_location + v_esc.prix_location + v_esc.prix_heure * extract(epoch from v_temps_cumule)/3600.0;
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


-- ============================================================
-- 3) NUMÉRO DE SUIVI PAR VÉHICULE
-- ============================================================
alter table vehicules add column if not exists numero_suivi text;

create or replace function _generer_numero_suivi_vehicule()
returns trigger language plpgsql as $$
begin
  if new.numero_suivi is null then
    new.numero_suivi := 'VH-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
  end if;
  return new;
end; $$;

drop trigger if exists trg_numero_suivi_vehicule on vehicules;
create trigger trg_numero_suivi_vehicule before insert on vehicules
  for each row execute function _generer_numero_suivi_vehicule();

-- Attribue un numéro aux véhicules déjà existants qui n'en ont pas.
update vehicules set numero_suivi = 'VH-' || upper(substr(md5(random()::text || id::text), 1, 6))
  where numero_suivi is null;


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
  if not est_personnel_banque(v_liv.banque_tag, 2) then raise exception 'Accès refusé : réservé aux managers et dirigeants de la banque.'; end if;

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
    'id', v_liv.id, 'vehicule_id', v_liv.vehicule_id,
    'numero_suivi', (select numero_suivi from vehicules where id = v_liv.vehicule_id),
    'statut', v_liv.statut, 'depart_le', v_liv.depart_le, 'terminee_le', v_liv.terminee_le,
    'distance_totale_km', v_liv.distance_totale_km, 'duree_totale_h', round(v_liv.duree_totale_h,2),
    'km_parcourus', v_km_valides, 'progress_pct', least(100, v_progress),
    'province_actuelle', case when v_leg_courant is not null then (v_liv.legs -> v_leg_courant)->>'province' else null end,
    'braquages', v_liv.braquages, 'accidents', v_liv.accidents,
    'montant_total', v_liv.montant_total, 'montant_livre', v_liv.montant_livre, 'legs', v_public_legs
  );
end; $$;
grant execute on function verifier_livraison(uuid) to authenticated;

create or replace function livraisons_actives(p_banque_tag char(1))
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_resultats jsonb := '[]'::jsonb;
begin
  if not est_personnel_banque(p_banque_tag, 2) then raise exception 'Accès refusé : réservé aux managers et dirigeants de la banque.'; end if;
  for v_id in select id from livraisons where banque_tag = p_banque_tag and statut = 'en_cours' loop
    v_resultats := v_resultats || verifier_livraison(v_id);
  end loop;
  return v_resultats;
end; $$;
grant execute on function livraisons_actives(char) to authenticated;


-- ============================================================
-- 4) DESTRUCTION — réservée exclusivement à @gouvernement
-- ============================================================
create or replace function detruire_billets(p_banque_tag char(1), p_valeur numeric, p_quantite bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_ad numeric; v_t numeric; v_r numeric; v_hausse numeric; v_nouveau_r numeric; v_cout numeric;
  v_cle text; v_pending jsonb; v_disponible bigint;
begin
  if not est_admin_actuel() then
    raise exception 'Accès refusé : la destruction de billets est réservée au gouvernement.';
  end if;
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
-- 5) AUTOMATISATION — quantité de billets par cycle configurable
-- ============================================================
alter table automatisation_banque add column if not exists quantite_par_cycle int not null default 1;
do $$ begin
  alter table automatisation_banque add constraint automatisation_banque_qte_check check (quantite_par_cycle >= 1);
exception when duplicate_object then null;
end $$;

drop function if exists demarrer_automatisation(char, numeric[]);
create or replace function demarrer_automatisation(p_banque_tag char(1), p_valeurs numeric[], p_quantite_par_cycle int default 1)
returns public.automatisation_banque language plpgsql security definer set search_path = public as $$
declare v_row public.automatisation_banque; v_toutes_valides boolean;
begin
  if not est_personnel_banque(p_banque_tag, 2) then raise exception 'Accès refusé : réservé aux managers et dirigeants de la banque.'; end if;
  if p_valeurs is null or array_length(p_valeurs,1) is null then raise exception 'Choisissez au moins une valeur de billet.'; end if;
  select bool_and(valeur_billet_valide(d.valeur)) into v_toutes_valides from unnest(p_valeurs) as d(valeur);
  if not coalesce(v_toutes_valides,false) then raise exception 'Valeur de billet invalide dans la sélection.'; end if;
  if p_quantite_par_cycle < 1 then raise exception 'La quantité par cycle doit être d''au moins 1.'; end if;

  update automatisation_banque set actif = true, valeurs_autorisees = p_valeurs, dernier_cycle = now(),
    en_panne = false, quantite_par_cycle = p_quantite_par_cycle
    where banque_tag = p_banque_tag returning * into v_row;
  return v_row;
end; $$;
grant execute on function demarrer_automatisation(char, numeric[], int) to authenticated;

-- Cycle : utilise désormais quantite_par_cycle (plus niveau_clic), et
-- rattrape toujours les cycles écoulés même si l'intervalle client dérive
-- légèrement sous 4 secondes (arrondi correct via floor).
create or replace function traiter_cycle_automatisation(p_banque_tag char(1))
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_auto public.automatisation_banque; v_banque public.banques_nationales; v_cycles int; v_cout numeric;
  v_valeur numeric; v_bug boolean; v_place bigint; v_key text; v_i int; v_qte int;
begin
  perform _rafraichir_jour_roiyal();
  select * into v_auto from automatisation_banque where banque_tag = p_banque_tag for update;
  select * into v_banque from banques_nationales where tag = p_banque_tag for update;
  if v_auto is null or not v_auto.actif or v_auto.en_panne then
    return jsonb_build_object('cycles', 0, 'en_panne', coalesce(v_auto.en_panne,false), 'actif', coalesce(v_auto.actif,false));
  end if;

  v_cycles := greatest(0, least(900, floor(extract(epoch from (now() - v_auto.dernier_cycle)) / 4.0)::int));
  if v_cycles <= 0 then
    return jsonb_build_object('cycles', 0, 'actif', v_auto.actif, 'en_panne', v_auto.en_panne);
  end if;

  v_qte := greatest(1, v_auto.quantite_par_cycle);

  for v_i in 1..v_cycles loop
    exit when v_auto.en_panne or not v_auto.actif;

    select coalesce(sum((value)::bigint),0) into v_place from jsonb_each_text(coalesce(v_banque.billets_en_attente,'{}'::jsonb)) as t(key, value);
    if v_place + v_qte > v_banque.capacite_max then
      v_auto.actif := false;
      exit;
    end if;

    v_bug := (not v_banque.employe_anti_bug) and (random() < 0.001);
    if v_bug then
      v_auto.en_panne := true;
      perform _incrementer_stat(p_banque_tag, 0,0,0,0,0,1,0);
      exit;
    end if;

    v_cout := (30.0 + case when v_banque.employe_anti_bug then 12.5 else 0 end) * (4.0/3600.0);
    if v_banque.tresorerie < v_cout then
      v_auto.actif := false;
      exit;
    end if;
    v_banque.tresorerie := v_banque.tresorerie - v_cout;

    v_valeur := v_auto.valeurs_autorisees[1 + floor(random() * array_length(v_auto.valeurs_autorisees,1))::int];

    declare
      v_r numeric; v_t numeric; v_b bigint; v_j bigint; v_a numeric; v_baisse numeric; v_nouveau_r numeric; v_prix numeric;
    begin
      select valeur_r, valeur_totale_imprimee, billets_imprimes_total, billets_imprimes_jour
        into v_r, v_t, v_b, v_j from roiyal_etat where id = 1;
      v_prix := round(0.23 * (100/v_r), 10);
      if v_banque.tresorerie < v_prix * v_qte then
        v_auto.actif := false;
        exit;
      end if;
      v_a := v_valeur * v_qte;
      v_baisse := (v_a / nullif(v_t + v_a,0)) * 20 * sqrt((v_b + v_qte)/1000000.0) * sqrt((v_j + v_qte)/1000000.0);
      v_nouveau_r := greatest(0.0001, v_r * (1 - (v_baisse/100)));
      update roiyal_etat set valeur_r = v_nouveau_r, valeur_totale_imprimee = v_t + v_a,
        billets_imprimes_total = v_b + v_qte, billets_imprimes_jour = v_j + v_qte,
        valeur_imprimee_jour = valeur_imprimee_jour + v_a where id = 1;
      v_banque.tresorerie := v_banque.tresorerie - (v_prix * v_qte);
      v_key := trim(to_char(v_valeur, 'FM999999990.00'));
      v_banque.billets_en_attente := jsonb_set(coalesce(v_banque.billets_en_attente,'{}'::jsonb), array[v_key],
        to_jsonb(coalesce((v_banque.billets_en_attente->>v_key)::bigint,0) + v_qte));
      perform _incrementer_stat(p_banque_tag, v_qte, v_a, 0,0,0,0, v_baisse);
    end;
    v_auto.dernier_cycle := v_auto.dernier_cycle + interval '4 seconds';
  end loop;

  update automatisation_banque set actif = v_auto.actif, en_panne = v_auto.en_panne, dernier_cycle = v_auto.dernier_cycle
    where banque_tag = p_banque_tag;
  update banques_nationales set tresorerie = v_banque.tresorerie, billets_en_attente = v_banque.billets_en_attente
    where tag = p_banque_tag;

  return jsonb_build_object('cycles', v_cycles, 'en_panne', v_auto.en_panne, 'actif', v_auto.actif);
end; $$;
grant execute on function traiter_cycle_automatisation(char) to authenticated;


-- ============================================================
-- 6) PIB NATIONAL — visible par tous les citoyens
-- ============================================================
create table if not exists pib_historique (
  id             int primary key default 1 check (id = 1),
  pib_reference  numeric not null default 0,
  date_reference timestamptz not null default now()
);
insert into pib_historique (id) values (1) on conflict (id) do nothing;
alter table pib_historique enable row level security;
drop policy if exists "Lecture publique PIB historique" on pib_historique;
create policy "Lecture publique PIB historique" on pib_historique for select using (true);

-- Simplification assumée (voir en-tête du fichier) : pas encore de
-- colonne "argent_attendu" ni de scission trésor public/privé du
-- gouvernement dans le site — hors périmètre de cette demande.
create or replace function pib_actuel()
returns numeric language sql stable security definer set search_path = public as $$
  select
    coalesce((select solde from tresor_public where id = 1), 0)
    + coalesce((select sum(tresorerie + dettes + prets + compte_chomage + compte_parentalite + compte_retraite) from citoyens), 0)
    + coalesce((select sum(tresorerie) from banques_nationales), 0);
$$;
grant execute on function pib_actuel() to authenticated, anon;

create or replace function _rafraichir_pib_historique()
returns void language plpgsql security definer set search_path = public as $$
begin
  update pib_historique set pib_reference = pib_actuel(), date_reference = now()
    where id = 1 and date_reference <= now() - interval '59 days';
end; $$;

create or replace function tableau_de_bord_national()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_pib numeric; v_ref numeric; v_date timestamptz; v_variation numeric;
begin
  perform _rafraichir_pib_historique();
  v_pib := pib_actuel();
  select pib_reference, date_reference into v_ref, v_date from pib_historique where id = 1;
  v_variation := case when v_ref = 0 then 0 else round(((v_pib - v_ref)/v_ref)*100, 4) end;
  return jsonb_build_object(
    'pib_actuel', v_pib, 'pib_reference', v_ref, 'date_reference', v_date, 'variation_pct', v_variation
  );
end; $$;
grant execute on function tableau_de_bord_national() to authenticated, anon;

-- ============================================================
-- FIN DES CORRECTIFS 2
-- ============================================================
