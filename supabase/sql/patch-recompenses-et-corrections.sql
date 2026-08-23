-- ============================================================
-- patch-recompenses-et-corrections.sql
-- À exécuter après patch-provinces-et-banques.sql. Idempotent.
--
-- CONTENU :
--  1. Correction : Grande-Capitale redevient indépendante (n'est plus
--     fusionnée avec Marcio dans le territoire de la Banque Lataylon).
--  2. Argent attendu typé : "Attente de salaire" (brut/net, avec les
--     mêmes retenues que le salaire normal appliquées au PAIEMENT, pas
--     à la création) + "Taxes secondaires" créées par le gouvernement
--     (montant taxé / montant non taxé, avec titre + description).
--  3. Répertoire des récompenses : RHPE (royale/excellence/base),
--     DRAEE, et AFT (formations tierces DFTN1/DFTN2).
--
-- HYPOTHÈSES (faute de précision, à ajuster vous-même si besoin) :
--  - Le formulaire de demande RHPE/DIDRAHE est long mais je l'ai gardé
--    structuré : les champs explicitement cités sont des colonnes
--    dédiées, et j'ai ajouté un sac `informations_supplementaires`
--    (jsonb) pour tout champ additionnel sérieux que vous voudrez
--    ajouter sans nouvelle migration SQL.
--  - Les "codes d'assurance sociaux" des gestionnaires AFT sont
--    comparés directement à citoyens.code_social_encrypte (la même
--    valeur que celle stockée à l'inscription).
--  - "Ne peut pas supprimer une personne qui a les pouvoirs" = ne peut
--    pas retirer une attribution AFT à un citoyen où est_admin = true.
--  - Les images de récompenses ne sont pas générées par moi : elles
--    doivent exister sur votre serveur sous assets/rhpe/[nom-fichier].png ;
--    j'ai choisi des noms de fichiers en kebab-case pour chaque type.
-- ============================================================


-- ============================================================
-- 1) CORRECTION : Grande-Capitale redevient indépendante
-- ============================================================
do $$
declare v_pop_marcio numeric; v_pop_gc numeric := 4012391;
begin
  if not exists (select 1 from banque_provinces where banque_tag = 'L' and province = 'Grande-Capitale') then
    select population into v_pop_marcio from banque_provinces where banque_tag = 'L' and province = 'Marcio';
    if v_pop_marcio is not null and v_pop_marcio >= v_pop_gc then
      update banque_provinces set population = population - v_pop_gc where banque_tag = 'L' and province = 'Marcio';
      insert into banque_provinces (banque_tag, province, population, part_pourcentage)
        values ('L', 'Grande-Capitale', v_pop_gc, 0)
        on conflict (banque_tag, province) do update set population = excluded.population;
    end if;
  end if;
end $$;

update banque_provinces bp set part_pourcentage = round(
  bp.population::numeric / nullif((select sum(population) from banque_provinces bp2 where bp2.banque_tag = bp.banque_tag), 0) * 100, 2
) where bp.banque_tag = 'L';


-- ============================================================
-- 2) ARGENT ATTENDU TYPÉ
-- ============================================================
alter table argent_attendu_log add column if not exists type text not null default 'salaire';
do $$ begin
  alter table argent_attendu_log add constraint argent_attendu_log_type_check check (type in ('salaire','taxe_secondaire'));
exception when duplicate_object then null;
end $$;
alter table argent_attendu_log add column if not exists montant_brut numeric;
update argent_attendu_log set montant_brut = coalesce(montant_brut, montant_initial) where montant_brut is null;
alter table argent_attendu_log add column if not exists titre text;
alter table argent_attendu_log add column if not exists description text;
alter table argent_attendu_log add column if not exists pct_tr numeric not null default 0;
alter table argent_attendu_log add column if not exists pct_te numeric not null default 0;
alter table argent_attendu_log add column if not exists pct_chomage numeric not null default 0;
alter table argent_attendu_log add column if not exists pct_retraite numeric not null default 0;
alter table argent_attendu_log add column if not exists pct_parentalite numeric not null default 0;
alter table argent_attendu_log add column if not exists cree_par uuid references auth.users(id);

