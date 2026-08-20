-- ============================================================
-- PATCH — Presse monétaire, banques nationales, flotte de
-- livraison, braquages/accidents, automatisation, destruction
-- de billets, résidence provinciale et trésor du gouvernement.
--
-- 100% additif : n'écrase aucune table/fonction existante,
-- sauf `inscrire_citoyen` (remplacée par une version avec un
-- paramètre de plus : p_province) et `deposer_revenu_citoyen`
-- (même signature, juste enrichie pour débiter la bonne banque).
-- À exécuter APRÈS tous les fichiers listés dans order.txt.
--
-- HYPOTHÈSES faites faute de précision dans la demande d'origine
-- (modifiables en un clic dans `parametres_livraison`, table §9) :
--   - Distance moyenne entre deux provinces livrées : 350 km
--   - Vitesse de base par catégorie de véhicule (non fournie) :
--     petit/moyen/gros/industriel camion (blindé ou non) : 90/80/70/60 km/h,
--     bateau : 35 km/h, avion : 550 km/h
--   - Grande-Capitale et Marcio sont réclamées à la fois par la
--     Banque L et la Banque C dans votre texte. Pour le salaire
--     (une seule banque payeuse par province de résidence), je les
--     attribue à C (Banque de la Capitale). Les DEUX banques
--     continuent chacune de livrer ces provinces avec leur propre
--     pourcentage (aucune perte d'information).
--   - Le braquage et l'accident sont tirés UNE fois par voyage
--     (et non par province) : un camion qui se fait braquer perd
--     toute sa cargaison, ce qui correspond à « le camion » comme
--     cible unique de la demande.
-- ============================================================

-- ============================================================
-- 1) PROVINCE DE RÉSIDENCE — inscription & salaire
-- ============================================================
alter table citoyens add column if not exists province_residence text;

create table if not exists province_residence_banque (
  province    text primary key,
  banque_tag  char(1) not null
);
insert into province_residence_banque (province, banque_tag) values
  ('Isulae','M'), ('Balques','M'), ('Vénésie','M'), ('Bushard Bay','M'), ('Tonawa','M'), ('Pruxe-Slamique','M'),
  ('Talon-Andrien','N'), ('Talon-Étalien','N'), ('Ombrie','N'), ('Itênnes','N'),
  ('Brien','L'), ('Romagna','L'),
  ('Grande-Capitale','C'), ('Marcio','C'), ('Baxe','C'),
  ('Côte-Anglaise','H'), ('Jance','H'), ('Alanbie','H'), ('Aloies','H'), ('Côte d''Avoigne','H'),
  ('Vénéz','H'), ('Hors-Grande-Vénésie','H'), ('Alonse','H'), ('Chagne','H'),
  ('Fleury','P'), ('Milela-Cale','P'), ('Prisonia','P'), ('Quoueta-Et-Milenniar-Étalois','P'),
  ('Île Saint-Étienne','P'), ('Gibaltage','P'), ('Grâdes','P'), ('North Milela','P'), ('Tivainne','P')
on conflict (province) do nothing;

-- ============================================================
-- 2) BANQUES NATIONALES
-- ============================================================
create table if not exists banques_nationales (
  tag                char(1) primary key,
  nom                text not null,
  ville_principale   text,
  tresorerie         numeric not null default 0,
  capacite_max       bigint not null,
  camions_max        int not null default 0,
  bateaux_max        int not null default 0,
  avions_max         int not null default 0,
  niveau_clic        int not null default 1,      -- billets produits par clic manuel
  billets_en_attente jsonb not null default '{}'::jsonb, -- coffre d'impression, pas encore livré
  employe_anti_bug   boolean not null default false
);
insert into banques_nationales (tag, nom, ville_principale, capacite_max, camions_max, bateaux_max, avions_max) values
  ('M','Banque Nationale du Maréchal','Maréchal', 250000000, 60, 15, 8),
  ('N','Banque Nationale Nopolitaine','Nopol', 500000000, 50, 10, 10),
  ('L','Banque Nationale de Lataylon','Lataylon', 900000000, 120, 5, 8),
  ('C','Banque Nationale de la Capitale','Imperoma', 3000000000, 150, 3, 12),
  ('H','Banque Nationale de Newhouse','Newhouse', 1500000000, 100, 12, 15),
  ('P','Banque Nationale Fleury','Port-Aux-Souverains', 9000000000, 220, 35, 25)
on conflict (tag) do nothing;

-- Répartition population/pourcentage par banque et province livrée
-- (sert à la fois d'affichage et à la répartition du montant livré).
create table if not exists banque_provinces (
  id           bigserial primary key,
  banque_tag   char(1) not null references banques_nationales(tag),
  province     text not null,
  population   bigint not null,
  part_pourcentage numeric not null,
  unique (banque_tag, province)
);
insert into banque_provinces (banque_tag, province, population, part_pourcentage) values
  ('M','Vénésie',1472000,32.79), ('M','Bushard Bay',1277344,28.45), ('M','Balques',875000,19.49),
  ('M','Isulae',355000,7.91), ('M','Tonawa',354000,7.89), ('M','Pruxe-Slamique',155675,3.47),
  ('N','Talon-Andrien',2221482,40.98), ('N','Talon-Étalien',1592000,29.37), ('N','Ombrie',875000,16.14), ('N','Itênnes',732000,13.50),
  ('L','Grande-Capitale',4012391,52.85), ('L','Marcio',1615000,21.27), ('L','Romagna',1408000,18.55), ('L','Brien',556000,7.32),
  ('C','Baxe',6658410,54.20), ('C','Grande-Capitale',4012391,32.66), ('C','Marcio',1615000,13.15),
  ('P','Fleury',2637000,52.35), ('P','Milela-Cale',1076000,21.36), ('P','Grâdes',639000,12.68), ('P','Tivainne',348000,6.91),
  ('P','North Milela',118951,2.36), ('P','Île Saint-Étienne',97000,1.93), ('P','Prisonia',76000,1.51),
  ('P','Quoueta-Et-Milenniar-Étalois',23506,0.47), ('P','Gibaltage',22000,0.44),
  ('H','Chagne',1170971,29.25), ('H','Aloies',673000,16.81), ('H','Hors-Grande-Vénésie',537000,13.42),
  ('H','Alonse',437000,10.92), ('H','Côte-Anglaise',331000,8.27), ('H','Jance',319000,7.97),
  ('H','Vénéz',234000,5.85), ('H','Alanbie',215000,5.37), ('H','Côte d''Avoigne',86000,2.15)
on conflict (banque_tag, province) do nothing;

alter table banques_nationales enable row level security;
alter table banque_provinces enable row level security;
alter table province_residence_banque enable row level security;
create policy "Lecture publique des banques" on banques_nationales for select using (true);
create policy "Lecture publique des provinces bancaires" on banque_provinces for select using (true);
create policy "Lecture publique de la résidence->banque" on province_residence_banque for select using (true);

-- ============================================================
-- 3) PERSONNEL DE BANQUE (employés / administrateurs de banque)
-- ============================================================
create table if not exists personnel_banque (
  id           uuid primary key default gen_random_uuid(),
  citoyen_id   uuid not null references auth.users(id) on delete cascade,
  banque_tag   char(1) not null references banques_nationales(tag),
  role         text not null check (role in ('employe','administrateur')),
  embauche_le  timestamptz not null default now(),
  unique (citoyen_id, banque_tag)
);
alter table personnel_banque enable row level security;

