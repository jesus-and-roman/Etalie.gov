-- ============================================================
-- patch-cib-entreprise-avancee-16.sql
-- À exécuter après patch-cib-entreprise-avancee-15.sql. Additif et rejouable.
--
-- BUREAUX DE POSTE (secteur spécial d'entreprise).
--
-- HYPOTHÈSES (voir aussi les totaux de l'exemple chiffré fourni) :
--  - Le "prix du carburant actuel" est un réglage GOUVERNEMENTAL unique
--    (parametres_fiscaux.prix_carburant_km), pas par bureau de poste.
--  - D'après l'exemple chiffré donné (500 km, 2,3293 R$/km carburant,
--    3,3 R$/km facturé, 0,09 %/0,02 % livreur/analyste) : l'entreprise
--    vendeuse paie distance × taux_affiliation au bureau de poste
--    (1650 R$) ; le bureau absorbe le coût carburant (1164,65 R$, versé
--    à la trésorerie PUBLIQUE du gouvernement — le carburant est acheté
--    à l'État) ; sur la MARGE restante (485,35 R$), les pourcentages
--    livreur/analyste sont prélevés (0,43695 R$ / 0,0971 R$) ; le reste
--    (484,96595 R$) va à la trésorerie du bureau de poste. C'est la
--    seule lecture qui retombe exactement sur tous les chiffres donnés.
--  - "Combien de km/m parcourus" : je calcule la distance comme un
--    simple nombre saisi par l'analyste (pas de vraie carte/GPS).
--  - Localisation des livreurs : un champ texte libre (nom du bureau de
--    poste où ils se trouvent), pas un système de succursales distinct.
-- ============================================================

alter table entreprises add column if not exists secteur text not null default 'normale' check (secteur in ('normale','bureau_poste'));
alter table entreprises add column if not exists pourcentage_livreurs numeric not null default 0;
alter table entreprises add column if not exists pourcentage_analystes numeric not null default 0;
alter table parametres_fiscaux add column if not exists prix_carburant_km numeric not null default 2.3293;

create or replace function gouv_definir_prix_carburant(p_prix numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  if p_prix < 0 then raise exception 'Prix invalide.'; end if;
  update parametres_fiscaux set prix_carburant_km = p_prix where id = 1;
end; $$;
grant execute on function gouv_definir_prix_carburant(numeric) to authenticated;

-- Permet de définir le secteur à la création (en plus de l'appel existant sans secteur).
create or replace function entreprise_demander(
  p_nom text, p_depenses numeric, p_achats numeric,
  p_type_vente text, p_mode_vente text, p_boutique_principale text, p_boutiques_secondaires text,
  p_sieges text, p_fondateur_cas text, p_employes jsonb default '[]'::jsonb, p_secteur text default 'normale'
) returns public.entreprises language plpgsql security definer set search_path = public as $$
declare v_row public.entreprises; v_emp jsonb; v_emp_id uuid; v_mode text; v_statut text;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if p_nom is null or char_length(trim(p_nom)) = 0 then raise exception 'Nom d''entreprise requis.'; end if;
  if p_sieges is null or char_length(trim(p_sieges)) = 0 then raise exception 'Au moins un siège physique est requis.'; end if;
  if p_secteur not in ('normale','bureau_poste') then raise exception 'Secteur invalide.'; end if;

  select mode_creation_entreprise into v_mode from parametres_fiscaux where id = 1;
  v_statut := case when v_mode = 'liberte' then 'acceptee' else 'en_attente' end;

  insert into entreprises (code, nom, depenses_an_dernier, achats_an_dernier, type_vente, mode_vente,
    boutique_principale, boutiques_secondaires, sieges, fondateur_id, fondateur_cas, statut, secteur)
  values ('E-' || _generer_code_alnum(8), p_nom, p_depenses, p_achats, p_type_vente, p_mode_vente,
    p_boutique_principale, p_boutiques_secondaires, p_sieges, auth.uid(), p_fondateur_cas, v_statut, p_secteur)
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
grant execute on function entreprise_demander(text,numeric,numeric,text,text,text,text,text,text,jsonb,text) to authenticated;


-- ============================================================
-- 1) PERSONNEL DU BUREAU DE POSTE (livreurs / managers / analystes)
-- ============================================================
alter table entreprises_membres add column if not exists poste_bureau text check (poste_bureau in ('livreur','manager','analyste'));
alter table entreprises_membres add column if not exists localisation_actuelle text;

create or replace function bureau_poste_assigner_poste(p_entreprise_id uuid, p_citoyen_id uuid, p_poste text)
returns void language plpgsql security definer set search_path = public as $$
declare v_role text; v_secteur text;
begin
  select secteur into v_secteur from entreprises where id = p_entreprise_id;
  if v_secteur <> 'bureau_poste' then raise exception 'Réservé aux bureaux de poste.'; end if;
  select role into v_role from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_role is distinct from 'pdg' then raise exception 'Réservé au PDG.'; end if;
  if p_poste is not null and p_poste not in ('livreur','manager','analyste') then raise exception 'Poste invalide.'; end if;
  update entreprises_membres set poste_bureau = p_poste where entreprise_id = p_entreprise_id and citoyen_id = p_citoyen_id;
  if not found then raise exception 'Membre introuvable.'; end if;
end; $$;
grant execute on function bureau_poste_assigner_poste(uuid, uuid, text) to authenticated;

create or replace function bureau_poste_maj_localisation(p_entreprise_id uuid, p_localisation text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update entreprises_membres set localisation_actuelle = p_localisation
    where entreprise_id = p_entreprise_id and citoyen_id = auth.uid() and poste_bureau = 'livreur';
  if not found then raise exception 'Réservé aux livreurs de ce bureau de poste.'; end if;
end; $$;
grant execute on function bureau_poste_maj_localisation(uuid, text) to authenticated;


-- ============================================================
-- 2) AFFILIATION TEMPORAIRE (vendeur <-> bureau de poste)
-- ============================================================
create table if not exists bureau_poste_affiliations (
  id                 uuid primary key default gen_random_uuid(),
  bureau_poste_id    uuid not null references entreprises(id) on delete cascade,
  cible_type         text not null check (cible_type in ('entreprise','annonce')),
  entreprise_cible_id uuid references entreprises(id),
  annonce_id         uuid references marche_annonces(id),
  demandeur_id       uuid not null references auth.users(id),
  justification      text not null,
  duree_jours        numeric not null check (duree_jours > 0),
  unite              text not null check (unite in ('km','m')),
  prix_par_unite     numeric not null check (prix_par_unite >= 0),
  statut             text not null default 'en_attente' check (statut in ('en_attente','acceptee','refusee','dissociee','expiree')),
  code               text unique,
  code_expire_le     timestamptz,
  cree_le            timestamptz not null default now(),
  check ((cible_type = 'entreprise' and entreprise_cible_id is not null) or (cible_type = 'annonce' and annonce_id is not null))
);
alter table bureau_poste_affiliations enable row level security;
drop policy if exists "Voir ses affiliations (bureau de poste ou cible) ou tout si admin" on bureau_poste_affiliations;
create policy "Voir ses affiliations (bureau de poste ou cible) ou tout si admin" on bureau_poste_affiliations for select
  using (demandeur_id = auth.uid() or est_admin_actuel()
    or exists (select 1 from entreprises_membres m where m.entreprise_id = bureau_poste_affiliations.bureau_poste_id and m.citoyen_id = auth.uid())
    or exists (select 1 from entreprises_membres m where m.entreprise_id = bureau_poste_affiliations.entreprise_cible_id and m.citoyen_id = auth.uid()));

create or replace function bureau_poste_demander_affiliation(
  p_bureau_poste_id uuid, p_cible_type text, p_cible_id uuid, p_justification text,
  p_duree_jours numeric, p_unite text, p_prix_par_unite numeric
) returns bureau_poste_affiliations language plpgsql security definer set search_path = public as $$
declare v_row bureau_poste_affiliations; v_role text;
begin
  if (select secteur from entreprises where id = p_bureau_poste_id) <> 'bureau_poste' then raise exception 'Ce n''est pas un bureau de poste.'; end if;
  if p_cible_type not in ('entreprise','annonce') then raise exception 'Cible invalide.'; end if;
  if p_cible_type = 'entreprise' then
    select role into v_role from entreprises_membres where entreprise_id = p_cible_id and citoyen_id = auth.uid();
    if v_role not in ('pdg','co_pdg') then raise exception 'Réservé au PDG ou à un Co-PDG de l''entreprise.'; end if;
  else
    if not exists (select 1 from marche_annonces where id = p_cible_id and vendeur_id = auth.uid()) then
      raise exception 'Cette annonce ne vous appartient pas.';
    end if;
  end if;
  if p_justification is null or char_length(trim(p_justification)) < 10 then raise exception 'Justification requise (10 caractères minimum).'; end if;
  if p_unite not in ('km','m') then raise exception 'Unité invalide.'; end if;

  insert into bureau_poste_affiliations (bureau_poste_id, cible_type, entreprise_cible_id, annonce_id, demandeur_id, justification, duree_jours, unite, prix_par_unite)
  values (p_bureau_poste_id, p_cible_type, case when p_cible_type = 'entreprise' then p_cible_id end, case when p_cible_type = 'annonce' then p_cible_id end,
    auth.uid(), trim(p_justification), p_duree_jours, p_unite, p_prix_par_unite)
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function bureau_poste_demander_affiliation(uuid, text, uuid, text, numeric, text, numeric) to authenticated;

create or replace function _generer_code_affiliation()
returns text language sql as $$
  select 'AFF-' || upper(_generer_code_alnum(10));
$$;

create or replace function bureau_poste_traiter_affiliation(p_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
declare a bureau_poste_affiliations; v_role text;
begin
  select * into a from bureau_poste_affiliations where id = p_id and statut = 'en_attente';
  if a.id is null then raise exception 'Demande introuvable ou déjà traitée.'; end if;
  select role into v_role from entreprises_membres where entreprise_id = a.bureau_poste_id and citoyen_id = auth.uid();
  if v_role not in ('pdg','manager') and not (select poste_bureau = 'manager' from entreprises_membres where entreprise_id = a.bureau_poste_id and citoyen_id = auth.uid()) then
    if v_role <> 'pdg' then raise exception 'Réservé au PDG ou à un manager du bureau de poste.'; end if;
  end if;
  if p_decision not in ('acceptee','refusee') then raise exception 'Décision invalide.'; end if;
  if p_decision = 'refusee' then
    update bureau_poste_affiliations set statut = 'refusee' where id = p_id;
    return;
  end if;
  update bureau_poste_affiliations set statut = 'acceptee', code = _generer_code_affiliation(), code_expire_le = now() + (a.duree_jours || ' days')::interval
    where id = p_id;
end; $$;
grant execute on function bureau_poste_traiter_affiliation(uuid, text) to authenticated;

create or replace function bureau_poste_renouveler_affiliation(p_id uuid, p_justification text, p_duree_jours numeric)
returns bureau_poste_affiliations language plpgsql security definer set search_path = public as $$
declare a bureau_poste_affiliations; v_row bureau_poste_affiliations;
begin
  select * into a from bureau_poste_affiliations where id = p_id and demandeur_id = auth.uid();
  if a.id is null then raise exception 'Affiliation introuvable.'; end if;
  insert into bureau_poste_affiliations (bureau_poste_id, cible_type, entreprise_cible_id, annonce_id, demandeur_id, justification, duree_jours, unite, prix_par_unite)
  values (a.bureau_poste_id, a.cible_type, a.entreprise_cible_id, a.annonce_id, auth.uid(), coalesce(p_justification, a.justification), p_duree_jours, a.unite, a.prix_par_unite)
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function bureau_poste_renouveler_affiliation(uuid, text, numeric) to authenticated;

-- Dissociation par n'importe quelle des deux parties, à tout moment.
create or replace function bureau_poste_dissocier(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a bureau_poste_affiliations; v_est_bureau boolean; v_est_cible boolean;
begin
  select * into a from bureau_poste_affiliations where id = p_id and statut = 'acceptee';
  if a.id is null then raise exception 'Affiliation introuvable ou non active.'; end if;
  v_est_bureau := exists (select 1 from entreprises_membres where entreprise_id = a.bureau_poste_id and citoyen_id = auth.uid() and role in ('pdg','co_pdg'));
  v_est_cible := a.demandeur_id = auth.uid()
    or (a.entreprise_cible_id is not null and exists (select 1 from entreprises_membres where entreprise_id = a.entreprise_cible_id and citoyen_id = auth.uid() and role in ('pdg','co_pdg')));
  if not (v_est_bureau or v_est_cible) then raise exception 'Accès refusé.'; end if;
  update bureau_poste_affiliations set statut = 'dissociee' where id = p_id;
end; $$;
grant execute on function bureau_poste_dissocier(uuid) to authenticated;

-- Modification des conditions (unité, prix) : demande + accord de l'autre partie.
create table if not exists bureau_poste_modif_conditions (
  id             uuid primary key default gen_random_uuid(),
  affiliation_id uuid not null references bureau_poste_affiliations(id) on delete cascade,
  demandeur_id   uuid not null references auth.users(id),
  nouvelle_unite text not null check (nouvelle_unite in ('km','m')),
  nouveau_prix   numeric not null check (nouveau_prix >= 0),
  statut         text not null default 'en_attente' check (statut in ('en_attente','acceptee','refusee')),
  cree_le        timestamptz not null default now()
);
alter table bureau_poste_modif_conditions enable row level security;
drop policy if exists "Voir les modifications de conditions de son affiliation" on bureau_poste_modif_conditions;
create policy "Voir les modifications de conditions de son affiliation" on bureau_poste_modif_conditions for select
  using (est_admin_actuel() or exists (
    select 1 from bureau_poste_affiliations a where a.id = bureau_poste_modif_conditions.affiliation_id
    and (a.demandeur_id = auth.uid()
      or exists (select 1 from entreprises_membres m where m.entreprise_id = a.bureau_poste_id and m.citoyen_id = auth.uid())
      or exists (select 1 from entreprises_membres m where m.entreprise_id = a.entreprise_cible_id and m.citoyen_id = auth.uid()))
  ));

create or replace function bureau_poste_demander_modif_conditions(p_affiliation_id uuid, p_unite text, p_prix numeric)
returns void language plpgsql security definer set search_path = public as $$
declare a bureau_poste_affiliations; v_role text;
begin
  select * into a from bureau_poste_affiliations where id = p_affiliation_id and statut = 'acceptee';
  if a.id is null then raise exception 'Affiliation introuvable ou non active.'; end if;
  select role into v_role from entreprises_membres where entreprise_id = a.bureau_poste_id and citoyen_id = auth.uid();
  if v_role is distinct from 'pdg' then raise exception 'Réservé au PDG du bureau de poste.'; end if;
  insert into bureau_poste_modif_conditions (affiliation_id, demandeur_id, nouvelle_unite, nouveau_prix) values (p_affiliation_id, auth.uid(), p_unite, p_prix);
end; $$;
grant execute on function bureau_poste_demander_modif_conditions(uuid, text, numeric) to authenticated;

create or replace function bureau_poste_repondre_modif_conditions(p_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
declare mc bureau_poste_modif_conditions; a bureau_poste_affiliations; v_autorise boolean;
begin
  select * into mc from bureau_poste_modif_conditions where id = p_id and statut = 'en_attente';
  if mc.id is null then raise exception 'Demande introuvable ou déjà traitée.'; end if;
  select * into a from bureau_poste_affiliations where id = mc.affiliation_id;
  v_autorise := a.demandeur_id = auth.uid()
    or (a.entreprise_cible_id is not null and exists (select 1 from entreprises_membres where entreprise_id = a.entreprise_cible_id and citoyen_id = auth.uid() and role in ('pdg','co_pdg')));
  if not v_autorise then raise exception 'Réservé à l''entreprise/au vendeur affilié.'; end if;
  if p_decision not in ('acceptee','refusee') then raise exception 'Décision invalide.'; end if;
  update bureau_poste_modif_conditions set statut = p_decision where id = p_id;
  if p_decision = 'acceptee' then
    update bureau_poste_affiliations set unite = mc.nouvelle_unite, prix_par_unite = mc.nouveau_prix where id = a.id;
  end if;
end; $$;
grant execute on function bureau_poste_repondre_modif_conditions(uuid, text) to authenticated;


-- ============================================================
-- 3) SUIVI DE COLIS + FACTURATION DE LA LIVRAISON
-- ============================================================
alter table marche_achats add column if not exists bureau_poste_id uuid references entreprises(id);
alter table marche_achats add column if not exists etape_bureau_poste text check (etape_bureau_poste in ('recu_bureau','parti_bureau','en_main_livreur','livre'));
alter table marche_achats add column if not exists livreur_id uuid references auth.users(id);
alter table marche_achats add column if not exists analyste_id uuid references auth.users(id);
alter table marche_achats add column if not exists distance_parcourue numeric;
alter table marche_achats add column if not exists prix_livraison_facture numeric;
alter table marche_achats add column if not exists livraison_delai_analyse timestamptz;
alter table marche_achats add column if not exists livraison_facturee boolean not null default false;
alter table marche_achats add column if not exists note_livreur_rapidite numeric;
alter table marche_achats add column if not exists note_livreur_etat numeric;

create or replace function bureau_poste_assigner_livraison(p_achat_id uuid, p_livreur_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m marche_achats; v_role text; v_poste text;
begin
  select * into m from marche_achats where id = p_achat_id;
  if m.id is null or m.bureau_poste_id is null then raise exception 'Achat introuvable ou non assigné à un bureau de poste.'; end if;
  select role, poste_bureau into v_role, v_poste from entreprises_membres where entreprise_id = m.bureau_poste_id and citoyen_id = auth.uid();
  if v_role is distinct from 'pdg' and v_poste is distinct from 'manager' then raise exception 'Réservé au PDG ou à un manager.'; end if;
  if not exists (select 1 from entreprises_membres where entreprise_id = m.bureau_poste_id and citoyen_id = p_livreur_id and poste_bureau = 'livreur') then
    raise exception 'Ce citoyen n''est pas livreur de ce bureau de poste.';
  end if;
  update marche_achats set livreur_id = p_livreur_id where id = p_achat_id;
end; $$;
grant execute on function bureau_poste_assigner_livraison(uuid, uuid) to authenticated;

create or replace function bureau_poste_maj_etape(p_achat_id uuid, p_etape text)
returns void language plpgsql security definer set search_path = public as $$
declare m marche_achats; v_ordre text[] := array['recu_bureau','parti_bureau','en_main_livreur','livre'];
begin
  if p_etape not in ('recu_bureau','parti_bureau','en_main_livreur','livre') then raise exception 'Étape invalide.'; end if;
  select * into m from marche_achats where id = p_achat_id;
  if m.id is null or m.bureau_poste_id is null then raise exception 'Achat introuvable ou non assigné à un bureau de poste.'; end if;
  if not exists (select 1 from entreprises_membres where entreprise_id = m.bureau_poste_id and citoyen_id = auth.uid()
      and (role = 'pdg' or poste_bureau in ('manager','livreur'))) then
    raise exception 'Accès refusé.';
  end if;
  update marche_achats set etape_bureau_poste = p_etape where id = p_achat_id;
end; $$;
grant execute on function bureau_poste_maj_etape(uuid, text) to authenticated;

-- Analyse (facultative) : prix de la livraison estimé par un analyste, jusqu'à 60 jours après réception.
create or replace function bureau_poste_analyser_livraison(p_achat_id uuid, p_distance numeric)
returns void language plpgsql security definer set search_path = public as $$
declare m marche_achats; v_poste text; a bureau_poste_affiliations; v_taux numeric; v_prix_carburant numeric;
  v_montant_facture numeric; v_cout_carburant numeric; v_marge numeric; v_part_livreur numeric; v_part_analyste numeric; v_reste numeric;
begin
  select * into m from marche_achats where id = p_achat_id;
  if m.id is null or m.bureau_poste_id is null then raise exception 'Achat introuvable ou non assigné à un bureau de poste.'; end if;
  if m.statut_livraison <> 'recu' then raise exception 'La livraison doit d''abord être marquée reçue par l''acheteur.'; end if;
  if m.livraison_facturee then raise exception 'Cette livraison a déjà été facturée.'; end if;
  if m.livraison_delai_analyse is not null and now() > m.livraison_delai_analyse then raise exception 'Le délai de 60 jours pour facturer est dépassé.'; end if;
  select poste_bureau into v_poste from entreprises_membres where entreprise_id = m.bureau_poste_id and citoyen_id = auth.uid();
  if v_poste is distinct from 'analyste' then raise exception 'Réservé aux analystes de ce bureau de poste.'; end if;
  if p_distance <= 0 then raise exception 'Distance invalide.'; end if;

  select * into a from bureau_poste_affiliations where bureau_poste_id = m.bureau_poste_id and statut in ('acceptee','dissociee','expiree')
    and (annonce_id = m.annonce_id or entreprise_cible_id = m.entreprise_vendeuse_id) order by cree_le desc limit 1;
  v_taux := coalesce(a.prix_par_unite, 0);
  select prix_carburant_km into v_prix_carburant from parametres_fiscaux where id = 1;

  v_montant_facture := round(p_distance * v_taux, 5);
  v_cout_carburant := round(p_distance * v_prix_carburant, 5);
  v_marge := v_montant_facture - v_cout_carburant;

  select pourcentage_livreurs, pourcentage_analystes into v_part_livreur, v_part_analyste from entreprises where id = m.bureau_poste_id;
  v_part_livreur := round(v_marge * coalesce(v_part_livreur, 0) / 100.0, 5);
  v_part_analyste := round(v_marge * coalesce(v_part_analyste, 0) / 100.0, 5);
  v_reste := v_marge - v_part_livreur - v_part_analyste;

  -- Facture le vendeur (ou son entreprise) pour la livraison ; l'argent ajoute à son dû.
  if m.entreprise_vendeuse_id is not null then
    if (select tresorerie from entreprises where id = m.entreprise_vendeuse_id) >= v_montant_facture then
      update entreprises set tresorerie = tresorerie - v_montant_facture where id = m.entreprise_vendeuse_id;
    else
      update entreprises set tresorerie = tresorerie - v_montant_facture, dette_salariale_employes = dette_salariale_employes + v_montant_facture where id = m.entreprise_vendeuse_id;
    end if;
  else
    if (select tresorerie from citoyens where id = m.vendeur_id) >= v_montant_facture then
      update citoyens set tresorerie = tresorerie - v_montant_facture where id = m.vendeur_id;
    else
      update citoyens set tresorerie = tresorerie - v_montant_facture, argent_attendu = argent_attendu + v_montant_facture where id = m.vendeur_id;
      insert into argent_attendu_detail (citoyen_id, montant, description) values (m.vendeur_id, v_montant_facture, 'Frais de livraison — ' || m.titre);
    end if;
  end if;

  update tresor_public set solde = solde + v_cout_carburant where id = 1;
  if m.livreur_id is not null then update citoyens set tresorerie = tresorerie + v_part_livreur where id = m.livreur_id; end if;
  update citoyens set tresorerie = tresorerie + v_part_analyste where id = auth.uid();
  update entreprises set tresorerie = tresorerie + v_reste where id = m.bureau_poste_id;

  update marche_achats set analyste_id = auth.uid(), distance_parcourue = p_distance, prix_livraison_facture = v_montant_facture, livraison_facturee = true where id = p_achat_id;
end; $$;
grant execute on function bureau_poste_analyser_livraison(uuid, numeric) to authenticated;

-- Fixe le délai de 60 jours au moment où l'acheteur marque "reçu".
create or replace function marche_marquer_recu(p_achat_id uuid, p_rapidite numeric, p_aide numeric, p_gentillesse numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_rapidite not in (0.5,1,1.5,2,2.5,3,3.5,4,4.5,5) or p_aide not in (0.5,1,1.5,2,2.5,3,3.5,4,4.5,5) or p_gentillesse not in (0.5,1,1.5,2,2.5,3,3.5,4,4.5,5) then
    raise exception 'Notes invalides (0,5 à 5 par demi-étoile).';
  end if;
  update marche_achats set statut_livraison = 'recu', note_rapidite = p_rapidite, note_aide = p_aide, note_gentillesse = p_gentillesse,
    livraison_delai_analyse = now() + interval '60 days'
    where id = p_achat_id and acheteur_id = auth.uid() and statut_livraison in ('en_preparation','expedie');
  if not found then raise exception 'Achat introuvable ou déjà traité.'; end if;
end; $$;
grant execute on function marche_marquer_recu(uuid, numeric, numeric, numeric) to authenticated;

-- Note séparée pour le livreur (rapidité 30 %, objet non abîmé 70 %), modifiable.
create or replace function marche_noter_livreur(p_achat_id uuid, p_rapidite numeric, p_etat numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_rapidite not in (0.5,1,1.5,2,2.5,3,3.5,4,4.5,5) or p_etat not in (0.5,1,1.5,2,2.5,3,3.5,4,4.5,5) then
    raise exception 'Notes invalides (0,5 à 5 par demi-étoile).';
  end if;
  update marche_achats set note_livreur_rapidite = p_rapidite, note_livreur_etat = p_etat
    where id = p_achat_id and acheteur_id = auth.uid() and livreur_id is not null;
  if not found then raise exception 'Achat introuvable, ou aucun livreur assigné.'; end if;
end; $$;
grant execute on function marche_noter_livreur(uuid, numeric, numeric) to authenticated;

create or replace function note_moyenne_livreur(p_livreur_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when count(*) = 0 then jsonb_build_object('note', null, 'nb_avis', 0) else jsonb_build_object(
    'note', round(avg(note_livreur_etat) * 0.70 + avg(note_livreur_rapidite) * 0.30, 2), 'nb_avis', count(*)
  ) end
  from marche_achats where livreur_id = p_livreur_id and note_livreur_etat is not null;
$$;
grant execute on function note_moyenne_livreur(uuid) to authenticated, anon;

-- Note de l'entreprise de livraison : moyenne des notes de tous ses livreurs.
create or replace function note_moyenne_bureau_poste(p_bureau_poste_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when count(*) = 0 then jsonb_build_object('note', null, 'nb_avis', 0) else jsonb_build_object(
    'note', round(avg(m.note_livreur_etat) * 0.70 + avg(m.note_livreur_rapidite) * 0.30, 2), 'nb_avis', count(*)
  ) end
  from marche_achats m join entreprises_membres em on em.citoyen_id = m.livreur_id
  where em.entreprise_id = p_bureau_poste_id and m.note_livreur_etat is not null;
$$;
grant execute on function note_moyenne_bureau_poste(uuid) to authenticated, anon;


-- ============================================================
-- 4) VOTE DES LIVREURS/ANALYSTES SUR LEUR POURCENTAGE
-- ============================================================
create table if not exists bureau_poste_votes (
  id                 uuid primary key default gen_random_uuid(),
  bureau_poste_id    uuid not null references entreprises(id) on delete cascade,
  poste              text not null check (poste in ('livreur','analyste')),
  nouveau_pourcentage numeric not null check (nouveau_pourcentage >= 0),
  statut             text not null default 'en_cours' check (statut in ('en_cours','acceptee','refusee')),
  cree_le            timestamptz not null default now(),
  expire_le          timestamptz not null default (now() + interval '7 days')
);
alter table bureau_poste_votes enable row level security;
drop policy if exists "Voir les votes de son bureau de poste" on bureau_poste_votes;
create policy "Voir les votes de son bureau de poste" on bureau_poste_votes for select
  using (est_admin_actuel() or exists (select 1 from entreprises_membres m where m.entreprise_id = bureau_poste_votes.bureau_poste_id and m.citoyen_id = auth.uid()));

create table if not exists bureau_poste_votes_reponses (
  vote_id    uuid not null references bureau_poste_votes(id) on delete cascade,
  citoyen_id uuid not null references auth.users(id),
  choix      boolean not null,
  cree_le    timestamptz not null default now(),
  primary key (vote_id, citoyen_id)
);
alter table bureau_poste_votes_reponses enable row level security;
drop policy if exists "Voir les réponses des votes de son bureau de poste" on bureau_poste_votes_reponses;
create policy "Voir les réponses des votes de son bureau de poste" on bureau_poste_votes_reponses for select
  using (est_admin_actuel() or exists (select 1 from bureau_poste_votes v join entreprises_membres m on m.entreprise_id = v.bureau_poste_id
    where v.id = bureau_poste_votes_reponses.vote_id and m.citoyen_id = auth.uid()));

create or replace function bureau_poste_proposer_pourcentage(p_entreprise_id uuid, p_poste text, p_nouveau_pourcentage numeric)
returns bureau_poste_votes language plpgsql security definer set search_path = public as $$
declare v_role text; v_row bureau_poste_votes;
begin
  select role into v_role from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_role is distinct from 'pdg' then raise exception 'Réservé au PDG.'; end if;
  if p_poste not in ('livreur','analyste') then raise exception 'Poste invalide.'; end if;
  if p_nouveau_pourcentage < 0 then raise exception 'Pourcentage invalide.'; end if;
  if exists (select 1 from bureau_poste_votes where bureau_poste_id = p_entreprise_id and poste = p_poste and statut = 'en_cours') then
    raise exception 'Un vote est déjà en cours pour ce poste.';
  end if;
  insert into bureau_poste_votes (bureau_poste_id, poste, nouveau_pourcentage) values (p_entreprise_id, p_poste, p_nouveau_pourcentage) returning * into v_row;
  return v_row;
end; $$;
grant execute on function bureau_poste_proposer_pourcentage(uuid, text, numeric) to authenticated;

create or replace function bureau_poste_voter(p_vote_id uuid, p_choix boolean)
returns void language plpgsql security definer set search_path = public as $$
declare vote_v bureau_poste_votes; v_poste text;
begin
  select * into vote_v from bureau_poste_votes where id = p_vote_id and statut = 'en_cours';
  if vote_v.id is null then raise exception 'Vote introuvable ou terminé.'; end if;
  if now() > vote_v.expire_le then raise exception 'Le délai de vote est terminé.'; end if;
  select poste_bureau into v_poste from entreprises_membres where entreprise_id = vote_v.bureau_poste_id and citoyen_id = auth.uid();
  if v_poste is distinct from vote_v.poste then raise exception 'Seuls les % de ce bureau de poste peuvent voter.', vote_v.poste; end if;
  insert into bureau_poste_votes_reponses (vote_id, citoyen_id, choix) values (p_vote_id, auth.uid(), p_choix)
    on conflict (vote_id, citoyen_id) do update set choix = p_choix;
end; $$;
grant execute on function bureau_poste_voter(uuid, boolean) to authenticated;

-- Clôture les votes expirés (appelé en rattrapage, comme les autres cycles du site).
create or replace function bureau_poste_cloturer_votes_expires()
returns int language plpgsql security definer set search_path = public as $$
declare v record; v_oui int; v_non int; v_n int := 0;
begin
  for v in select * from bureau_poste_votes where statut = 'en_cours' and expire_le < now() loop
    select count(*) filter (where choix), count(*) filter (where not choix) into v_oui, v_non from bureau_poste_votes_reponses where vote_id = v.id;
    if v_oui > v_non then
      update bureau_poste_votes set statut = 'acceptee' where id = v.id;
      if v.poste = 'livreur' then update entreprises set pourcentage_livreurs = v.nouveau_pourcentage where id = v.bureau_poste_id;
      else update entreprises set pourcentage_analystes = v.nouveau_pourcentage where id = v.bureau_poste_id; end if;
    else
      update bureau_poste_votes set statut = 'refusee' where id = v.id;
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end; $$;
grant execute on function bureau_poste_cloturer_votes_expires() to authenticated;

-- Rattrapé au passage à chaque connexion (déjà appelé par enregistrer_mon_cib).
create or replace function enregistrer_mon_cib(p_cib_fichier text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_code text; v_actuel text; v_force text;
begin
  perform citoyens_rattraper_releves();
  perform entreprises_rattraper_rapports();
  perform bureau_poste_cloturer_votes_expires();

  select code_social_encrypte into v_code from citoyens where id = auth.uid();
  if v_code is null then raise exception 'Non authentifié.'; end if;

  select cib into v_force from cib_reserves where code_encrypte = v_code and actif and remplace_fichier limit 1;
  if v_force is not null then return v_force; end if;

  select cib into v_actuel from cib_reserves where code_encrypte = v_code and actif limit 1;
  if p_cib_fichier is null or p_cib_fichier !~ '^0R-0[0-9]+$' then return v_actuel; end if;
  if v_actuel = p_cib_fichier then return v_actuel; end if;

  if exists (select 1 from entreprises_cib where p_cib_fichier in (cib_impots, cib_reception, cib_envoi))
     or exists (select 1 from cib_reserves where cib = p_cib_fichier and code_encrypte is distinct from v_code) then
    raise exception 'Ce CIB est déjà attribué : contactez le gouvernement.';
  end if;
  if v_actuel is not null then update cib_reserves set actif = false where cib = v_actuel; end if;
  insert into cib_reserves (cib, code_encrypte, origine) values (p_cib_fichier, v_code, 'fichier_cas')
    on conflict (cib) do update set actif = true;
  return p_cib_fichier;
end; $$;
grant execute on function enregistrer_mon_cib(text) to authenticated;

-- ============================================================
-- FIN
-- ============================================================