-- Tente de payer un salaire immédiatement (banque de la province, puis
-- publique, puis privée) ; si le NET n'est pas disponible en entier, rien
-- n'est prélevé et le BRUT complet est différé comme "argent attendu" —
-- les retenues seront appliquées seulement au moment du paiement réel
-- (gouv_regler_argent_attendu), pas maintenant.
create or replace function gouv_payer_salaire_ou_differer(
  p_citoyen_id uuid, p_brut numeric, p_province text, p_pct_tr numeric, p_pct_te numeric
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_tr numeric; v_te numeric; v_cho numeric; v_ret numeric; v_par numeric; v_net numeric;
  v_banque_tag char(1); v_solde_banque numeric := 0; v_solde numeric; v_solde_prive numeric;
  v_disponible numeric; v_pris_banque numeric; v_pris_pub numeric; v_pris_priv numeric;
begin
  if p_brut is null or p_brut <= 0 then return jsonb_build_object('paye_immediatement', true, 'net', 0, 'brut', 0); end if;

  v_tr := p_brut * (p_pct_tr/100.0);
  v_te := p_brut * (p_pct_te/100.0);
  v_cho := p_brut * 0.0275;
  v_ret := p_brut * 0.0675;
  v_par := p_brut * 0.0025;
  v_net := p_brut - v_tr - v_te - v_cho - v_ret - v_par;

  if p_province is not null then
    select banque_tag into v_banque_tag from province_residence_banque where province = p_province;
    if v_banque_tag is not null then
      select tresorerie into v_solde_banque from banques_nationales where tag = v_banque_tag for update;
    end if;
  end if;
  select solde, solde_prive into v_solde, v_solde_prive from tresor_public where id = 1 for update;

  v_disponible := greatest(0, v_solde_banque) + greatest(0, v_solde) + greatest(0, v_solde_prive);

  if v_disponible < v_net then
    insert into argent_attendu_log (citoyen_id, type, montant_initial, montant_brut, montant_restant, pct_tr, pct_te, pct_chomage, pct_retraite, pct_parentalite)
      values (p_citoyen_id, 'salaire', p_brut, p_brut, p_brut, p_pct_tr, p_pct_te, 2.75, 6.75, 0.25);
    update citoyens set argent_attendu = argent_attendu + p_brut where id = p_citoyen_id;
    return jsonb_build_object('paye_immediatement', false, 'brut_differe', p_brut);
  end if;

  v_pris_banque := least(v_net, greatest(0, v_solde_banque));
  v_pris_pub := least(v_net - v_pris_banque, greatest(0, v_solde));
  v_pris_priv := v_net - v_pris_banque - v_pris_pub;

  if v_banque_tag is not null and v_pris_banque > 0 then
    update banques_nationales set tresorerie = tresorerie - v_pris_banque where tag = v_banque_tag;
  end if;
  update tresor_public set solde = solde - v_pris_pub, solde_prive = solde_prive - v_pris_priv where id = 1;

  update citoyens set
    tresorerie = tresorerie + v_net,
    compte_chomage = compte_chomage + v_cho,
    compte_retraite = compte_retraite + v_ret,
    compte_parentalite = compte_parentalite + v_par,
    taxes_gouv_60j = taxes_gouv_60j + v_tr,
    taxe_preventive_60j = taxe_preventive_60j + v_te
    where id = p_citoyen_id;
  update tresor_public set solde = solde + v_tr + v_te, taxes_totales_periode = taxes_totales_periode + v_tr + v_te where id = 1;

  return jsonb_build_object('paye_immediatement', true, 'net', v_net, 'brut', p_brut);
end; $$;
revoke all on function gouv_payer_salaire_ou_differer(uuid, numeric, text, numeric, numeric) from public;

-- Remplace deposer_revenu_citoyen pour utiliser gouv_payer_salaire_ou_differer
-- (même signature, logique de jour férié / période 60j inchangée).
create or replace function deposer_revenu_citoyen(p_minutes numeric default 1.0/60)
returns public.citoyens language plpgsql security definer set search_path = public as $$
declare
  v_citoyen public.citoyens; v_taux_preventif numeric; v_brut numeric; v_periode_60 int;
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
  perform gouv_payer_salaire_ou_differer(auth.uid(), v_brut, v_citoyen.province_residence, v_citoyen.taux_revenu, v_taux_preventif);

  update citoyens set derniere_synchro_tresorerie = now() where id = auth.uid() returning * into v_citoyen;
  perform gouv_distribuer_argent_attendu();
  return v_citoyen;
end;
$$;
grant execute on function deposer_revenu_citoyen(numeric) to authenticated;

-- Règle l'argent attendu en appliquant les retenues stockées sur chaque
-- entrée (0% pour les entrées non salariales/non taxées, ce qui couvre
-- automatiquement les anciens usages de gouv_payer_civil).
create or replace function gouv_regler_argent_attendu(
  p_citoyen_id uuid, p_treasorerie_preferee text default 'publique', p_plafond numeric default null
) returns numeric language plpgsql security definer set search_path = public as $$
declare
  v_du numeric; v_cible numeric; v_solde numeric; v_solde_prive numeric; v_home numeric; v_other numeric;
  v_pris_home numeric; v_pris_other numeric; v_disponible numeric; v_reste numeric; v_log record;
  v_paye_brut numeric; v_pris numeric; v_tr numeric; v_te numeric; v_cho numeric; v_ret numeric; v_par numeric; v_net numeric;
begin
  select argent_attendu into v_du from citoyens where id = p_citoyen_id for update;
  if v_du is null or v_du <= 0 then return 0; end if;
  v_cible := least(v_du, coalesce(p_plafond, v_du));
  if v_cible <= 0 then return 0; end if;

  select solde, solde_prive into v_solde, v_solde_prive from tresor_public where id = 1 for update;
  if p_treasorerie_preferee = 'privee' then v_home := v_solde_prive; v_other := v_solde;
  else v_home := v_solde; v_other := v_solde_prive; end if;
  v_disponible := greatest(0, v_home) + greatest(0, v_other);
  v_cible := least(v_cible, v_disponible);
  if v_cible <= 0 then return 0; end if;

  v_reste := v_cible;
  for v_log in select * from argent_attendu_log where citoyen_id = p_citoyen_id and montant_restant > 0 order by cree_le loop
    exit when v_reste <= 0;
    v_pris := least(v_reste, v_log.montant_restant);

    v_tr := v_pris * (v_log.pct_tr/100.0);
    v_te := v_pris * (v_log.pct_te/100.0);
    v_cho := v_pris * (v_log.pct_chomage/100.0);
    v_ret := v_pris * (v_log.pct_retraite/100.0);
    v_par := v_pris * (v_log.pct_parentalite/100.0);
    v_net := v_pris - v_tr - v_te - v_cho - v_ret - v_par;

    update citoyens set
      tresorerie = tresorerie + v_net,
      compte_chomage = compte_chomage + v_cho,
      compte_retraite = compte_retraite + v_ret,
      compte_parentalite = compte_parentalite + v_par
      where id = p_citoyen_id;
    if v_tr + v_te > 0 then
      update tresor_public set taxes_totales_periode = taxes_totales_periode + v_tr + v_te where id = 1;
    end if;

    update argent_attendu_log set montant_restant = montant_restant - v_pris where id = v_log.id;
    v_reste := v_reste - v_pris;
  end loop;
  delete from argent_attendu_log where citoyen_id = p_citoyen_id and montant_restant <= 0;

  v_paye_brut := v_cible - v_reste;
  if v_paye_brut <= 0 then return 0; end if;

  v_pris_home := least(v_paye_brut, greatest(0, v_home));
  v_pris_other := v_paye_brut - v_pris_home;
  if p_treasorerie_preferee = 'privee' then
    update tresor_public set solde_prive = solde_prive - v_pris_home, solde = solde - v_pris_other where id = 1;
  else
    update tresor_public set solde = solde - v_pris_home, solde_prive = solde_prive - v_pris_other where id = 1;
  end if;

  update citoyens set argent_attendu = argent_attendu - v_paye_brut where id = p_citoyen_id;
  return v_paye_brut;
end; $$;
revoke all on function gouv_regler_argent_attendu(uuid, text, numeric) from public;

-- Création d'une "taxe secondaire" par le gouvernement (montant taxé au
-- taux de revenu du citoyen et/ou montant non taxé, avec titre/description).
create or replace function gouv_creer_taxe_secondaire(
  p_username text, p_titre text, p_description text,
  p_montant_taxe numeric default 0, p_montant_non_taxe numeric default 0
) returns void language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_taux numeric;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if coalesce(p_montant_taxe,0) <= 0 and coalesce(p_montant_non_taxe,0) <= 0 then
    raise exception 'Indiquez au moins un montant.';
  end if;
  if p_titre is null or char_length(trim(p_titre)) = 0 then raise exception 'Un titre est requis.'; end if;
  select id, taux_revenu into v_id, v_taux from citoyens where lower(username) = lower(p_username);
  if v_id is null then raise exception 'Citoyen introuvable.'; end if;

  if coalesce(p_montant_taxe,0) > 0 then
    insert into argent_attendu_log (citoyen_id, type, montant_initial, montant_brut, montant_restant, titre, description, pct_tr, cree_par)
      values (v_id, 'taxe_secondaire', p_montant_taxe, p_montant_taxe, p_montant_taxe, p_titre, p_description, v_taux, auth.uid());
    update citoyens set argent_attendu = argent_attendu + p_montant_taxe where id = v_id;
  end if;
  if coalesce(p_montant_non_taxe,0) > 0 then
    insert into argent_attendu_log (citoyen_id, type, montant_initial, montant_brut, montant_restant, titre, description, cree_par)
      values (v_id, 'taxe_secondaire', p_montant_non_taxe, p_montant_non_taxe, p_montant_non_taxe, p_titre, p_description, auth.uid());
    update citoyens set argent_attendu = argent_attendu + p_montant_non_taxe where id = v_id;
  end if;
  perform gouv_distribuer_argent_attendu();