create policy "Un employé voit son propre poste" on personnel_banque for select
  using (auth.uid() = citoyen_id or est_admin_actuel());

create or replace function mon_personnel_banque()
returns setof personnel_banque language sql stable security definer set search_path = public as $$
  select * from personnel_banque where citoyen_id = auth.uid();
$$;
grant execute on function mon_personnel_banque() to authenticated;

create or replace function est_personnel_banque(p_banque_tag char(1), p_role_min text default 'employe')
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from personnel_banque
    where citoyen_id = auth.uid() and banque_tag = p_banque_tag
      and (p_role_min = 'employe' or role = 'administrateur')
  ) or est_admin_actuel();
$$;

-- Réservé au gouvernement (admin global du site) : embaucher/renvoyer le personnel d'une banque
create or replace function gouv_assigner_personnel_banque(p_username text, p_banque_tag char(1), p_role text)
returns personnel_banque language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_row personnel_banque;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if p_role not in ('employe','administrateur') then raise exception 'Rôle invalide.'; end if;
  select id into v_id from citoyens where lower(username) = lower(p_username);
  if v_id is null then raise exception 'Citoyen introuvable.'; end if;
  insert into personnel_banque (citoyen_id, banque_tag, role) values (v_id, p_banque_tag, p_role)
    on conflict (citoyen_id, banque_tag) do update set role = excluded.role
    returning * into v_row;
  return v_row;
end; $$;
grant execute on function gouv_assigner_personnel_banque(text,char,text) to authenticated;

create or replace function gouv_renvoyer_personnel_banque(p_username text, p_banque_tag char(1))
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  delete from personnel_banque where banque_tag = p_banque_tag
    and citoyen_id = (select id from citoyens where lower(username) = lower(p_username));
end; $$;
grant execute on function gouv_renvoyer_personnel_banque(text,char) to authenticated;

-- ============================================================
-- 4) ÉTAT DU ROIYAL (R en %) — inflation calculée directement
-- ============================================================
create table if not exists roiyal_etat (
  id                        int primary key default 1 check (id = 1),
  valeur_r                  numeric not null default 100,   -- R (%)
  billets_imprimes_total    bigint not null default 0,      -- B
  valeur_totale_imprimee    numeric not null default 0,     -- T
  billets_detruits_total    bigint not null default 0,
  jour_reference            date not null default current_date,
  billets_imprimes_jour     bigint not null default 0,      -- J
  valeur_imprimee_jour      numeric not null default 0
);
insert into roiyal_etat (id) values (1) on conflict (id) do nothing;
alter table roiyal_etat enable row level security;
create policy "Lecture publique du Roiyal" on roiyal_etat for select using (true);

create or replace function prix_impression_actuel()
returns numeric language sql stable as $$
  select round(0.23 * (100 / valeur_r), 10) from roiyal_etat where id = 1;
$$;

create or replace function prix_essence_actuel()
returns numeric language sql stable as $$
  select round(4.2 * (100 / valeur_r), 6) from roiyal_etat where id = 1;
$$;

create or replace function inflation_pourcentage()
returns numeric language sql stable as $$
  select round(100 - valeur_r, 4) from roiyal_etat where id = 1;
$$;

-- S'assure que le "jour" (compteurs "aujourd'hui") bascule à minuit
create or replace function _rafraichir_jour_roiyal()
returns void language plpgsql security definer set search_path = public as $$
begin
  update roiyal_etat
    set jour_reference = current_date, billets_imprimes_jour = 0, valeur_imprimee_jour = 0
    where id = 1 and jour_reference <> current_date;
end; $$;

