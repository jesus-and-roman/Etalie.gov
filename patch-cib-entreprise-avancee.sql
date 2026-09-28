-- ============================================================
-- patch-cib-entreprise-avancee.sql
-- À exécuter après patch-tresorerie-contribuables.sql (et tout ce qui
-- suit dans order.txt / les patches hors-ordre déjà appliqués). Idempotent.
--
-- CONTENU :
--  1. Rôles & droits d'entreprise (PDG a TOUJOURS tout ; Co-PDG a un jeu
--     de droits par défaut modifiable ; rôles employés personnalisés
--     avec droits à la carte). "modifier_droits" est lui-même un droit :
--     par défaut seul le PDG l'a, mais il est délégable comme les autres.
--  2. CIB (Code d'Identification Bancaire) des entreprises : 3 par
--     entreprise (impôts / réception / envoi), générés au hasard à la
--     création, visibles seulement selon les droits voir_cib_*.
--     Suppression des champs "numéro de papier d'impôt" à l'inscription
--     (remplacés par le système de CIB).
--  3. Salaire horaire modifiable pour TOUS les rôles (PDG/Co-PDG/employés/
--     rôles créés) + heures accumulées PAR TAUX (un changement de salaire
--     ouvre une nouvelle case sans perdre les heures déjà accumulées à
--     l'ancien taux).
--  4. Mode de paiement (manuel / automatique) + 4 options de défaillance
--     de trésorerie (prêt gouvernemental plafonné+dette 20%, trésorerie
--     négative avec dette aux employés, virement automatique externe par
--     CIB, ou repli en manuel). Emprunts d'entreprise au gouvernement
--     (taux jour/mois/an/fixe).
--  5. Virement personnel -> entreprise par CIB de réception ; virement
--     entreprise -> entreprise par CIB.
--  6. Marché des capitaux (vente de %, prix par 0,01%, max par individu,
--     minimum achetable).
--  7. Logs d'entreprise (dépenses, ajouts de fonds, paiements, virements,
--     ventes de capital) + rapport d'impôt mensuel manuel OU automatique
--     (généré depuis les logs si aucun rapport manuel n'est fait ; les
--     logs sont purgés après un rapport, qu'il soit manuel ou auto) +
--     consultation publique des relevés par nom d'entreprise.
--  8. Page "Infos personnelles" : infos complètes du citoyen connecté +
--     changement d'email (le changement de mot de passe se fait côté
--     client avec sb.auth.updateUser({password}), aucune fonction SQL
--     n'est nécessaire pour ça).
--
-- HYPOTHÈSES (scope énorme, à corriger au besoin) :
--  - Aucune taxe sur virement_vers_entreprise (par CIB) : traité comme un
--    simple ajout de fonds, contrairement à virement_entrepreneur (0,15%)
--    qui existait déjà.
--  - En défaillance de paie (options 1/2/3), le montant versé au citoyen
--    est le NET déjà calculé, sans re-appliquer les taxes normales : la
--    trésorerie/dette concernée avance directement ce net.
--  - Option 1 : le taux horaire "couvrable" par le gouvernement est
--    plafonné à 200 R$/h ; si le taux réel dépasse 200, seule la portion
--    proportionnelle à 200 R$/h est couverte (mise en dette à 20%), le
--    reste part en argent_attendu comme un salaire civil différé normal.
--  - Mode automatique : je respecte littéralement "on divise le salaire
--    horaire par 60" pour obtenir le montant par SECONDE (18/60=0,3),
--    même si ça ne correspond pas exactement à 18 R$ sur une heure
--    réelle de 3600 secondes — c'est la formule telle que décrite.
--  - "Dépenses" du rapport automatique = somme des logs depense +
--    paiement_employe + virement_tiers + virement_entreprise sur la
--    période. Ajustable si une autre définition était voulue.
-- ============================================================


-- ============================================================
-- 1) RÔLES & DROITS D'ENTREPRISE
-- ============================================================
-- Droits valides : ajouter_employe, modifier_salaire, payer_employe,
-- transferer_argent, voir_cib_impots, voir_cib_reception, voir_cib_envoi,
-- modifier_droits, deposer_impot, vendre_capital, emprunter_gouvernement,
-- definir_mode_paiement, enregistrer_depense, virement_inter_entreprise.
-- Le PDG a TOUJOURS tous les droits, sans exception, non révocable.

create table if not exists entreprises_roles (
  id            uuid primary key default gen_random_uuid(),
  entreprise_id uuid not null references entreprises(id),
  nom           text not null,
  droits        text[] not null default '{}',
  cree_le       timestamptz not null default now(),
  unique (entreprise_id, nom)
);
alter table entreprises_roles enable row level security;
drop policy if exists "Lecture des rôles de ses entreprises" on entreprises_roles;
create policy "Lecture des rôles de ses entreprises" on entreprises_roles for select
  using (est_admin_actuel() or exists(
    select 1 from entreprises_membres m
    where m.entreprise_id = entreprises_roles.entreprise_id and m.citoyen_id = auth.uid()
  ));

alter table entreprises add column if not exists droits_co_pdg text[] not null default array[
  'ajouter_employe','modifier_salaire','payer_employe','transferer_argent',
  'voir_cib_reception','voir_cib_envoi','deposer_impot','vendre_capital',
  'emprunter_gouvernement','definir_mode_paiement','enregistrer_depense','virement_inter_entreprise'
]::text[];
-- Par défaut le Co-PDG a tout SAUF modifier_droits et voir_cib_impots
-- (à accorder explicitement par le PDG via entreprise_definir_droits_co_pdg).

alter table entreprises_membres add column if not exists role_id uuid references entreprises_roles(id);
alter table entreprises_membres add column if not exists cib text;

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
  if v_role_id is null then return false; end if;
  select droits into v_droits_role from entreprises_roles where id = v_role_id;
  return p_droit = any(coalesce(v_droits_role, '{}'));
end; $$;
grant execute on function _entreprise_a_droit(uuid, text, uuid) to authenticated;

create or replace function _exige_droit(p_entreprise_id uuid, p_droit text)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not _entreprise_a_droit(p_entreprise_id, p_droit) then
    raise exception 'Accès refusé : droit "%" requis.', p_droit;
  end if;
end; $$;

create or replace function entreprise_creer_role(p_entreprise_id uuid, p_nom text, p_droits text[])
returns entreprises_roles language plpgsql security definer set search_path = public as $$
declare v_row entreprises_roles;
begin
  perform _exige_droit(p_entreprise_id, 'modifier_droits');
  if p_nom is null or char_length(trim(p_nom)) = 0 then raise exception 'Nom de rôle requis.'; end if;
  insert into entreprises_roles (entreprise_id, nom, droits)
    values (p_entreprise_id, trim(p_nom), coalesce(p_droits, '{}'))
    returning * into v_row;
  return v_row;
end; $$;
grant execute on function entreprise_creer_role(uuid, text, text[]) to authenticated;

create or replace function entreprise_modifier_droits_role(p_role_id uuid, p_droits text[])
returns void language plpgsql security definer set search_path = public as $$
declare v_ent uuid;
begin
  select entreprise_id into v_ent from entreprises_roles where id = p_role_id;
  if v_ent is null then raise exception 'Rôle introuvable.'; end if;
  perform _exige_droit(v_ent, 'modifier_droits');
  update entreprises_roles set droits = coalesce(p_droits, '{}') where id = p_role_id;
end; $$;
grant execute on function entreprise_modifier_droits_role(uuid, text[]) to authenticated;

create or replace function entreprise_supprimer_role(p_role_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_ent uuid;
begin
  select entreprise_id into v_ent from entreprises_roles where id = p_role_id;
  if v_ent is null then raise exception 'Rôle introuvable.'; end if;
  perform _exige_droit(v_ent, 'modifier_droits');
  update entreprises_membres set role_id = null where role_id = p_role_id;
  delete from entreprises_roles where id = p_role_id;
end; $$;
grant execute on function entreprise_supprimer_role(uuid) to authenticated;

create or replace function entreprise_assigner_role_employe(p_entreprise_id uuid, p_citoyen_id uuid, p_role_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exige_droit(p_entreprise_id, 'modifier_droits');
  if p_role_id is not null and not exists(
    select 1 from entreprises_roles where id = p_role_id and entreprise_id = p_entreprise_id
  ) then
    raise exception 'Rôle introuvable dans cette entreprise.';
  end if;
  update entreprises_membres set role_id = p_role_id
    where entreprise_id = p_entreprise_id and citoyen_id = p_citoyen_id and role = 'employe';
end; $$;
grant execute on function entreprise_assigner_role_employe(uuid, uuid, uuid) to authenticated;

create or replace function entreprise_definir_droits_co_pdg(p_entreprise_id uuid, p_droits text[])
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exige_droit(p_entreprise_id, 'modifier_droits');
  update entreprises set droits_co_pdg = coalesce(p_droits, '{}') where id = p_entreprise_id;
end; $$;
grant execute on function entreprise_definir_droits_co_pdg(uuid, text[]) to authenticated;

create or replace function entreprise_mes_droits(p_entreprise_id uuid)
returns text[] language plpgsql stable security definer set search_path = public as $$
declare v_role text; v_role_id uuid; v_droits_co text[]; v_droits_role text[];
begin
  select role, role_id into v_role, v_role_id from entreprises_membres
    where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_role is null then return '{}'; end if;
  if v_role = 'pdg' then
    return array['ajouter_employe','modifier_salaire','payer_employe','transferer_argent',
      'voir_cib_impots','voir_cib_reception','voir_cib_envoi','modifier_droits','deposer_impot',
      'vendre_capital','emprunter_gouvernement','definir_mode_paiement','enregistrer_depense','virement_inter_entreprise'];
  end if;
  if v_role = 'co_pdg' then
    select droits_co_pdg into v_droits_co from entreprises where id = p_entreprise_id;
    return coalesce(v_droits_co, '{}');
  end if;
  if v_role_id is null then return '{}'; end if;
  select droits into v_droits_role from entreprises_roles where id = v_role_id;
  return coalesce(v_droits_role, '{}');
end; $$;
grant execute on function entreprise_mes_droits(uuid) to authenticated;


-- ============================================================
-- 2) CIB DES ENTREPRISES — retrait des numéros de papier d'impôt
-- ============================================================
alter table entreprises add column if not exists cib_impots text unique;
alter table entreprises add column if not exists cib_reception text unique;
alter table entreprises add column if not exists cib_envoi text unique;
alter table entreprises drop column if exists numero_papier_impot_depenses;
alter table entreprises drop column if exists numero_papier_impot_achats;

create or replace function _generer_cib()
returns text language plpgsql as $$
declare v_code text;
begin
  loop
    v_code := '0R-0' || lpad(floor(random() * 100000000000)::text, 11, '0');
    exit when not exists(
      select 1 from entreprises where cib_impots = v_code or cib_reception = v_code or cib_envoi = v_code
    );
  end loop;
  return v_code;
end; $$;

drop function if exists entreprise_demander(text,numeric,text,numeric,text,text,text,text,text,text,text,jsonb);

create or replace function entreprise_demander(
  p_nom text, p_depenses numeric, p_achats numeric,
  p_type_vente text, p_mode_vente text, p_boutique_principale text, p_boutiques_secondaires text,
  p_sieges text, p_fondateur_cas text, p_employes jsonb default '[]'::jsonb
) returns public.entreprises language plpgsql security definer set search_path = public as $$
declare v_row public.entreprises; v_emp jsonb; v_emp_id uuid;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if p_nom is null or char_length(trim(p_nom)) = 0 then raise exception 'Nom d''entreprise requis.'; end if;
  if p_sieges is null or char_length(trim(p_sieges)) = 0 then raise exception 'Au moins un siège physique est requis.'; end if;

  insert into entreprises (code, nom, depenses_an_dernier, achats_an_dernier, type_vente, mode_vente,
    boutique_principale, boutiques_secondaires, sieges, fondateur_id, fondateur_cas,
    cib_impots, cib_reception, cib_envoi)
  values ('E-' || _generer_code_alnum(8), p_nom, p_depenses, p_achats, p_type_vente, p_mode_vente,
    p_boutique_principale, p_boutiques_secondaires, p_sieges, auth.uid(), p_fondateur_cas,
    _generer_cib(), _generer_cib(), _generer_cib())
  returning * into v_row;

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

create or replace function entreprise_mes_cib(p_entreprise_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_ent entreprises; v_role text; v_res jsonb := '{}'::jsonb;
begin
  select * into v_ent from entreprises where id = p_entreprise_id;
  if v_ent is null then raise exception 'Entreprise introuvable.'; end if;
  select role into v_role from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_role is null and not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  if _entreprise_a_droit(p_entreprise_id, 'voir_cib_impots') then v_res := v_res || jsonb_build_object('cib_impots', v_ent.cib_impots); end if;
  if _entreprise_a_droit(p_entreprise_id, 'voir_cib_reception') then v_res := v_res || jsonb_build_object('cib_reception', v_ent.cib_reception); end if;
  if _entreprise_a_droit(p_entreprise_id, 'voir_cib_envoi') then v_res := v_res || jsonb_build_object('cib_envoi', v_ent.cib_envoi); end if;
  return v_res;
end; $$;
grant execute on function entreprise_mes_cib(uuid) to authenticated;


-- ============================================================
-- 3) SALAIRE GÉNÉRIQUE (tous rôles) + HEURES PAR TAUX
-- ============================================================
create table if not exists entreprises_membres_heures (
  id            uuid primary key default gen_random_uuid(),
  entreprise_id uuid not null references entreprises(id),
  citoyen_id    uuid not null references auth.users(id),
  taux          numeric not null,
  heures        numeric not null default 0,
  unique (entreprise_id, citoyen_id, taux)
);
alter table entreprises_membres_heures enable row level security;
drop policy if exists "Voir ses heures ou celles de ses entreprises gérées" on entreprises_membres_heures;
create policy "Voir ses heures ou celles de ses entreprises gérées" on entreprises_membres_heures for select
  using (
    citoyen_id = auth.uid()
    or exists(select 1 from entreprises_membres m where m.entreprise_id = entreprises_membres_heures.entreprise_id
              and m.citoyen_id = auth.uid() and m.role in ('pdg','co_pdg'))
    or est_admin_actuel()
  );

drop function if exists entreprise_ajouter_employe(uuid, text, numeric);

create or replace function entreprise_ajouter_employe(p_entreprise_id uuid, p_cas text, p_salaire_horaire numeric, p_cib text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform _exige_droit(p_entreprise_id, 'ajouter_employe');
  if p_salaire_horaire < 18 then raise exception 'Le salaire doit être au moins le salaire minimum (18 R$/heure).'; end if;
  select id into v_id from citoyens where code_social_encrypte = p_cas;
  if v_id is null then raise exception 'Code d''assurance social introuvable.'; end if;
  insert into entreprises_membres (entreprise_id, citoyen_id, role, salaire_horaire, cib)
    values (p_entreprise_id, v_id, 'employe', p_salaire_horaire, nullif(trim(coalesce(p_cib,'')), ''))
    on conflict (entreprise_id, citoyen_id) do update
      set salaire_horaire = p_salaire_horaire,
          cib = coalesce(excluded.cib, entreprises_membres.cib);
end; $$;
grant execute on function entreprise_ajouter_employe(uuid, text, numeric, text) to authenticated;

create or replace function entreprise_definir_cib_membre(p_entreprise_id uuid, p_citoyen_id uuid, p_cib text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exige_droit(p_entreprise_id, 'ajouter_employe');
  update entreprises_membres set cib = nullif(trim(coalesce(p_cib,'')), '')
    where entreprise_id = p_entreprise_id and citoyen_id = p_citoyen_id;
end; $$;
grant execute on function entreprise_definir_cib_membre(uuid, uuid, text) to authenticated;

-- Modifie le salaire de N'IMPORTE QUEL membre (PDG, Co-PDG, employé, quel
-- que soit son rôle personnalisé). Les heures déjà accumulées à l'ancien
-- taux restent intactes dans leur propre case (entreprises_membres_heures) ;
-- l'accumulation future se fera dans une nouvelle case au nouveau taux.
create or replace function entreprise_modifier_salaire(p_entreprise_id uuid, p_citoyen_id uuid, p_nouveau_salaire numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_role text;
begin
  perform _exige_droit(p_entreprise_id, 'modifier_salaire');
  select role into v_role from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = p_citoyen_id;
  if v_role is null then raise exception 'Membre introuvable.'; end if;
  if p_nouveau_salaire < 18 then raise exception 'Le salaire doit être au moins le salaire minimum (18 R$/heure).'; end if;
  update entreprises_membres set salaire_horaire = p_nouveau_salaire
    where entreprise_id = p_entreprise_id and citoyen_id = p_citoyen_id;
end; $$;
grant execute on function entreprise_modifier_salaire(uuid, uuid, numeric) to authenticated;

-- Appelé côté client toutes les minutes pendant que le membre est connecté
-- (mode manuel seulement — ne fait rien en mode automatique).
create or replace function entreprise_accumuler_heure(p_entreprise_id uuid, p_minutes numeric default 1.0/60)
returns void language plpgsql security definer set search_path = public as $$
declare v_taux numeric; v_mode text;
begin
  select salaire_horaire into v_taux from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_taux is null then raise exception 'Non membre de cette entreprise, ou sans salaire défini.'; end if;
  select mode_paiement into v_mode from entreprises where id = p_entreprise_id;
  if v_mode <> 'manuel' then return; end if;
  insert into entreprises_membres_heures (entreprise_id, citoyen_id, taux, heures)
    values (p_entreprise_id, auth.uid(), v_taux, p_minutes / 60.0)
    on conflict (entreprise_id, citoyen_id, taux) do update
      set heures = entreprises_membres_heures.heures + p_minutes / 60.0;
end; $$;
grant execute on function entreprise_accumuler_heure(uuid, numeric) to authenticated;

-- Liste "18h (18R$) / 1h (22R$)" pour l'écran de paie.
create or replace function entreprise_heures_membre(p_entreprise_id uuid, p_citoyen_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('taux', taux, 'heures', heures) order by taux), '[]'::jsonb)
  from entreprises_membres_heures where entreprise_id = p_entreprise_id and citoyen_id = p_citoyen_id and heures > 0;
$$;
grant execute on function entreprise_heures_membre(uuid, uuid) to authenticated;


-- ============================================================
-- 4) MODE DE PAIEMENT + OPTIONS DE DÉFAILLANCE + EMPRUNTS GOUV.
-- ============================================================
alter table entreprises add column if not exists mode_paiement text not null default 'manuel' check (mode_paiement in ('manuel','automatique'));
alter table entreprises add column if not exists option_defaillance int not null default 4 check (option_defaillance in (1,2,3,4));
alter table entreprises add column if not exists dette_salariale_gouv numeric not null default 0;
alter table entreprises add column if not exists dette_salariale_employes numeric not null default 0;
alter table entreprises add column if not exists option3_cibs text[] not null default '{}';

create or replace function entreprise_definir_mode_paiement(p_entreprise_id uuid, p_mode text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exige_droit(p_entreprise_id, 'definir_mode_paiement');
  if p_mode not in ('manuel','automatique') then raise exception 'Mode invalide.'; end if;
  update entreprises set mode_paiement = p_mode where id = p_entreprise_id;
end; $$;
grant execute on function entreprise_definir_mode_paiement(uuid, text) to authenticated;

create or replace function entreprise_definir_option_defaillance(p_entreprise_id uuid, p_option int, p_cibs text[] default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exige_droit(p_entreprise_id, 'definir_mode_paiement');
  if p_option not in (1,2,3,4) then raise exception 'Option invalide (1 à 4).'; end if;
  update entreprises set option_defaillance = p_option,
    option3_cibs = case when p_option = 3 then coalesce(p_cibs, '{}') else option3_cibs end
    where id = p_entreprise_id;
end; $$;
grant execute on function entreprise_definir_option_defaillance(uuid, int, text[]) to authenticated;

-- Gère un manque de trésorerie d'entreprise selon l'option choisie.
-- Retourne le montant effectivement obtenu par l'employé (net direct,
-- voir HYPOTHÈSES en tête de fichier).
create or replace function _entreprise_gerer_manque_paie(p_entreprise_id uuid, p_citoyen_id uuid, p_montant_du numeric, p_taux_horaire numeric)
returns numeric language plpgsql security definer set search_path = public as $$
declare v_option int; v_couvrable numeric; v_reste numeric; v_cibs text[]; v_cib text;
  v_ent_source uuid; v_dispo numeric; v_pris numeric;
begin
  select option_defaillance into v_option from entreprises where id = p_entreprise_id;

  if v_option = 1 then
    if p_taux_horaire > 200 then
      v_couvrable := p_montant_du * (200.0 / p_taux_horaire);
    else
      v_couvrable := p_montant_du;
    end if;
    update entreprises set dette_salariale_gouv = dette_salariale_gouv + v_couvrable * 1.20 where id = p_entreprise_id;
    if (select dette_salariale_gouv from entreprises where id = p_entreprise_id) > 100000 then
      update entreprises set option_defaillance = 2 where id = p_entreprise_id;
    end if;
    update citoyens set tresorerie = tresorerie + v_couvrable where id = p_citoyen_id;
    v_reste := p_montant_du - v_couvrable;
    if v_reste > 0 then
      update citoyens set argent_attendu = argent_attendu + v_reste where id = p_citoyen_id;
    end if;
    return v_couvrable;

  elsif v_option = 2 then
    update entreprises set tresorerie = tresorerie - p_montant_du,
      dette_salariale_employes = dette_salariale_employes + p_montant_du where id = p_entreprise_id;
    update citoyens set tresorerie = tresorerie + p_montant_du where id = p_citoyen_id;
    return p_montant_du;

  elsif v_option = 3 then
    select option3_cibs into v_cibs from entreprises where id = p_entreprise_id;
    v_reste := p_montant_du;
    foreach v_cib in array coalesce(v_cibs, '{}') loop
      exit when v_reste <= 0;
      select id into v_ent_source from entreprises where cib_envoi = v_cib or cib_reception = v_cib;
      if v_ent_source is not null then
        select tresorerie into v_dispo from entreprises where id = v_ent_source for update;
        v_pris := least(v_reste, greatest(0, v_dispo));
        update entreprises set tresorerie = tresorerie - v_pris where id = v_ent_source;
        v_reste := v_reste - v_pris;
      end if;
    end loop;
    if v_reste > 0 then
      -- Aucune source externe n'a suffi : la différence retombe en dette employés (option 2).
      update entreprises set tresorerie = tresorerie - v_reste,
        dette_salariale_employes = dette_salariale_employes + v_reste where id = p_entreprise_id;
    end if;
    update citoyens set tresorerie = tresorerie + p_montant_du where id = p_citoyen_id;
    return p_montant_du;

  else
    raise exception 'Trésorerie insuffisante : cette entreprise est en mode manuel uniquement (option 4).';
  end if;
end; $$;

-- Quand la trésorerie de l'entreprise redevient positive, rembourse
-- d'abord dette_salariale_employes (option 2) avant que le surplus soit
-- utilisable normalement. À appeler après tout ajout de fonds.
create or replace function _entreprise_regler_dette_employes(p_entreprise_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_tresor numeric; v_dette numeric; v_paye numeric;
begin
  select tresorerie, dette_salariale_employes into v_tresor, v_dette from entreprises where id = p_entreprise_id for update;
  if v_dette <= 0 or v_tresor <= 0 then return; end if;
  v_paye := least(v_tresor, v_dette);
  update entreprises set tresorerie = tresorerie - v_paye, dette_salariale_employes = dette_salariale_employes - v_paye
    where id = p_entreprise_id;
end; $$;

-- Mode automatique : "0,3 R$/seconde" pour un salaire de 18 R$/h (voir
-- HYPOTHÈSES). Appelé côté client chaque seconde pendant la connexion.
create or replace function entreprise_avancer_paiement_auto(p_entreprise_id uuid, p_secondes numeric default 1)
returns void language plpgsql security definer set search_path = public as $$
declare v_taux numeric; v_mode text; v_montant numeric; v_tresor numeric;
begin
  select mode_paiement into v_mode from entreprises where id = p_entreprise_id;
  if v_mode <> 'automatique' then raise exception 'Cette entreprise n''est pas en mode de paiement automatique.'; end if;
  select salaire_horaire into v_taux from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_taux is null then raise exception 'Non membre de cette entreprise, ou sans salaire défini.'; end if;

  v_montant := (v_taux / 60.0) * p_secondes;
  select tresorerie into v_tresor from entreprises where id = p_entreprise_id for update;
  if v_tresor >= v_montant then
    update entreprises set tresorerie = tresorerie - v_montant where id = p_entreprise_id;
    update citoyens set tresorerie = tresorerie + v_montant where id = auth.uid();
    perform _entreprise_log(p_entreprise_id, 'paiement_employe',
      jsonb_build_object('citoyen_id', auth.uid(), 'montant', v_montant, 'secondes', p_secondes, 'taux', v_taux));
  else
    perform _entreprise_gerer_manque_paie(p_entreprise_id, auth.uid(), v_montant, v_taux);
    perform _entreprise_log(p_entreprise_id, 'paiement_employe',
      jsonb_build_object('citoyen_id', auth.uid(), 'montant', v_montant, 'secondes', p_secondes, 'taux', v_taux, 'defaillance', true));
  end if;
end; $$;
grant execute on function entreprise_avancer_paiement_auto(uuid, numeric) to authenticated;

-- ---- Emprunts de l'entreprise au gouvernement ----
create table if not exists entreprises_emprunts_gouv (
  id                uuid primary key default gen_random_uuid(),
  entreprise_id     uuid not null references entreprises(id),
  montant_demande   numeric not null check (montant_demande > 0),
  type_taux         text not null check (type_taux in ('jour','mois','an','fixe')),
  taux_valeur       numeric not null check (taux_valeur >= 0),
  justification     text not null,
  statut            text not null default 'en_attente' check (statut in ('en_attente','acceptee','refusee','rembourse')),
  montant_du        numeric,
  accepte_le        timestamptz,
  cree_le           timestamptz not null default now()
);
alter table entreprises_emprunts_gouv enable row level security;
drop policy if exists "Voir ses emprunts d'entreprise ou tout si admin" on entreprises_emprunts_gouv;
create policy "Voir ses emprunts d'entreprise ou tout si admin" on entreprises_emprunts_gouv for select
  using (est_admin_actuel() or exists(
    select 1 from entreprises_membres m where m.entreprise_id = entreprises_emprunts_gouv.entreprise_id and m.citoyen_id = auth.uid()
  ));

create or replace function entreprise_demander_emprunt_gouv(p_entreprise_id uuid, p_montant numeric, p_type_taux text, p_taux_valeur numeric, p_justification text)
returns entreprises_emprunts_gouv language plpgsql security definer set search_path = public as $$
declare v_row entreprises_emprunts_gouv;
begin
  perform _exige_droit(p_entreprise_id, 'emprunter_gouvernement');
  if p_montant <= 0 then raise exception 'Montant invalide.'; end if;
  if p_type_taux not in ('jour','mois','an','fixe') then raise exception 'Type de taux invalide.'; end if;
  insert into entreprises_emprunts_gouv (entreprise_id, montant_demande, type_taux, taux_valeur, justification)
    values (p_entreprise_id, p_montant, p_type_taux, p_taux_valeur, p_justification) returning * into v_row;
  return v_row;
end; $$;
grant execute on function entreprise_demander_emprunt_gouv(uuid, numeric, text, numeric, text) to authenticated;

create or replace function gouv_liste_emprunts_entreprises(p_statut text default 'en_attente')
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not est_admin_actuel() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id, 'entreprise_nom', en.nom, 'montant_demande', e.montant_demande, 'type_taux', e.type_taux,
    'taux_valeur', e.taux_valeur, 'justification', e.justification, 'cree_le', e.cree_le
  ) order by e.cree_le), '[]'::jsonb) end
  from entreprises_emprunts_gouv e join entreprises en on en.id = e.entreprise_id where e.statut = p_statut;
$$;
grant execute on function gouv_liste_emprunts_entreprises(text) to authenticated;

create or replace function gouv_traiter_emprunt_entreprise(p_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
declare v_row entreprises_emprunts_gouv; v_ajout numeric;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if p_decision not in ('acceptee','refusee') then raise exception 'Décision invalide.'; end if;
  select * into v_row from entreprises_emprunts_gouv where id = p_id and statut = 'en_attente';
  if v_row is null then raise exception 'Demande introuvable ou déjà traitée.'; end if;

  if p_decision = 'refusee' then
    update entreprises_emprunts_gouv set statut = 'refusee' where id = p_id;
    return;
  end if;

  v_ajout := case when v_row.type_taux = 'fixe' then v_row.montant_demande + v_row.taux_valeur else v_row.montant_demande end;
  update entreprises set tresorerie = tresorerie + v_row.montant_demande where id = v_row.entreprise_id;
  update entreprises_emprunts_gouv set statut = 'acceptee', montant_du = v_ajout, accepte_le = now() where id = p_id;
end; $$;
grant execute on function gouv_traiter_emprunt_entreprise(uuid, text) to authenticated;

-- Montant dû : figé pour "fixe", croît chaque jour pour jour/mois/an.
create or replace function emprunt_entreprise_montant_du(p_id uuid)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare v entreprises_emprunts_gouv; v_jours numeric; v_par_jour numeric;
begin
  select * into v from entreprises_emprunts_gouv where id = p_id;
  if v is null or v.statut <> 'acceptee' then return coalesce(v.montant_du, 0); end if;
  if v.type_taux = 'fixe' then return v.montant_du; end if;
  v_jours := extract(epoch from (now() - v.accepte_le)) / 86400.0;
  v_par_jour := case v.type_taux
    when 'jour' then v.montant_demande * (v.taux_valeur / 100.0)
    when 'mois' then v.montant_demande * (v.taux_valeur / 100.0) / 30.0
    when 'an'   then v.montant_demande * (v.taux_valeur / 100.0) / 365.0
  end;
  return v.montant_demande + v_par_jour * v_jours;
end; $$;
grant execute on function emprunt_entreprise_montant_du(uuid) to authenticated, anon;

create or replace function entreprise_rembourser_emprunt_gouv(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_du numeric; v_ent uuid; v_tresor numeric;
begin
  select entreprise_id into v_ent from entreprises_emprunts_gouv where id = p_id and statut = 'acceptee';
  if v_ent is null then raise exception 'Emprunt introuvable ou non actif.'; end if;
  perform _exige_droit(v_ent, 'emprunter_gouvernement');
  v_du := emprunt_entreprise_montant_du(p_id);
  select tresorerie into v_tresor from entreprises where id = v_ent for update;
  if v_tresor < v_du then raise exception 'Trésorerie de l''entreprise insuffisante (dû : % R$).', v_du; end if;
  update entreprises set tresorerie = tresorerie - v_du where id = v_ent;
  update tresor_public set solde = solde + v_du where id = 1;
  update entreprises_emprunts_gouv set statut = 'rembourse', montant_du = 0 where id = p_id;
end; $$;
grant execute on function entreprise_rembourser_emprunt_gouv(uuid) to authenticated;

-- Réécriture de la paie manuelle : paiement PAR TAUX accumulé, gérée par
-- droit ('payer_employe'), avec repli sur la défaillance si besoin.
drop function if exists entreprise_payer_employe(uuid, uuid, numeric);

create or replace function entreprise_payer_employe(p_entreprise_id uuid, p_citoyen_id uuid, p_taux numeric, p_heures numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_dispo numeric; v_brut numeric; v_taux_revenu numeric; v_taux_prev numeric;
  v_tr numeric; v_te numeric; v_cho numeric; v_ret numeric; v_par numeric; v_net numeric; v_tresor numeric;
begin
  perform _exige_droit(p_entreprise_id, 'payer_employe');
  if p_heures <= 0 then raise exception 'Le nombre d''heures doit être positif.'; end if;

  select heures into v_dispo from entreprises_membres_heures
    where entreprise_id = p_entreprise_id and citoyen_id = p_citoyen_id and taux = p_taux for update;
  if v_dispo is null or v_dispo < p_heures then
    raise exception 'Heures accumulées insuffisantes à ce taux (disponible : % h).', coalesce(v_dispo, 0);
  end if;

  v_brut := p_taux * p_heures;
  select taux_revenu into v_taux_revenu from citoyens where id = p_citoyen_id;
  select taux_preventif into v_taux_prev from parametres_fiscaux where id = 1;
  v_tr := v_brut * (v_taux_revenu / 100.0); v_te := v_brut * (v_taux_prev / 100.0);
  v_cho := v_brut * 0.0275; v_ret := v_brut * 0.0675; v_par := v_brut * 0.0025;
  v_net := v_brut - v_tr - v_te - v_cho - v_ret - v_par;

  select tresorerie into v_tresor from entreprises where id = p_entreprise_id for update;
  if v_tresor >= v_brut then
    update entreprises set tresorerie = tresorerie - v_brut where id = p_entreprise_id;
    update citoyens set tresorerie = tresorerie + v_net, compte_chomage = compte_chomage + v_cho,
      compte_retraite = compte_retraite + v_ret, compte_parentalite = compte_parentalite + v_par,
      taxes_gouv_60j = taxes_gouv_60j + v_tr, taxe_preventive_60j = taxe_preventive_60j + v_te
      where id = p_citoyen_id;
    update tresor_public set solde = solde + v_tr + v_te, taxes_totales_periode = taxes_totales_periode + v_tr + v_te where id = 1;
  else
    perform _entreprise_gerer_manque_paie(p_entreprise_id, p_citoyen_id, v_net, p_taux);
  end if;

  update entreprises_membres_heures set heures = heures - p_heures
    where entreprise_id = p_entreprise_id and citoyen_id = p_citoyen_id and taux = p_taux;

  perform _entreprise_log(p_entreprise_id, 'paiement_employe',
    jsonb_build_object('citoyen_id', p_citoyen_id, 'montant', v_net, 'heures', p_heures, 'taux', p_taux));
end; $$;
grant execute on function entreprise_payer_employe(uuid, uuid, numeric, numeric) to authenticated;


-- ============================================================
-- 5) VIREMENTS PAR CIB (personnel -> entreprise, entreprise -> entreprise)
-- ============================================================
create or replace function virement_vers_entreprise(p_cib text, p_montant numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_ent_id uuid; v_expediteur citoyens;
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select id into v_ent_id from entreprises where cib_reception = p_cib and statut = 'acceptee';
  if v_ent_id is null then raise exception 'CIB de réception introuvable.'; end if;
  select * into v_expediteur from citoyens where id = auth.uid();
  if v_expediteur.tresorerie < p_montant then raise exception 'Trésorerie insuffisante.'; end if;

  update citoyens set tresorerie = tresorerie - p_montant where id = auth.uid();
  update entreprises set tresorerie = tresorerie + p_montant where id = v_ent_id;
  perform _entreprise_regler_dette_employes(v_ent_id);
  perform _entreprise_log(v_ent_id, 'ajout_fonds', jsonb_build_object('citoyen_id', auth.uid(), 'montant', p_montant));
end; $$;
grant execute on function virement_vers_entreprise(text, numeric) to authenticated;

create or replace function entreprise_virement_vers_entreprise(p_entreprise_id uuid, p_cib_dest text, p_montant numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_dest_id uuid; v_nom_dest text; v_tresor numeric;
begin
  perform _exige_droit(p_entreprise_id, 'virement_inter_entreprise');
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select id, nom into v_dest_id, v_nom_dest from entreprises where cib_reception = p_cib_dest and statut = 'acceptee';
  if v_dest_id is null then raise exception 'CIB de réception introuvable.'; end if;
  if v_dest_id = p_entreprise_id then raise exception 'Impossible de se virer à soi-même.'; end if;

  select tresorerie into v_tresor from entreprises where id = p_entreprise_id for update;
  if v_tresor < p_montant then raise exception 'Trésorerie insuffisante.'; end if;

  update entreprises set tresorerie = tresorerie - p_montant where id = p_entreprise_id;
  update entreprises set tresorerie = tresorerie + p_montant where id = v_dest_id;
  perform _entreprise_regler_dette_employes(v_dest_id);
  perform _entreprise_log(p_entreprise_id, 'virement_entreprise',
    jsonb_build_object('entreprise_dest_nom', v_nom_dest, 'entreprise_dest_id', v_dest_id, 'montant', p_montant));
end; $$;
grant execute on function entreprise_virement_vers_entreprise(uuid, text, numeric) to authenticated;

-- virement_entrepreneur existant : gouverné par droit + journalisé.
create or replace function virement_entrepreneur(p_entreprise_id uuid, p_destinataire_username text, p_montant numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_dest_id uuid; v_expediteur citoyens; v_taxe numeric; v_total numeric;
begin
  perform _exige_droit(p_entreprise_id, 'transferer_argent');
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select id into v_dest_id from citoyens where lower(username) = lower(p_destinataire_username);
  if v_dest_id is null then raise exception 'Destinataire introuvable.'; end if;

  select * into v_expediteur from citoyens where id = auth.uid();
  v_taxe := p_montant * 0.0015;
  v_total := p_montant + v_taxe;
  if v_expediteur.tresorerie < v_total then raise exception 'Trésorerie personnelle insuffisante (total avec taxe: %).', v_total; end if;

  update citoyens set tresorerie = tresorerie - v_total where id = auth.uid();
  update entreprises set tresorerie = tresorerie + p_montant where id = p_entreprise_id;
  update tresor_public set solde_prive = solde_prive + v_taxe where id = 1;
  perform _entreprise_log(p_entreprise_id, 'virement_tiers', jsonb_build_object('destinataire_username', p_destinataire_username, 'montant', p_montant));
end; $$;
grant execute on function virement_entrepreneur(uuid, text, numeric) to authenticated;


-- ============================================================
-- 6) MARCHÉ DES CAPITAUX
-- ============================================================
alter table entreprises add column if not exists capital_en_vente_pct numeric not null default 0 check (capital_en_vente_pct >= 0 and capital_en_vente_pct <= 100);
alter table entreprises add column if not exists capital_max_par_individu numeric;
alter table entreprises add column if not exists capital_prix_par_centieme numeric;
alter table entreprises add column if not exists capital_min_achat_pct numeric not null default 0.01;

create table if not exists entreprises_capital_detenteurs (
  id            uuid primary key default gen_random_uuid(),
  entreprise_id uuid not null references entreprises(id),
  citoyen_id    uuid not null references auth.users(id),
  pourcentage   numeric not null default 0,
  unique (entreprise_id, citoyen_id)
);
alter table entreprises_capital_detenteurs enable row level security;
drop policy if exists "Lecture publique des détenteurs de capital" on entreprises_capital_detenteurs;
create policy "Lecture publique des détenteurs de capital" on entreprises_capital_detenteurs for select using (true);

create or replace function entreprise_mettre_capital_en_vente(p_entreprise_id uuid, p_pourcentage numeric, p_max_par_individu numeric, p_prix_par_centieme numeric, p_min_achat_pct numeric default 0.01)
returns void language plpgsql security definer set search_path = public as $$
declare v_deja_vendu numeric;
begin
  perform _exige_droit(p_entreprise_id, 'vendre_capital');
  if p_pourcentage < 0 or p_pourcentage > 100 then raise exception 'Pourcentage invalide.'; end if;
  select coalesce(sum(pourcentage), 0) into v_deja_vendu from entreprises_capital_detenteurs where entreprise_id = p_entreprise_id;
  if p_pourcentage + v_deja_vendu > 100 then raise exception 'Le total des capitaux vendus dépasserait 100 %%.'; end if;
  update entreprises set capital_en_vente_pct = p_pourcentage, capital_max_par_individu = p_max_par_individu,
    capital_prix_par_centieme = p_prix_par_centieme, capital_min_achat_pct = coalesce(p_min_achat_pct, 0.01)
    where id = p_entreprise_id;
end; $$;
grant execute on function entreprise_mettre_capital_en_vente(uuid, numeric, numeric, numeric, numeric) to authenticated;

create or replace function entreprise_acheter_capital(p_entreprise_id uuid, p_pourcentage numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_ent entreprises; v_cout numeric; v_deja numeric; v_acheteur citoyens;
begin
  select * into v_ent from entreprises where id = p_entreprise_id and statut = 'acceptee' for update;
  if v_ent is null then raise exception 'Entreprise introuvable.'; end if;
  if p_pourcentage < v_ent.capital_min_achat_pct then
    raise exception 'Minimum achetable : % %%.', v_ent.capital_min_achat_pct;
  end if;
  if p_pourcentage > v_ent.capital_en_vente_pct then
    raise exception 'Il ne reste que % %% en vente.', v_ent.capital_en_vente_pct;
  end if;
  select coalesce(pourcentage, 0) into v_deja from entreprises_capital_detenteurs
    where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_ent.capital_max_par_individu is not null and (coalesce(v_deja, 0) + p_pourcentage) > v_ent.capital_max_par_individu then
    raise exception 'Maximum par individu dépassé (max : % %%).', v_ent.capital_max_par_individu;
  end if;

  v_cout := (p_pourcentage / 0.01) * v_ent.capital_prix_par_centieme;
  select * into v_acheteur from citoyens where id = auth.uid();
  if v_acheteur.tresorerie < v_cout then raise exception 'Trésorerie insuffisante (coût : % R$).', v_cout; end if;

  update citoyens set tresorerie = tresorerie - v_cout where id = auth.uid();
  update entreprises set tresorerie = tresorerie + v_cout, capital_en_vente_pct = capital_en_vente_pct - p_pourcentage where id = p_entreprise_id;
  insert into entreprises_capital_detenteurs (entreprise_id, citoyen_id, pourcentage)
    values (p_entreprise_id, auth.uid(), p_pourcentage)
    on conflict (entreprise_id, citoyen_id) do update set pourcentage = entreprises_capital_detenteurs.pourcentage + p_pourcentage;
  perform _entreprise_regler_dette_employes(p_entreprise_id);
  perform _entreprise_log(p_entreprise_id, 'vente_capital',
    jsonb_build_object('acheteur_username', (select username from citoyens where id = auth.uid()), 'pourcentage', p_pourcentage, 'cout', v_cout));
end; $$;
grant execute on function entreprise_acheter_capital(uuid, numeric) to authenticated;

create or replace function entreprise_capital_public(p_entreprise_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'en_vente_pct', e.capital_en_vente_pct, 'max_par_individu', e.capital_max_par_individu,
    'prix_par_centieme', e.capital_prix_par_centieme, 'min_achat_pct', e.capital_min_achat_pct,
    'detenteurs', coalesce((select jsonb_agg(jsonb_build_object('username', c.username, 'pourcentage', d.pourcentage))
      from entreprises_capital_detenteurs d join citoyens c on c.id = d.citoyen_id where d.entreprise_id = e.id), '[]'::jsonb)
  )
  from entreprises e where e.id = p_entreprise_id;
$$;
grant execute on function entreprise_capital_public(uuid) to authenticated, anon;


-- ============================================================
-- 7) LOGS D'ENTREPRISE + RAPPORTS D'IMPÔTS (manuel / automatique)
-- ============================================================
create table if not exists entreprises_logs (
  id            uuid primary key default gen_random_uuid(),
  entreprise_id uuid not null references entreprises(id),
  type          text not null check (type in ('depense','ajout_fonds','paiement_employe','virement_entreprise','virement_tiers','vente_capital')),
  donnees       jsonb not null default '{}'::jsonb,
  cree_le       timestamptz not null default now()
);
alter table entreprises_logs enable row level security;
drop policy if exists "Voir les logs de ses entreprises" on entreprises_logs;
create policy "Voir les logs de ses entreprises" on entreprises_logs for select
  using (est_admin_actuel() or exists(
    select 1 from entreprises_membres m where m.entreprise_id = entreprises_logs.entreprise_id and m.citoyen_id = auth.uid()
  ));

create or replace function _entreprise_log(p_entreprise_id uuid, p_type text, p_donnees jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into entreprises_logs (entreprise_id, type, donnees) values (p_entreprise_id, p_type, p_donnees);
end; $$;

create or replace function entreprise_enregistrer_depense(p_entreprise_id uuid, p_montant numeric, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare v_tresor numeric;
begin
  perform _exige_droit(p_entreprise_id, 'enregistrer_depense');
  if p_montant <= 0 then raise exception 'Montant invalide.'; end if;
  select tresorerie into v_tresor from entreprises where id = p_entreprise_id for update;
  if v_tresor < p_montant then raise exception 'Trésorerie insuffisante.'; end if;
  update entreprises set tresorerie = tresorerie - p_montant where id = p_entreprise_id;
  perform _entreprise_log(p_entreprise_id, 'depense', jsonb_build_object('montant', p_montant, 'note', p_note));
end; $$;
grant execute on function entreprise_enregistrer_depense(uuid, numeric, text) to authenticated;

alter table entreprises_depots_impots add column if not exists type text not null default 'manuel' check (type in ('manuel','automatique'));
alter table entreprises_depots_impots add column if not exists details jsonb;
alter table entreprises_depots_impots add column if not exists capital_pdg_pct numeric;
alter table entreprises_depots_impots add column if not exists capital_tiers_pct numeric;

-- Dépôt manuel : purge aussi les logs du mois (aucun rapport automatique
-- ne sera donc généré pour cette période, tel que demandé).
create or replace function entreprise_deposer_impot(p_entreprise_id uuid, p_periode text, p_benefices numeric, p_depenses numeric, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exige_droit(p_entreprise_id, 'deposer_impot');
  if exists(select 1 from entreprises_depots_impots where entreprise_id = p_entreprise_id and periode = p_periode) then
    raise exception 'Un rapport existe déjà pour cette période.';
  end if;
  insert into entreprises_depots_impots (entreprise_id, periode, benefices, depenses, note, depose_par, type)
    values (p_entreprise_id, p_periode, p_benefices, p_depenses, p_note, auth.uid(), 'manuel');
  delete from entreprises_logs where entreprise_id = p_entreprise_id;
end; $$;
grant execute on function entreprise_deposer_impot(uuid, text, numeric, numeric, text) to authenticated;

-- Rapport automatique, généré depuis les logs (template période : "AAAA-MM").
create or replace function entreprise_generer_rapport_auto(p_entreprise_id uuid, p_periode text)
returns entreprises_depots_impots language plpgsql security definer set search_path = public as $$
declare
  v_ancien_benefices numeric; v_tresor numeric; v_benefices numeric; v_depenses numeric;
  v_virements_tiers jsonb; v_ajouts_fonds jsonb; v_virements_ent jsonb; v_capitaux jsonb; v_salaires jsonb;
  v_tiers_pct numeric; v_pdg_pct numeric; v_row entreprises_depots_impots; v_mon_role text;
begin
  select role into v_mon_role from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_mon_role not in ('pdg','co_pdg') and not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  if exists(select 1 from entreprises_depots_impots where entreprise_id = p_entreprise_id and periode = p_periode) then
    raise exception 'Un rapport (manuel ou automatique) existe déjà pour cette période.';
  end if;

  select benefices into v_ancien_benefices from entreprises_depots_impots
    where entreprise_id = p_entreprise_id order by cree_le desc limit 1;
  select tresorerie into v_tresor from entreprises where id = p_entreprise_id;
  v_benefices := v_tresor - coalesce(v_ancien_benefices, 0);

  select coalesce(sum((donnees->>'montant')::numeric), 0) into v_depenses
    from entreprises_logs where entreprise_id = p_entreprise_id
    and type in ('depense','paiement_employe','virement_tiers','virement_entreprise');

  select coalesce(jsonb_agg(jsonb_build_object('destinataire_username', donnees->>'destinataire_username', 'montant', donnees->>'montant')), '[]'::jsonb)
    into v_virements_tiers from entreprises_logs where entreprise_id = p_entreprise_id and type = 'virement_tiers';

  select coalesce(jsonb_agg(jsonb_build_object('username', c.username, 'montant', l.donnees->>'montant')), '[]'::jsonb)
    into v_ajouts_fonds from entreprises_logs l left join citoyens c on c.id = (l.donnees->>'citoyen_id')::uuid
    where l.entreprise_id = p_entreprise_id and l.type = 'ajout_fonds';

  select coalesce(jsonb_agg(jsonb_build_object('entreprise_dest_nom', donnees->>'entreprise_dest_nom', 'montant', donnees->>'montant')), '[]'::jsonb)
    into v_virements_ent from entreprises_logs where entreprise_id = p_entreprise_id and type = 'virement_entreprise';

  select coalesce(jsonb_agg(jsonb_build_object('acheteur_username', donnees->>'acheteur_username', 'pourcentage', donnees->>'pourcentage')), '[]'::jsonb)
    into v_capitaux from entreprises_logs where entreprise_id = p_entreprise_id and type = 'vente_capital';

  select coalesce(jsonb_agg(jsonb_build_object(
      'username', c.username, 'montant_recu', (l.donnees->>'montant')::numeric,
      'heures', l.donnees->>'heures', 'taux', l.donnees->>'taux'
    )), '[]'::jsonb) into v_salaires
    from entreprises_logs l join citoyens c on c.id = (l.donnees->>'citoyen_id')::uuid
    where l.entreprise_id = p_entreprise_id and l.type = 'paiement_employe';

  select coalesce(sum(pourcentage), 0) into v_tiers_pct from entreprises_capital_detenteurs where entreprise_id = p_entreprise_id;
  v_pdg_pct := 100 - v_tiers_pct;

  insert into entreprises_depots_impots (entreprise_id, periode, benefices, depenses, note, depose_par, type, details, capital_pdg_pct, capital_tiers_pct)
  values (p_entreprise_id, p_periode, v_benefices, v_depenses, 'Généré automatiquement', auth.uid(), 'automatique',
    jsonb_build_object('virements_tiers', v_virements_tiers, 'ajouts_fonds', v_ajouts_fonds,
      'virements_entreprises', v_virements_ent, 'capitaux_vendus', v_capitaux, 'salaires', v_salaires),
    v_pdg_pct, v_tiers_pct)
  returning * into v_row;

  delete from entreprises_logs where entreprise_id = p_entreprise_id;
  return v_row;
end; $$;
grant execute on function entreprise_generer_rapport_auto(uuid, text) to authenticated;

-- Consultation publique : nom d'entreprise -> tous ses relevés (noms en clair).
create or replace function rapport_impot_public(p_nom_entreprise text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_ent entreprises; v_rapports jsonb;
begin
  select * into v_ent from entreprises where lower(nom) = lower(trim(p_nom_entreprise)) and statut = 'acceptee';
  if v_ent is null then raise exception 'Entreprise introuvable.'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'periode', periode, 'type', type, 'benefices', benefices, 'depenses', depenses, 'note', note,
    'details', details, 'capital_pdg_pct', capital_pdg_pct, 'capital_tiers_pct', capital_tiers_pct, 'cree_le', cree_le
  ) order by cree_le desc), '[]'::jsonb) into v_rapports
  from entreprises_depots_impots where entreprise_id = v_ent.id;

  return jsonb_build_object(
    'id', v_ent.id, 'nom', v_ent.nom, 'code', v_ent.code, 'sieges', v_ent.sieges, 'type_vente', v_ent.type_vente,
    'mode_vente', v_ent.mode_vente, 'cree_le', v_ent.cree_le, 'rapports', v_rapports
  );
end; $$;
grant execute on function rapport_impot_public(text) to authenticated, anon;


-- ============================================================
-- 8) INFOS PERSONNELLES + CHANGEMENT D'EMAIL
-- ============================================================
-- Le changement de MOT DE PASSE se fait entièrement côté client via
-- sb.auth.updateUser({ password: ... }) (session déjà authentifiée) —
-- aucune fonction SQL requise. Ci-dessous : lecture groupée des infos +
-- changement d'email (touche auth.users directement, comme le fait déjà
-- admin_supprimer_compte dans ce projet).
create or replace function mes_infos_personnelles()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_c citoyens;
begin
  select * into v_c from citoyens where id = auth.uid();
  if v_c is null then raise exception 'Non authentifié.'; end if;
  return jsonb_build_object(
    'username', v_c.username, 'email', v_c.email, 'nom_complet', v_c.nom_complet,
    'date_naissance', v_c.date_naissance, 'cree_le', v_c.cree_le,
    'est_agent_paix', v_c.est_agent_paix, 'salaire_brut_minute', v_c.salaire,
    'taux_revenu', v_c.taux_revenu,
    'salaire_net_minute', v_c.salaire - (v_c.salaire * v_c.taux_revenu / 100.0),
    'code_social_encrypte', v_c.code_social_encrypte
  );
end; $$;
grant execute on function mes_infos_personnelles() to authenticated;

create or replace function changer_mon_email(p_nouvel_email text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if p_nouvel_email is null or char_length(trim(p_nouvel_email)) = 0 then raise exception 'Email requis.'; end if;
  update auth.users set email = trim(p_nouvel_email) where id = auth.uid();
  update citoyens set email = trim(p_nouvel_email) where id = auth.uid();
end; $$;
grant execute on function changer_mon_email(text) to authenticated;


-- ============================================================
-- 9) MISE À JOUR de mes_entreprises() et entreprise_detail()
--    (exposent mode de paiement, droits, rôles, heures, CIB membres,
--    dettes, options, rapports détaillés)
-- ============================================================
create or replace function mes_entreprises()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id, 'code', e.code, 'nom', e.nom, 'role', m.role, 'tresorerie', e.tresorerie,
    'mode_paiement', e.mode_paiement, 'salaire_horaire', m.salaire_horaire,
    'type', _type_entreprise((select count(*)::int from entreprises_membres m2 where m2.entreprise_id = e.id))
  )), '[]'::jsonb)
  from entreprises_membres m join entreprises e on e.id = m.entreprise_id
  where m.citoyen_id = auth.uid() and e.statut = 'acceptee';
$$;
grant execute on function mes_entreprises() to authenticated;

create or replace function entreprise_detail(p_entreprise_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_e public.entreprises; v_mon_role text; v_membres jsonb; v_depots jsonb; v_roles jsonb; v_voit boolean;
begin
  select * into v_e from entreprises where id = p_entreprise_id;
  if v_e is null then raise exception 'Entreprise introuvable.'; end if;
  select role into v_mon_role from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_mon_role is null and not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  v_voit := _entreprise_a_droit(p_entreprise_id, 'payer_employe') or _entreprise_a_droit(p_entreprise_id, 'ajouter_employe');

  select coalesce(jsonb_agg(jsonb_build_object(
      'username', c.username, 'nom_complet', coalesce(c.nom_complet, c.prenom || ' ' || c.nom),
      'role', m.role, 'role_id', m.role_id, 'role_nom', r.nom,
      'salaire_horaire', m.salaire_horaire, 'citoyen_id', m.citoyen_id,
      'cib', case when v_voit or m.citoyen_id = auth.uid() then m.cib end,
      'heures', case when v_voit or m.citoyen_id = auth.uid() then
         (select coalesce(jsonb_agg(jsonb_build_object('taux', h.taux, 'heures', h.heures) order by h.taux), '[]'::jsonb)
          from entreprises_membres_heures h where h.entreprise_id = m.entreprise_id and h.citoyen_id = m.citoyen_id and h.heures > 0)
         else '[]'::jsonb end
    )), '[]'::jsonb)
    into v_membres from entreprises_membres m join citoyens c on c.id = m.citoyen_id
    left join entreprises_roles r on r.id = m.role_id where m.entreprise_id = p_entreprise_id;

  select coalesce(jsonb_agg(jsonb_build_object('periode', periode, 'type', type, 'benefices', benefices,
      'depenses', depenses, 'note', note, 'details', details, 'capital_pdg_pct', capital_pdg_pct,
      'capital_tiers_pct', capital_tiers_pct, 'cree_le', cree_le) order by cree_le desc), '[]'::jsonb)
    into v_depots from entreprises_depots_impots where entreprise_id = p_entreprise_id;

  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nom', nom, 'droits', droits) order by nom), '[]'::jsonb)
    into v_roles from entreprises_roles where entreprise_id = p_entreprise_id;

  return jsonb_build_object(
    'id', v_e.id, 'code', v_e.code, 'nom', v_e.nom, 'tresorerie', v_e.tresorerie, 'sieges', v_e.sieges,
    'type', _type_entreprise(jsonb_array_length(v_membres)), 'mon_role', v_mon_role,
    'membres', v_membres, 'depots_impots', v_depots, 'roles', v_roles,
    'mes_droits', entreprise_mes_droits(p_entreprise_id), 'droits_co_pdg', v_e.droits_co_pdg,
    'mode_paiement', v_e.mode_paiement, 'option_defaillance', v_e.option_defaillance,
    'dette_salariale_gouv', v_e.dette_salariale_gouv, 'dette_salariale_employes', v_e.dette_salariale_employes,
    'option3_cibs', case when _entreprise_a_droit(p_entreprise_id, 'definir_mode_paiement') then to_jsonb(v_e.option3_cibs) else '[]'::jsonb end,
    'capital_en_vente_pct', v_e.capital_en_vente_pct, 'capital_max_par_individu', v_e.capital_max_par_individu,
    'capital_prix_par_centieme', v_e.capital_prix_par_centieme, 'capital_min_achat_pct', v_e.capital_min_achat_pct
  );
end; $$;
grant execute on function entreprise_detail(uuid) to authenticated;

-- ============================================================
-- FIN
-- ============================================================