end; $$;
grant execute on function gouv_creer_taxe_secondaire(text,text,text,numeric,numeric) to authenticated;

-- Page "Argent attendu" du citoyen : attente de salaire (brut/net) +
-- liste des taxes secondaires.
create or replace function mes_argent_attendu()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_total numeric; v_nb_salaire int; v_brut_total numeric; v_net_total numeric; v_taxes jsonb;
begin
  select argent_attendu into v_total from citoyens where id = auth.uid();
  select count(*), coalesce(sum(montant_restant),0) into v_nb_salaire, v_brut_total
    from argent_attendu_log where citoyen_id = auth.uid() and type = 'salaire';
  select coalesce(sum(montant_restant - montant_restant*(pct_tr+pct_te+pct_chomage+pct_retraite+pct_parentalite)/100.0),0)
    into v_net_total from argent_attendu_log where citoyen_id = auth.uid() and type = 'salaire';

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id, 'titre', titre, 'description', description, 'montant', montant_restant,
    'taxe', pct_tr > 0, 'cree_le', cree_le
  ) order by cree_le desc), '[]'::jsonb) into v_taxes
  from argent_attendu_log where citoyen_id = auth.uid() and type = 'taxe_secondaire';

  return jsonb_build_object(
    'total', coalesce(v_total,0),
    'salaire', jsonb_build_object('nombre', v_nb_salaire, 'brut', v_brut_total, 'net', v_net_total),
    'taxes_secondaires', v_taxes
  );