-- ============================================================
-- 5) STATISTIQUES (aujourd'hui / tous les temps) — par banque
-- ============================================================
create table if not exists stats_banque_total (
  banque_tag        char(1) primary key references banques_nationales(tag),
  billets_imprimes  bigint not null default 0,
  valeur_imprimee   numeric not null default 0,
  camions_envoyes   int not null default 0,
  braquages         int not null default 0,
  accidents         int not null default 0,
  pannes            int not null default 0,
  inflation_causee  numeric not null default 0
);
insert into stats_banque_total (banque_tag) select tag from banques_nationales
  on conflict (banque_tag) do nothing;

create table if not exists stats_banque_jour (
  banque_tag        char(1) not null references banques_nationales(tag),
  jour              date not null default current_date,
  billets_imprimes  bigint not null default 0,
  valeur_imprimee   numeric not null default 0,
  camions_envoyes   int not null default 0,
  braquages         int not null default 0,
  accidents         int not null default 0,
  pannes            int not null default 0,
  inflation_causee  numeric not null default 0,
  primary key (banque_tag, jour)
);
alter table stats_banque_total enable row level security;
alter table stats_banque_jour enable row level security;
create policy "Lecture publique stats totales" on stats_banque_total for select using (true);
create policy "Lecture publique stats du jour" on stats_banque_jour for select using (true);

create or replace function _incrementer_stat(
  p_banque_tag char(1), p_billets bigint default 0, p_valeur numeric default 0,
  p_camions int default 0, p_braquages int default 0, p_accidents int default 0,
  p_pannes int default 0, p_inflation numeric default 0
) returns void language plpgsql security definer set search_path = public as $$
begin
  update stats_banque_total set
    billets_imprimes = billets_imprimes + p_billets, valeur_imprimee = valeur_imprimee + p_valeur,
    camions_envoyes = camions_envoyes + p_camions, braquages = braquages + p_braquages,
    accidents = accidents + p_accidents, pannes = pannes + p_pannes,
    inflation_causee = inflation_causee + p_inflation
    where banque_tag = p_banque_tag;

  insert into stats_banque_jour (banque_tag, jour, billets_imprimes, valeur_imprimee, camions_envoyes, braquages, accidents, pannes, inflation_causee)
    values (p_banque_tag, current_date, p_billets, p_valeur, p_camions, p_braquages, p_accidents, p_pannes, p_inflation)
  on conflict (banque_tag, jour) do update set
    billets_imprimes = stats_banque_jour.billets_imprimes + excluded.billets_imprimes,
    valeur_imprimee = stats_banque_jour.valeur_imprimee + excluded.valeur_imprimee,
    camions_envoyes = stats_banque_jour.camions_envoyes + excluded.camions_envoyes,
    braquages = stats_banque_jour.braquages + excluded.braquages,
    accidents = stats_banque_jour.accidents + excluded.accidents,
    pannes = stats_banque_jour.pannes + excluded.pannes,
    inflation_causee = stats_banque_jour.inflation_causee + excluded.inflation_causee;
end; $$;

-- Vue "aujourd'hui" agrégée tout pays (pratique pour le tableau de bord global)
create or replace view stats_globales_jour as
  select current_date as jour,
    coalesce(sum(billets_imprimes) filter (where jour = current_date), 0) as billets_imprimes,
    coalesce(sum(valeur_imprimee) filter (where jour = current_date), 0) as valeur_imprimee,
    coalesce(sum(camions_envoyes) filter (where jour = current_date), 0) as camions_envoyes,
    coalesce(sum(braquages) filter (where jour = current_date), 0) as braquages,
    coalesce(sum(accidents) filter (where jour = current_date), 0) as accidents,
    coalesce(sum(pannes) filter (where jour = current_date), 0) as pannes,
    coalesce(sum(inflation_causee) filter (where jour = current_date), 0) as inflation_causee
  from stats_banque_jour;

create or replace view stats_globales_total as
  select
    coalesce(sum(billets_imprimes),0) as billets_imprimes, coalesce(sum(valeur_imprimee),0) as valeur_imprimee,
    coalesce(sum(camions_envoyes),0) as camions_envoyes, coalesce(sum(braquages),0) as braquages,
    coalesce(sum(accidents),0) as accidents, coalesce(sum(pannes),0) as pannes,
    coalesce(sum(inflation_causee),0) as inflation_causee
  from stats_banque_total;

-- ============================================================
-- 6) IMPRESSION MANUELLE
-- ============================================================
create or replace function imprimer_billet(p_banque_tag char(1), p_valeur numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_quantite int; v_prix numeric; v_cout numeric; v_r numeric; v_t numeric; v_b bigint; v_j bigint;
  v_a numeric; v_baisse numeric; v_nouveau_r numeric; v_pending jsonb; v_cle text;
begin
  if not est_personnel_banque(p_banque_tag) then raise exception 'Accès refusé : réservé au personnel de cette banque.'; end if;
  if p_valeur not in (0.5,1,5,50,500) then raise exception 'Valeur de billet invalide.'; end if;
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

-- Amélioration "+1 billet par clic" (prix ×1,25 à chaque niveau, base 120 R$)
create or replace function prix_prochaine_amelioration_clic(p_banque_tag char(1))
returns numeric language sql stable as $$
  select round(120 * power(1.25, niveau_clic - 1), 4) from banques_nationales where tag = p_banque_tag;
$$;

create or replace function ameliorer_production_clic(p_banque_tag char(1))
returns banques_nationales language plpgsql security definer set search_path = public as $$
declare v_prix numeric; v_row banques_nationales;
begin
  if not est_personnel_banque(p_banque_tag) then raise exception 'Accès refusé.'; end if;
  select round(120 * power(1.25, niveau_clic - 1), 4) into v_prix from banques_nationales where tag = p_banque_tag;
  update banques_nationales set tresorerie = tresorerie - v_prix, niveau_clic = niveau_clic + 1
    where tag = p_banque_tag and tresorerie >= v_prix
    returning * into v_row;
  if v_row is null then raise exception 'Trésorerie de la banque insuffisante (coût: % R$).', v_prix; end if;
  return v_row;
end; $$;
grant execute on function ameliorer_production_clic(char) to authenticated;

-- ============================================================
-- 7) AUTOMATISATION (une instance par banque)
-- ============================================================
create table if not exists automatisation_banque (
  banque_tag         char(1) primary key references banques_nationales(tag),
  actif              boolean not null default false,
  valeurs_autorisees numeric[] not null default '{}',
  dernier_cycle      timestamptz not null default now(),
  en_panne           boolean not null default false
);
insert into automatisation_banque (banque_tag) select tag from banques_nationales on conflict (banque_tag) do nothing;
alter table automatisation_banque enable row level security;
create policy "Lecture publique automatisation" on automatisation_banque for select using (true);

create or replace function demarrer_automatisation(p_banque_tag char(1), p_valeurs numeric[])
returns automatisation_banque language plpgsql security definer set search_path = public as $$
declare v_row automatisation_banque; v boolean;
begin
  if not est_personnel_banque(p_banque_tag) then raise exception 'Accès refusé.'; end if;
  if p_valeurs is null or array_length(p_valeurs,1) is null then raise exception 'Choisissez au moins une valeur de billet.'; end if;
  select bool_and(v = any(array[0.5,1,5,50,500])) into v from unnest(p_valeurs) as v;
  if not coalesce(v,false) then raise exception 'Valeur de billet invalide dans la sélection.'; end if;
  update automatisation_banque set actif = true, valeurs_autorisees = p_valeurs, dernier_cycle = now(), en_panne = false
    where banque_tag = p_banque_tag returning * into v_row;
  return v_row;
end; $$;
grant execute on function demarrer_automatisation(char, numeric[]) to authenticated;

create or replace function arreter_automatisation(p_banque_tag char(1))
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_personnel_banque(p_banque_tag) then raise exception 'Accès refusé.'; end if;
  update automatisation_banque set actif = false where banque_tag = p_banque_tag;
end; $$;
grant execute on function arreter_automatisation(char) to authenticated;

create or replace function reparer_automatisation(p_banque_tag char(1))
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_personnel_banque(p_banque_tag) then raise exception 'Accès refusé.'; end if;
  update automatisation_banque set en_panne = false, dernier_cycle = now() where banque_tag = p_banque_tag;
end; $$;
grant execute on function reparer_automatisation(char) to authenticated;

create or replace function embaucher_employe_maintenance(p_banque_tag char(1), p_actif boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_personnel_banque(p_banque_tag, 'administrateur') then raise exception 'Accès refusé : réservé aux administrateurs de la banque.'; end if;
  update banques_nationales set employe_anti_bug = p_actif where tag = p_banque_tag;
end; $$;
grant execute on function embaucher_employe_maintenance(char, boolean) to authenticated;

-- Traite les cycles écoulés (appelée par le client toutes les ~4s pendant
-- qu'un employé a la page ouverte ; rattrape aussi tout le retard accumulé
-- pendant que personne n'était en ligne, calculé à partir de dernier_cycle).
create or replace function traiter_cycle_automatisation(p_banque_tag char(1))
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_auto automatisation_banque; v_banque banques_nationales; v_cycles int; v_cout numeric;
  v_valeur numeric; v_bug boolean; v_place bigint; v_key text;
begin
  perform _rafraichir_jour_roiyal();
  select * into v_auto from automatisation_banque where banque_tag = p_banque_tag for update;
  select * into v_banque from banques_nationales where tag = p_banque_tag for update;
  if v_auto is null or not v_auto.actif or v_auto.en_panne then
    return jsonb_build_object('cycles', 0, 'en_panne', coalesce(v_auto.en_panne,false));
  end if;

  v_cycles := least(900, floor(extract(epoch from (now() - v_auto.dernier_cycle)) / 4)::int);
  if v_cycles <= 0 then return jsonb_build_object('cycles', 0); end if;

  for i in 1..v_cycles loop
    exit when v_auto.en_panne;

    -- pas assez de place dans le coffre d'attente de la banque : on coupe
    select coalesce(sum((value)::bigint),0) into v_place from jsonb_each_text(v_banque.billets_en_attente) as t(key, value);
    if v_place + v_banque.niveau_clic > v_banque.capacite_max then
      v_auto.actif := false;
      exit;
    end if;
    -- 0,1% de chance de bug par cycle (réduite à 0 si employé de maintenance actif)
    v_bug := (not v_banque.employe_anti_bug) and (random() < 0.001);
    if v_bug then
      v_auto.en_panne := true;
      perform _incrementer_stat(p_banque_tag, 0,0,0,0,0,1,0);
      exit;
    end if;

    -- coût électricité (30 R$/h) + employé (12,5 R$/h), au prorata d'un cycle de 4s
    v_cout := (30.0 + case when v_banque.employe_anti_bug then 12.5 else 0 end) * (4.0/3600.0);
    if v_banque.tresorerie < v_cout then
      v_auto.actif := false; -- plus assez d'électricité : on coupe proprement
      exit;
    end if;
    v_banque.tresorerie := v_banque.tresorerie - v_cout;

    v_valeur := v_auto.valeurs_autorisees[1 + floor(random() * array_length(v_auto.valeurs_autorisees,1))::int];

    declare
      v_r numeric; v_t numeric; v_b bigint; v_j bigint; v_a numeric; v_baisse numeric; v_nouveau_r numeric; v_prix numeric; v_qte int;
    begin
      select valeur_r, valeur_totale_imprimee, billets_imprimes_total, billets_imprimes_jour
        into v_r, v_t, v_b, v_j from roiyal_etat where id = 1;
      v_qte := v_banque.niveau_clic;
      v_prix := round(0.23 * (100/v_r), 10);
      if v_banque.tresorerie < v_prix * v_qte then exit; end if;
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
-- 8) VÉHICULES DE TRANSPORT — types & flotte
-- ============================================================
create table if not exists types_vehicules (
  type               text primary key,
  categorie          text not null check (categorie in ('camion','bateau','avion')),
  blinde             boolean not null default false,
  capacite_billets   bigint not null,
  poids_max_kg       numeric not null,
  chance_braquage    numeric not null,   -- %
  risque_accident    numeric not null,   -- %
  prix_location_h    numeric not null,
  prix_achat         numeric not null,
  km_max             bigint not null,
  vitesse_base_kmh   numeric not null    -- non fournie dans la demande : estimation, voir en-tête du fichier
);
insert into types_vehicules (type, categorie, blinde, capacite_billets, poids_max_kg, chance_braquage, risque_accident, prix_location_h, prix_achat, km_max, vitesse_base_kmh) values
  ('petit_camion','camion',false,300000,300,12,1.5,80,40000,300000,90),
  ('camion_moyen','camion',false,700000,700,9,2,160,90000,600000,80),
  ('gros_camion','camion',false,1500000,1500,6,3,300,220000,900000,70),
  ('camion_industriel','camion',false,5000000,5000,4,4,700,700000,1500000,60),
  ('petit_camion_blinde','camion',true,300000,300,2,1.8,250,300000,500000,85),
  ('camion_moyen_blinde','camion',true,1000000,1000,1.2,2.2,500,750000,900000,75),
  ('gros_camion_blinde','camion',true,3000000,3000,0.6,3,900,1800000,1500000,65),
  ('camion_industriel_blinde','camion',true,10000000,10000,0.2,3.5,1800,5000000,2500000,55),
  ('bateau','bateau',false,50000000,50000,0.5,2.5,4000,12000000,5000000,35),
  ('avion','avion',false,100000000,100000,0.1,0.8,12000,50000000,10000000,550)
on conflict (type) do nothing;
alter table types_vehicules enable row level security;
create policy "Lecture publique des types de véhicules" on types_vehicules for select using (true);

create table if not exists parametres_livraison (
  id int primary key default 1 check (id = 1),
  distance_moyenne_km numeric not null default 350, -- distance estimée entre deux provinces livrées
  chance_bris_totale numeric not null default 0.05  -- % de chance qu'un véhicule "brise" (perte totale, hors accident/braquage)
);
insert into parametres_livraison (id) values (1) on conflict (id) do nothing;
alter table parametres_livraison enable row level security;
create policy "Lecture publique des paramètres de livraison" on parametres_livraison for select using (true);

create table if not exists vehicules (
  id               uuid primary key default gen_random_uuid(),
  banque_tag       char(1) not null references banques_nationales(tag),
  type             text not null references types_vehicules(type),
  achete           boolean not null default true,
  loue             boolean not null default false,
  loue_expire_le   timestamptz,
  km_parcourus     numeric not null default 0,
  statut           text not null default 'disponible' check (statut in ('disponible','charge','en_livraison','hors_service')),
  hors_service_jusqua timestamptz,
  cargaison        jsonb not null default '{}'::jsonb,      -- { "500.00": 120, ... }
  ameliorations    jsonb not null default '{}'::jsonb,      -- { "moteur":true, "blindage":true, "coffre":true, "gps":true, "chauffeur":true }
  cree_le          timestamptz not null default now()
);
alter table vehicules enable row level security;
create policy "Lecture publique des véhicules" on vehicules for select using (true);

create or replace function acheter_vehicule(p_banque_tag char(1), p_type text)
returns vehicules language plpgsql security definer set search_path = public as $$
declare v_prix numeric; v_cat text; v_max int; v_actuel int; v_row vehicules;
begin
  if not est_personnel_banque(p_banque_tag, 'administrateur') then raise exception 'Accès refusé : réservé aux administrateurs de la banque.'; end if;
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
returns vehicules language plpgsql security definer set search_path = public as $$
declare v_veh vehicules; v_prix numeric; v_row vehicules;
begin
  select * into v_veh from vehicules where id = p_vehicule_id;
  if v_veh is null then raise exception 'Véhicule introuvable.'; end if;
  if not est_personnel_banque(v_veh.banque_tag, 'administrateur') then raise exception 'Accès refusé.'; end if;
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

-- Chargement d'un camion depuis le coffre d'attente de la banque
create or replace function charger_camion(p_vehicule_id uuid, p_composition jsonb)
returns vehicules language plpgsql security definer set search_path = public as $$
declare
  v_veh vehicules; v_type types_vehicules; v_cle text; v_qte bigint; v_total_billets bigint := 0;
  v_poids_g numeric := 0; v_capacite bigint; v_row vehicules; v_pending jsonb;
begin
  select * into v_veh from vehicules where id = p_vehicule_id for update;
  if v_veh is null then raise exception 'Véhicule introuvable.'; end if;
  if not est_personnel_banque(v_veh.banque_tag) then raise exception 'Accès refusé.'; end if;
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
    v_poids_g := v_poids_g + v_qte; -- 1g par billet
  end loop;

  if v_total_billets = 0 then raise exception 'Aucune cargaison sélectionnée.'; end if;
  if v_total_billets > v_capacite then raise exception 'Capacité du véhicule dépassée (% / % billets).', v_total_billets, v_capacite; end if;
  if v_poids_g > v_type.poids_max_kg * 1000 then raise exception 'Poids maximal du véhicule dépassé.'; end if;

  update banques_nationales set billets_en_attente = v_pending where tag = v_veh.banque_tag;
  update vehicules set cargaison = p_composition, statut = 'charge' where id = p_vehicule_id returning * into v_row;
  return v_row;
end; $$;
grant execute on function charger_camion(uuid, jsonb) to authenticated;

-- ------------------------------------------------------------
-- John « Le Routier » — offres de location, régénérées à 396h
-- ------------------------------------------------------------
create table if not exists offres_john (
  banque_tag  char(1) primary key references banques_nationales(tag),
  genere_le   timestamptz not null default now(),
  offres      jsonb not null default '[]'::jsonb
);
alter table offres_john enable row level security;
create policy "Lecture publique des offres de John" on offres_john for select using (true);

create table if not exists john_probabilites (
  type text primary key references types_vehicules(type),
  chance numeric not null
);
insert into john_probabilites (type, chance) values
  ('petit_camion',25), ('camion_moyen',20), ('gros_camion',12), ('camion_industriel',5),
  ('petit_camion_blinde',15), ('camion_moyen_blinde',10), ('gros_camion_blinde',5),
  ('camion_industriel_blinde',2), ('bateau',0.8), ('avion',0.2)
on conflict (type) do nothing;
alter table john_probabilites enable row level security;
create policy "Lecture publique des probabilités de John" on john_probabilites for select using (true);

create or replace function _tirer_type_john()
returns text language plpgsql as $$
declare v_r numeric := random() * 100; v_cumul numeric := 0; v_type text;
begin
  for v_type, v_cumul in
    select type, sum(chance) over (order by chance desc, type) from john_probabilites order by chance desc, type
  loop
    if v_r <= v_cumul then return v_type; end if;
  end loop;
  return 'petit_camion';
end; $$;

create or replace function obtenir_offres_john(p_banque_tag char(1))
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_row offres_john; v_offres jsonb := '[]'::jsonb; v_type text; v_t types_vehicules; v_i int;
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
      'prix_heure', round(v_t.prix_location_h * (0.9 + random()*0.4), 2),
      'km_compteur', floor(random() * (v_t.km_max * 0.7))::bigint,
      'risque', v_t.chance_braquage + round((random()*2 - 1)::numeric, 2)
    );
  end loop;
  insert into offres_john (banque_tag, genere_le, offres) values (p_banque_tag, now(), v_offres)
    on conflict (banque_tag) do update set genere_le = now(), offres = v_offres;
  return v_offres;