end; $$;
grant execute on function mes_argent_attendu() to authenticated;


-- ============================================================
-- 3) RÉPERTOIRE DES RÉCOMPENSES — RHPE / DRAEE / AFT
-- ============================================================

create table if not exists recompenses_types (
  id           uuid primary key default gen_random_uuid(),
  nom          text not null unique,
  categorie    text not null check (categorie in ('rhpe_royale','rhpe_excellence','rhpe_base','draee')),
  longueur_code int not null,
  image        text,
  description  text,
  actif        boolean not null default true
);
alter table recompenses_types enable row level security;
drop policy if exists "Lecture publique des types de récompenses" on recompenses_types;
create policy "Lecture publique des types de récompenses" on recompenses_types for select using (true);

insert into recompenses_types (nom, categorie, longueur_code, image) values
  ('Médaille Dalma', 'rhpe_royale', 40, 'assets/rhpe/medaille-dalma.png'),
  ('Médaille d''honneur', 'rhpe_excellence', 20, 'assets/rhpe/medaille-dhonneur.png'),
  ('Médaille de sacrifice', 'rhpe_excellence', 20, 'assets/rhpe/medaille-de-sacrifice.png'),
  ('Médaille Laville', 'rhpe_base', 6, 'assets/rhpe/medaille-laville.png'),
  ('Médaille d''Expédition au Combat', 'rhpe_base', 6, 'assets/rhpe/medaille-dexpedition-au-combat.png'),
  ('Médaille honorifique', 'rhpe_base', 6, 'assets/rhpe/medaille-honorifique.png'),
  ('Diplôme d''études Scolaire', 'draee', 5, 'assets/rhpe/diplome-detudes-scolaire.png'),
  ('Diplôme d''étude Secondaire', 'draee', 5, 'assets/rhpe/diplome-detude-secondaire.png')