end; $$;
grant execute on function obtenir_offres_john(char) to authenticated;

create or replace function louer_vehicule_john(p_banque_tag char(1), p_index int)
returns vehicules language plpgsql security definer set search_path = public as $$
declare v_offres jsonb; v_off jsonb; v_row vehicules;
begin
  if not est_personnel_banque(p_banque_tag) then raise exception 'Accès refusé.'; end if;
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

-- ------------------------------------------------------------
-- ESCORTE POLICIÈRE
-- ------------------------------------------------------------
create table if not exists escortes_types (
  escorte           text primary key,
  reduction_braquage numeric not null,
  reduction_vitesse  numeric not null,
  prix_location      numeric not null,
  prix_heure         numeric not null
);
insert into escortes_types (escorte, reduction_braquage, reduction_vitesse, prix_location, prix_heure) values
  ('standard',40,20,500,80), ('renforcee',50,10,1500,200), ('speciale',60,5,5000,600)
on conflict (escorte) do nothing;
alter table escortes_types enable row level security;
create policy "Lecture publique des escortes" on escortes_types for select using (true);

create or replace function escorte_compatible(p_type text, p_escorte text)
returns boolean language sql immutable as $$
  select case p_type
    when 'petit_camion' then true when 'camion_moyen' then true
    when 'gros_camion' then p_escorte in ('renforcee','speciale')
    when 'camion_industriel' then p_escorte = 'speciale'
    when 'petit_camion_blinde' then p_escorte in ('renforcee','speciale')
    when 'camion_moyen_blinde' then p_escorte in ('renforcee','speciale')
    when 'gros_camion_blinde' then p_escorte = 'speciale'
    when 'camion_industriel_blinde' then p_escorte = 'speciale'
    when 'bateau' then p_escorte = 'speciale'
    when 'avion' then false
    else false
  end;
$$;

-- ------------------------------------------------------------
-- LIVRAISON — traite tout le trajet (toutes les provinces de la
-- région d'agir de la banque) en une seule transaction serveur.
-- ------------------------------------------------------------
create table if not exists livraisons (
  id                uuid primary key default gen_random_uuid(),
  vehicule_id       uuid not null references vehicules(id),
  banque_tag        char(1) not null references banques_nationales(tag),
  escorte           text,
  distance_km       numeric not null,
  duree_h           numeric not null,
  cout_essence      numeric not null,
  cout_location     numeric not null,
  cout_entretien    numeric not null,
  statut            text not null check (statut in ('livree','braquee','accident_perte','bris_total')),
  type_accident      text,
  montant_total     numeric not null,
  montant_livre     numeric not null,
  detail_provinces  jsonb not null default '[]'::jsonb,
  cree_le           timestamptz not null default now()
);
alter table livraisons enable row level security;
create policy "Lecture publique des livraisons" on livraisons for select using (true);

create or replace function livrer_camion(p_vehicule_id uuid, p_escorte text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_veh vehicules; v_type types_vehicules; v_prm parametres_livraison;
  v_nb_provinces int; v_distance numeric; v_vitesse numeric; v_duree numeric;
  v_prix_essence numeric; v_cout_essence numeric; v_cout_location numeric; v_cout_entretien numeric;
  v_chance_braquage numeric; v_chance_accident numeric; v_usure numeric;
  v_montant_total numeric := 0; v_cle text; v_val text; v_qte bigint;
  v_roll numeric; v_statut text := 'livree'; v_type_accident text; v_perte_pct numeric := 0;
  v_reparation numeric := 0; v_montant_livre numeric; v_detail jsonb := '[]'::jsonb; v_prov record;
  v_esc escortes_types; v_km_prov numeric;
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

  select count(*) into v_nb_provinces from banque_provinces where banque_tag = v_veh.banque_tag;
  if v_nb_provinces = 0 then raise exception 'Aucune province associée à cette banque.'; end if;
  v_distance := v_nb_provinces * v_prm.distance_moyenne_km;

  v_vitesse := v_type.vitesse_base_kmh
    * (1 - (v_veh.km_parcourus * 0.0000001 / 100))
    * (case when (v_veh.ameliorations->>'moteur') = 'true' then 1.2 else 1 end)
    * (case when (v_veh.ameliorations->>'gps') = 'true' then 1.2 else 1 end)
    * (case when p_escorte is not null then (1 - v_esc.reduction_vitesse/100.0) else 1 end);
  v_duree := v_distance / greatest(v_vitesse, 5);

  v_prix_essence := prix_essence_actuel() / 15.0; -- R$/km
  v_cout_essence := v_distance * v_prix_essence * (case when (v_veh.ameliorations->>'moteur') = 'true' then 0.9 else 1 end);
  if p_escorte is not null then
    v_cout_essence := v_cout_essence + (v_distance * v_prix_essence * 2); -- 2 voitures de police
  end if;

  v_cout_location := case when v_veh.loue then v_type.prix_location_h * v_duree else 0 end;
  if p_escorte is not null then v_cout_location := v_cout_location + (v_esc.prix_location + v_esc.prix_heure * v_duree); end if;

  v_cout_entretien := 0;
  if (v_veh.ameliorations->>'moteur') = 'true' then v_cout_entretien := v_cout_entretien + 20 * (v_distance/1000); end if;
  if (v_veh.ameliorations->>'blindage') = 'true' then v_cout_entretien := v_cout_entretien + 50 * (v_distance/1000); end if;
  if (v_veh.ameliorations->>'coffre') = 'true' then v_cout_entretien := v_cout_entretien + 15 * (v_distance/1000); end if;
  if (v_veh.ameliorations->>'gps') = 'true' then v_cout_entretien := v_cout_entretien + 5 * (v_distance/1000); end if;

  -- Chances (jamais 0%, même blindé)
  v_chance_braquage := v_type.chance_braquage
    * (case when (v_veh.ameliorations->>'blindage') = 'true' then 0.7 else 1 end)
    * (case when p_escorte is not null then (1 - v_esc.reduction_braquage/100.0) else 1 end);
  v_chance_braquage := greatest(v_chance_braquage, 0.01);

  v_usure := least(20, v_veh.km_parcourus * 0.0000001);
  v_chance_accident := least(15, v_type.risque_accident + (v_veh.km_parcourus * 0.000001))
    * (case when (v_veh.ameliorations->>'chauffeur') = 'true' then 0.85 else 1 end);

  for v_cle, v_val in select key, value from jsonb_each_text(v_veh.cargaison) loop
    v_montant_total := v_montant_total + (v_cle::numeric * v_val::bigint);
  end loop;

  -- 1) Bris total indépendant (rare, jamais 0%)
  if random()*100 < v_prm.chance_bris_totale then
    v_statut := 'bris_total';
  else
    -- 2) Braquage
    if random()*100 < v_chance_braquage then
      v_statut := 'braquee';
    else
      -- 3) Accident
      if random()*100 < v_chance_accident then
        v_roll := random()*100;
        if v_roll < 70 then
          v_type_accident := 'accrochage';
          v_perte_pct := (case when (v_veh.ameliorations->>'chauffeur') = 'true' then 0.008 else 0.01 end);
          v_reparation := v_type.prix_achat * (case when (v_veh.ameliorations->>'chauffeur') = 'true' then 0.004 else 0.005 end);
        elsif v_roll < 95 then
          v_type_accident := 'accident_moyen';
          v_perte_pct := (case when (v_veh.ameliorations->>'chauffeur') = 'true' then 0.425 else 0.5 end);
          v_reparation := v_type.prix_achat * (case when (v_veh.ameliorations->>'chauffeur') = 'true' then 0.0425 else 0.05 end);
        else
          v_type_accident := 'accident_grave';
          v_perte_pct := (case when (v_veh.ameliorations->>'chauffeur') = 'true' then 4.5 else 5 end);
          v_reparation := v_type.prix_achat * (case when (v_veh.ameliorations->>'chauffeur') = 'true' then 0.18 else 0.20 end);
        end if;
        v_statut := 'accident_perte';
      end if;
    end if;
  end if;

  if v_statut = 'livree' then
    v_montant_livre := v_montant_total;
  elsif v_statut = 'accident_perte' then
    v_montant_livre := v_montant_total * (1 - v_perte_pct/100.0);
  else
    v_montant_livre := 0; -- braquée ou bris total : tout est perdu
  end if;

  -- Répartition par province (pour la traçabilité / le rôle-play)
  for v_prov in select province, part_pourcentage from banque_provinces where banque_tag = v_veh.banque_tag loop
    v_detail := v_detail || jsonb_build_object('province', v_prov.province,
      'montant', round(v_montant_livre * v_prov.part_pourcentage/100.0, 2));
  end loop;

  update banques_nationales set
    tresorerie = tresorerie + v_montant_livre - v_cout_essence - v_cout_location - v_cout_entretien - v_reparation
    where tag = v_veh.banque_tag;

  update vehicules set
    statut = case when v_veh.loue then 'hors_service' else 'disponible' end,
    km_parcourus = km_parcourus + v_distance,
    cargaison = '{}'::jsonb,
    hors_service_jusqua = case
      when v_type_accident = 'accident_moyen' then now() + interval '12 hours' * (case when (v_veh.ameliorations->>'chauffeur')='true' then 0.85 else 1 end)
      when v_type_accident = 'accident_grave' then now() + interval '24 hours' * (case when (v_veh.ameliorations->>'chauffeur')='true' then 0.85 else 1 end)
      else null end
    where id = p_vehicule_id;
  -- Un véhicule loué reste marqué 'hors_service' pour toujours après sa
  -- livraison (il "disparaît" fonctionnellement : plus jamais rechargeable).

  insert into livraisons (vehicule_id, banque_tag, escorte, distance_km, duree_h, cout_essence, cout_location,
    cout_entretien, statut, type_accident, montant_total, montant_livre, detail_provinces)
    values (p_vehicule_id, v_veh.banque_tag, p_escorte, v_distance, v_duree, v_cout_essence, v_cout_location,
    v_cout_entretien, v_statut, v_type_accident, v_montant_total, v_montant_livre, v_detail);

  perform _incrementer_stat(v_veh.banque_tag, 0, 0, 1,
    case when v_statut = 'braquee' then 1 else 0 end,
    case when v_type_accident is not null then 1 else 0 end, 0, 0);

  return jsonb_build_object('statut', v_statut, 'type_accident', v_type_accident, 'montant_total', v_montant_total,
    'montant_livre', v_montant_livre, 'distance_km', v_distance, 'duree_h', round(v_duree,2),
    'cout_essence', round(v_cout_essence,2), 'cout_location', round(v_cout_location,2), 'detail', v_detail);