on conflict (nom) do nothing;

create table if not exists recompenses_demandes (
  id                     uuid primary key default gen_random_uuid(),
  type_id                uuid not null references recompenses_types(id),
  demandeur_id           uuid not null references auth.users(id),
  quand                  text, où text,
  nom_personne_affectee  text,
  nom_meritant           text not null,
  raison                 text not null,
  date_acte              date,
  heure_acte             text,
  promesse_fidelite      boolean not null default false,
  informations_supplementaires jsonb not null default '{}'::jsonb,
  statut                 text not null default 'en_attente' check (statut in ('en_attente','acceptee','refusee')),
  reponse                text,
  verifie_par_username   text,
  supervise_par_username text,
  numero_suivi_demande   text,
  cree_le                timestamptz not null default now(),
  traite_le              timestamptz
);
alter table recompenses_demandes enable row level security;
drop policy if exists "Un citoyen voit ses demandes de récompense" on recompenses_demandes;
create policy "Un citoyen voit ses demandes de récompense" on recompenses_demandes
  for select using (auth.uid() = demandeur_id or est_admin_actuel());

create table if not exists recompenses_attributions (
  id                   uuid primary key default gen_random_uuid(),
  type_id              uuid not null references recompenses_types(id),
  demande_id           uuid references recompenses_demandes(id),
  citoyen_id           uuid not null references auth.users(id),
  numero_suivi_meritas text not null unique,
  verifie_par_username   text,
  supervise_par_username text,
  donne_le             timestamptz not null default now()
);
alter table recompenses_attributions enable row level security;
drop policy if exists "Lecture publique de la vitrine des récompenses" on recompenses_attributions;
create policy "Lecture publique de la vitrine des récompenses" on recompenses_attributions for select using (true);

create or replace function _generer_code_alnum(p_longueur int)
returns text language sql as $$
  select upper(string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', (floor(random()*33)+1)::int, 1), ''))
  from generate_series(1, p_longueur);
$$;

create or replace function recompenses_demander(
  p_type_id uuid, p_quand text, p_ou text, p_nom_personne_affectee text, p_nom_meritant text,
  p_raison text, p_date_acte date, p_heure_acte text, p_promesse_fidelite boolean,
  p_informations_supplementaires jsonb default '{}'::jsonb
) returns public.recompenses_demandes language plpgsql security definer set search_path = public as $$
declare v_row public.recompenses_demandes;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if p_nom_meritant is null or p_raison is null then raise exception 'Nom du méritant et raison sont requis.'; end if;
  if not exists (select 1 from recompenses_types where id = p_type_id and actif) then raise exception 'Type de récompense invalide.'; end if;

  insert into recompenses_demandes (type_id, demandeur_id, quand, où, nom_personne_affectee, nom_meritant,
    raison, date_acte, heure_acte, promesse_fidelite, informations_supplementaires, numero_suivi_demande)
  values (p_type_id, auth.uid(), p_quand, p_ou, p_nom_personne_affectee, p_nom_meritant,
    p_raison, p_date_acte, p_heure_acte, coalesce(p_promesse_fidelite,false), coalesce(p_informations_supplementaires,'{}'::jsonb),
    'DEM-' || _generer_code_alnum(10))
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function recompenses_demander(uuid,text,text,text,text,text,date,text,boolean,jsonb) to authenticated;

create or replace function mes_demandes_recompenses()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', d.id, 'type', t.nom, 'categorie', t.categorie, 'statut', d.statut,
    'numero_suivi_demande', d.numero_suivi_demande, 'cree_le', d.cree_le, 'reponse', d.reponse
  ) order by d.cree_le desc), '[]'::jsonb)
  from recompenses_demandes d join recompenses_types t on t.id = d.type_id
  where d.demandeur_id = auth.uid();
$$;
grant execute on function mes_demandes_recompenses() to authenticated;

create or replace function gouv_liste_demandes_recompenses(p_statut text default 'en_attente')
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not est_admin_actuel() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
    'id', d.id, 'type', t.nom, 'categorie', t.categorie, 'demandeur_username', c.username,
    'nom_meritant', d.nom_meritant, 'raison', d.raison, 'quand', d.quand, 'où', d.où,
    'date_acte', d.date_acte, 'numero_suivi_demande', d.numero_suivi_demande, 'cree_le', d.cree_le
  ) order by d.cree_le), '[]'::jsonb) end
  from recompenses_demandes d
  join recompenses_types t on t.id = d.type_id
  join citoyens c on c.id = d.demandeur_id
  where d.statut = p_statut;
$$;
grant execute on function gouv_liste_demandes_recompenses(text) to authenticated;

create or replace function gouv_traiter_demande_recompense(
  p_demande_id uuid, p_decision text, p_reponse text,
  p_verifie_par_username text, p_supervise_par_username text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_demande public.recompenses_demandes; v_type public.recompenses_types; v_code text; v_attrib public.recompenses_attributions;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if p_decision not in ('acceptee','refusee') then raise exception 'Décision invalide.'; end if;

  select * into v_demande from recompenses_demandes where id = p_demande_id;
  if v_demande is null then raise exception 'Demande introuvable.'; end if;
  if v_demande.statut <> 'en_attente' then raise exception 'Cette demande a déjà été traitée.'; end if;

  update recompenses_demandes set statut = p_decision, reponse = p_reponse,
    verifie_par_username = p_verifie_par_username, supervise_par_username = p_supervise_par_username,
    traite_le = now()
    where id = p_demande_id returning * into v_demande;

  if p_decision = 'acceptee' then
    select * into v_type from recompenses_types where id = v_demande.type_id;
    v_code := v_type.categorie || '-' || _generer_code_alnum(v_type.longueur_code);
    insert into recompenses_attributions (type_id, demande_id, citoyen_id, numero_suivi_meritas, verifie_par_username, supervise_par_username)
      values (v_demande.type_id, v_demande.id, v_demande.demandeur_id, v_code, p_verifie_par_username, p_supervise_par_username)
      returning * into v_attrib;
    return jsonb_build_object('demande', to_jsonb(v_demande), 'attribution', to_jsonb(v_attrib));
  end if;
  return jsonb_build_object('demande', to_jsonb(v_demande));
end; $$;
grant execute on function gouv_traiter_demande_recompense(uuid,text,text,text,text) to authenticated;

create or replace function recompenses_vitrine(p_username text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_id uuid;
begin
  if p_username is null then v_id := auth.uid();
  else select id into v_id from citoyens where lower(username) = lower(p_username); end if;
  if v_id is null then return '[]'::jsonb; end if;

  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', a.id, 'type', t.nom, 'categorie', t.categorie, 'image', t.image,
    'numero_suivi_meritas', a.numero_suivi_meritas, 'donne_le', a.donne_le
  ) order by a.donne_le desc) from recompenses_attributions a join recompenses_types t on t.id = a.type_id where a.citoyen_id = v_id), '[]'::jsonb);
end; $$;
grant execute on function recompenses_vitrine(text) to authenticated, anon;

create or replace function recompenses_detail_attribution(p_attribution_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'attribution', jsonb_build_object(
      'numero_suivi_meritas', a.numero_suivi_meritas, 'donne_le', a.donne_le,
      'verifie_par', a.verifie_par_username, 'supervise_par', a.supervise_par_username,
      'type', t.nom, 'categorie', t.categorie, 'image', t.image
    ),
    'demande', case when d.id is null then null else jsonb_build_object(
      'numero_suivi_demande', d.numero_suivi_demande, 'quand', d.quand, 'où', d.où,
      'nom_personne_affectee', d.nom_personne_affectee, 'nom_meritant', d.nom_meritant,
      'raison', d.raison, 'date_acte', d.date_acte, 'heure_acte', d.heure_acte,
      'promesse_fidelite', d.promesse_fidelite, 'informations_supplementaires', d.informations_supplementaires,
      'reponse', d.reponse
    ) end
  )
  from recompenses_attributions a
  join recompenses_types t on t.id = a.type_id
  left join recompenses_demandes d on d.id = a.demande_id
  where a.id = p_attribution_id;
$$;
grant execute on function recompenses_detail_attribution(uuid) to authenticated, anon;