end; $$;
grant execute on function livrer_camion(uuid, text) to authenticated;

-- ============================================================
-- 9) DESTRUCTION DE BILLETS — administrateurs de banque seulement
-- ============================================================
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
  v_ad numeric; v_t numeric; v_r numeric; v_hausse numeric; v_nouveau_r numeric; v_cout numeric; v_total numeric;
begin
  if not est_personnel_banque(p_banque_tag, 'administrateur') then raise exception 'Accès refusé : réservé aux administrateurs de la banque.'; end if;
  if p_quantite <= 0 then raise exception 'Quantité invalide.'; end if;

  v_ad := p_valeur * p_quantite;
  v_cout := p_quantite * 0.02;
  v_total := v_ad + v_cout;
  if (select tresorerie from banques_nationales where tag = p_banque_tag) < v_total then
    raise exception 'Trésorerie de la banque insuffisante pour détruire ces billets (coût total: % R$).', v_total;
  end if;

  select valeur_r, valeur_totale_imprimee into v_r, v_t from roiyal_etat where id = 1;
  v_hausse := ((v_ad / nullif(v_t,0)) * 20 * sqrt(v_ad/1000000.0)) * 0.80;
  v_nouveau_r := v_r * (1 + (v_hausse/100));

  update roiyal_etat set valeur_r = v_nouveau_r, billets_detruits_total = billets_detruits_total + p_quantite where id = 1;
  update banques_nationales set tresorerie = tresorerie - v_total where tag = p_banque_tag;
  insert into destructions_billets (banque_tag, citoyen_id, valeur, quantite, montant, cout, hausse_valeur)
    values (p_banque_tag, auth.uid(), p_valeur, p_quantite, v_ad, v_cout, v_hausse);

  return jsonb_build_object('nouveau_r', v_nouveau_r, 'hausse_valeur', v_hausse, 'cout', v_total);
end; $$;
grant execute on function detruire_billets(char, numeric, bigint) to authenticated;

-- ============================================================
-- 10) TRÉSOR DU GOUVERNEMENT — 2 trésoreries distinctes
-- ============================================================
-- Trésor public : taxes, constats, remboursements de dettes/prêts,
-- virements à @gouvernement, taxe des virements, permis, emprunts,
-- taxes préventives. N'est JAMAIS utilisé pour payer un salaire.
-- Trésorerie bancaire : somme des trésoreries des banques nationales
-- (déjà représentée par banques_nationales.tresorerie — pas dupliquée).
create table if not exists gouvernement_tresor (
  id            int primary key default 1 check (id = 1),
  tresor_public numeric not null default 0
);
insert into gouvernement_tresor (id) values (1) on conflict (id) do nothing;
alter table gouvernement_tresor enable row level security;
create policy "Admin lit le trésor public" on gouvernement_tresor for select using (est_admin_actuel());

create or replace function tresorerie_bancaire_totale()
returns numeric language sql stable as $$
  select coalesce(sum(tresorerie),0) from banques_nationales;
$$;