create or replace function recompenses_catalogue_complet()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id, 'nom', nom, 'categorie', categorie, 'image', image, 'description', description
  ) order by categorie, nom), '[]'::jsonb) from recompenses_types where actif;
$$;
grant execute on function recompenses_catalogue_complet() to authenticated, anon;


-- ------------------------------------------------------------
-- AFT — Autonomie aux Formations Tiers
-- ------------------------------------------------------------
create table if not exists aft_formations (
  id            uuid primary key default gen_random_uuid(),
  nom           text not null,
  niveau        text not null check (niveau in ('DFTN1','DFTN2')),
  gestionnaires uuid[] not null default '{}',
  justification text not null,
  statut        text not null default 'en_attente' check (statut in ('en_attente','acceptee','refusee')),
  demandeur_id  uuid not null references auth.users(id),
  cree_le       timestamptz not null default now(),
  traite_le     timestamptz
);
alter table aft_formations enable row level security;
drop policy if exists "Lecture publique des formations AFT" on aft_formations;
create policy "Lecture publique des formations AFT" on aft_formations for select using (statut = 'acceptee' or demandeur_id = auth.uid() or est_admin_actuel());

create table if not exists aft_attributions (
  id            uuid primary key default gen_random_uuid(),
  formation_id  uuid not null references aft_formations(id),
  citoyen_id    uuid not null references auth.users(id),
  code          text not null unique,
  note          numeric,
  justification text,
  date_debut    date,
  date_fin      date,
  attribue_par  uuid not null references auth.users(id),
  cree_le       timestamptz not null default now()
);
alter table aft_attributions enable row level security;
drop policy if exists "Lecture publique des attributions AFT" on aft_attributions;
create policy "Lecture publique des attributions AFT" on aft_attributions for select using (true);

create or replace function aft_demander_formation(
  p_nom text, p_niveau text, p_justification text, p_cas_gestionnaires text[]
) returns public.aft_formations language plpgsql security definer set search_path = public as $$
declare v_gestionnaires uuid[]; v_row public.aft_formations;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if p_niveau not in ('DFTN1','DFTN2') then raise exception 'Niveau invalide.'; end if;
  if p_justification is null or char_length(p_justification) < 100 then
    raise exception 'La justification doit compter au moins 100 caractères.';
  end if;
  select array_agg(id) into v_gestionnaires from citoyens where code_social_encrypte = any(p_cas_gestionnaires);
  if v_gestionnaires is null or array_length(v_gestionnaires,1) is null then
    raise exception 'Aucun code d''assurance social valide fourni pour les gestionnaires.';
  end if;

  insert into aft_formations (nom, niveau, gestionnaires, justification, demandeur_id)
    values (p_nom, p_niveau, v_gestionnaires, p_justification, auth.uid())
    returning * into v_row;
  return v_row;
end; $$;
grant execute on function aft_demander_formation(text,text,text,text[]) to authenticated;

create or replace function gouv_liste_demandes_aft(p_statut text default 'en_attente')
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not est_admin_actuel() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
    'id', f.id, 'nom', f.nom, 'niveau', f.niveau, 'justification', f.justification,
    'demandeur_username', c.username, 'cree_le', f.cree_le,
    'gestionnaires', (select jsonb_agg(g.username) from citoyens g where g.id = any(f.gestionnaires))
  ) order by f.cree_le), '[]'::jsonb) end
  from aft_formations f join citoyens c on c.id = f.demandeur_id
  where f.statut = p_statut;
$$;
grant execute on function gouv_liste_demandes_aft(text) to authenticated;

create or replace function gouv_traiter_demande_aft(p_formation_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if p_decision not in ('acceptee','refusee') then raise exception 'Décision invalide.'; end if;
  update aft_formations set statut = p_decision, traite_le = now()
    where id = p_formation_id and statut = 'en_attente';
end; $$;
grant execute on function gouv_traiter_demande_aft(uuid, text) to authenticated;

-- Formations gérées par le citoyen courant (gestionnaire désigné).
create or replace function mes_formations_aft_gerees()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nom', nom, 'niveau', niveau))
    order by nom, '[]'::jsonb) filter (where id is not null), '[]'::jsonb
  from aft_formations where auth.uid() = any(gestionnaires) and statut = 'acceptee';
$$;
grant execute on function mes_formations_aft_gerees() to authenticated;

create or replace function aft_attribuer(
  p_formation_id uuid, p_cas_destinataire text, p_note numeric, p_justification text,
  p_date_debut date, p_date_fin date
) returns public.aft_attributions language plpgsql security definer set search_path = public as $$
declare v_formation public.aft_formations; v_citoyen_id uuid; v_prefixe text; v_longueur int; v_code text; v_row public.aft_attributions;
begin
  select * into v_formation from aft_formations where id = p_formation_id;
  if v_formation is null or v_formation.statut <> 'acceptee' then raise exception 'Formation invalide ou non acceptée.'; end if;
  if not (auth.uid() = any(v_formation.gestionnaires) or est_admin_actuel()) then
    raise exception 'Accès refusé : vous ne gérez pas cette formation.';
  end if;
  select id into v_citoyen_id from citoyens where code_social_encrypte = p_cas_destinataire;
  if v_citoyen_id is null then raise exception 'Code d''assurance social introuvable.'; end if;

  if v_formation.niveau = 'DFTN1' then v_prefixe := 'DFTN1-'; v_longueur := 4;
  else v_prefixe := 'DFTN2-'; v_longueur := 5; end if;
  v_code := v_prefixe || _generer_code_alnum(v_longueur);

  insert into aft_attributions (formation_id, citoyen_id, code, note, justification, date_debut, date_fin, attribue_par)
    values (p_formation_id, v_citoyen_id, v_code, p_note, p_justification, p_date_debut, p_date_fin, auth.uid())
    returning * into v_row;
  return v_row;
end; $$;
grant execute on function aft_attribuer(uuid, text, numeric, text, date, date) to authenticated;

create or replace function aft_retirer_attribution(p_attribution_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_attrib public.aft_attributions; v_formation public.aft_formations; v_cible_admin boolean;
begin
  select * into v_attrib from aft_attributions where id = p_attribution_id;
  if v_attrib is null then raise exception 'Attribution introuvable.'; end if;
  select * into v_formation from aft_formations where id = v_attrib.formation_id;
  if not (auth.uid() = any(v_formation.gestionnaires) or est_admin_actuel()) then
    raise exception 'Accès refusé : vous ne gérez pas cette formation.';
  end if;
  select est_admin into v_cible_admin from citoyens where id = v_attrib.citoyen_id;
  if v_cible_admin then raise exception 'Impossible de retirer ce diplôme à un titulaire de pouvoirs.'; end if;
  delete from aft_attributions where id = p_attribution_id;
end; $$;
grant execute on function aft_retirer_attribution(uuid) to authenticated;

-- Tiroir AFT : toutes les formations acceptées, avec indication obtenue/non
create or replace function aft_tiroir(p_username text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_id uuid;
begin
  if p_username is null then v_id := auth.uid();
  else select id into v_id from citoyens where lower(username) = lower(p_username); end if;

  return coalesce((select jsonb_agg(jsonb_build_object(
    'formation_id', f.id, 'nom', f.nom, 'niveau', f.niveau,
    'obtenu', (a.id is not null),
    'code', a.code, 'note', a.note, 'date_debut', a.date_debut, 'date_fin', a.date_fin,
    'attribue_par_username', ac.username
  ) order by f.nom)
  from aft_formations f
  left join aft_attributions a on a.formation_id = f.id and a.citoyen_id = v_id
  left join citoyens ac on ac.id = a.attribue_par
  where f.statut = 'acceptee'), '[]'::jsonb);
end; $$;
grant execute on function aft_tiroir(text) to authenticated, anon;

create or replace function aft_liste_recus(p_formation_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_formation public.aft_formations;
begin
  select * into v_formation from aft_formations where id = p_formation_id;
  if v_formation is null then raise exception 'Formation introuvable.'; end if;
  if not (auth.uid() = any(v_formation.gestionnaires) or est_admin_actuel()) then
    raise exception 'Accès refusé.';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'attribution_id', a.id, 'username', c.username, 'nom_complet', c.prenom || ' ' || c.nom,
    'note', a.note, 'code', a.code, 'cree_le', a.cree_le
  ) order by a.cree_le desc) from aft_attributions a join citoyens c on c.id = a.citoyen_id where a.formation_id = p_formation_id), '[]'::jsonb);
end; $$;
grant execute on function aft_liste_recus(uuid) to authenticated;

-- ============================================================
-- FIN
-- ============================================================