-- Le gouvernement (admin) reçoit un montant : il choisit la trésorerie cible.
-- p_type_source sert à documenter d'où vient l'argent pour la commission
-- (les constats d'infraction gardent toujours 0,25%–2,25% dans le trésor
-- public, même si le montant net est envoyé vers une banque).
create or replace function gouv_recevoir_montant(
  p_montant numeric, p_tresorerie_cible text, p_source text default 'autre',
  p_banque_tag char(1) default null, p_commission_pct numeric default 0
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_commission numeric := 0; v_net numeric;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if p_tresorerie_cible not in ('public','bancaire') then raise exception 'Trésorerie cible invalide.'; end if;

  if p_source = 'constat' then
    v_commission := p_montant * least(2.25, greatest(0.25, p_commission_pct)) / 100.0;
  end if;
  v_net := p_montant - v_commission;

  update gouvernement_tresor set tresor_public = tresor_public + v_commission where id = 1;

  if p_tresorerie_cible = 'public' then
    update gouvernement_tresor set tresor_public = tresor_public + v_net where id = 1;
  else
    if p_banque_tag is null then raise exception 'Précisez la banque nationale cible.'; end if;
    update banques_nationales set tresorerie = tresorerie + v_net where tag = p_banque_tag;
  end if;

  return jsonb_build_object('net', v_net, 'commission', v_commission);
end; $$;
grant execute on function gouv_recevoir_montant(numeric, text, text, char, numeric) to authenticated;

-- Le gouvernement envoie du trésor public vers une banque (jamais l'inverse
-- via cette fonction, et jamais pour payer un salaire).
create or replace function gouv_envoyer_tresor_public_vers_banque(p_montant numeric, p_banque_tag char(1))
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if (select tresor_public from gouvernement_tresor where id = 1) < p_montant then
    raise exception 'Trésor public insuffisant.';
  end if;
  update gouvernement_tresor set tresor_public = tresor_public - p_montant where id = 1;
  update banques_nationales set tresorerie = tresorerie + p_montant where tag = p_banque_tag;
  return jsonb_build_object('tresor_public_restant', (select tresor_public from gouvernement_tresor where id = 1));
end; $$;
grant execute on function gouv_envoyer_tresor_public_vers_banque(numeric, char) to authenticated;

-- ============================================================
-- 11) INSCRIPTION — ajout de la province de résidence
-- ============================================================
-- PostgreSQL n'autorise pas d'ajouter un paramètre à une fonction existante
-- via CREATE OR REPLACE : on supprime d'abord l'ancienne signature (9
-- paramètres, celle posée par patch-salaire-taxes-epargne.sql).
drop function if exists inscrire_citoyen(text,text,text,text,text,date,boolean,boolean,numeric) cascade;

create or replace function inscrire_citoyen(
  p_username text, p_email text, p_prenom text, p_nom text,
  p_code_social_encrypte text, p_date_naissance date,
  p_protege_gouvernement boolean default false, p_police boolean default false,
  p_salaire numeric default 12.5, p_province text default null
) returns citoyens
language plpgsql security definer set search_path = public as $$
declare
  v_age numeric; v_cas cas_valides; v_row citoyens; v_est_admin boolean;
begin
  if auth.uid() is null then raise exception 'Utilisateur non authentifié.'; end if;

  select * into v_cas from cas_valides where code_encrypte = p_code_social_encrypte;
  if v_cas is null then raise exception 'Code d''assurance social invalide.'; end if;
  if v_cas.utilise then raise exception 'Ce code d''assurance social est déjà associé à un compte.'; end if;
  if upper(trim(v_cas.nom_legal)) <> upper(trim(p_nom)) or upper(trim(v_cas.prenom_legal)) <> upper(trim(p_prenom)) then
    raise exception 'Le nom légal fourni ne correspond pas au code d''assurance social.';
  end if;

  v_age := age_toutouien(p_date_naissance);
  if v_age < 20 then
    raise exception 'Majorité civile non atteinte (20 ans toutouïens requis, actuel: %).', round(v_age, 2);
  end if;

  if p_province is not null and not exists (select 1 from province_residence_banque where province = p_province) then
    raise exception 'Province de résidence invalide.';
  end if;

  v_est_admin := v_cas.est_admin;

  insert into citoyens (id, username, email, prenom, nom, code_social_encrypte, date_naissance,
                         age_toutouien_inscription, est_admin, salaire, taux_revenu, province_residence)
  values (auth.uid(), p_username, p_email, p_prenom, p_nom, p_code_social_encrypte, p_date_naissance,
          v_age, v_est_admin, p_salaire, calculer_taux_revenu(p_salaire), p_province)
  returning * into v_row;

  update cas_valides set utilise = true, citoyen_id = auth.uid(), utilise_le = now()
    where code_encrypte = p_code_social_encrypte;

  return v_row;
end; $$;
grant execute on function inscrire_citoyen(text,text,text,text,text,date,boolean,boolean,numeric,text) to authenticated;

-- Permet à un citoyen déjà inscrit de fixer/mettre à jour sa province
-- (utile pour les comptes créés avant ce patch).
create or replace function definir_ma_province(p_province text)
returns citoyens language plpgsql security definer set search_path = public as $$
declare v_row citoyens;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if not exists (select 1 from province_residence_banque where province = p_province) then
    raise exception 'Province invalide.';
  end if;
  update citoyens set province_residence = p_province where id = auth.uid() returning * into v_row;
  return v_row;
end; $$;
grant execute on function definir_ma_province(text) to authenticated;

-- ============================================================
-- 12) SALAIRE — payé par la trésorerie de la banque de résidence
-- ============================================================
-- Remplace deposer_revenu_citoyen (même signature) : le montant versé au
-- citoyen est maintenant débité de la trésorerie de la Banque Nationale de
-- sa province de résidence (peut passer en négatif si la banque est à sec :
-- le salaire du citoyen n'est jamais bloqué pour cette raison).
create or replace function deposer_revenu_citoyen(p_minutes numeric default 5)
returns numeric language plpgsql security definer set search_path = public as $$
declare v_nouveau numeric; v_montant numeric; v_banque char(1);
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;

  select salaire * p_minutes into v_montant from citoyens where id = auth.uid();
  select banque_tag into v_banque from citoyens c
    join province_residence_banque p on p.province = c.province_residence
    where c.id = auth.uid();

  update citoyens set tresorerie = tresorerie + v_montant, derniere_synchro_tresorerie = now()
    where id = auth.uid() returning tresorerie into v_nouveau;

  if v_banque is not null then
    update banques_nationales set tresorerie = tresorerie - v_montant where tag = v_banque;
  end if;

  return v_nouveau;
end; $$;
grant execute on function deposer_revenu_citoyen(numeric) to authenticated;

-- ============================================================
-- 13) REALTIME (idempotent : relancer le patch ne casse rien)
-- ============================================================
do $$
declare t text;
begin
  foreach t in array array['banques_nationales','roiyal_etat','vehicules','automatisation_banque','livraisons'] loop
    if not exists (
      select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table %I', t);
    end if;
  end loop;
end $$;

-- ============================================================
-- FIN DU PATCH
-- ============================================================
