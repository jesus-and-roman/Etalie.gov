-- ============================================================
-- patch-cib-entreprise-avancee-13.sql
-- À exécuter après patch-cib-entreprise-avancee-12.sql. Additif et rejouable.
--
-- BANQUES PRIVÉES (créées par n'importe qui) :
--  - Type "fructification" : chaque dépôt protège l'argent de l'inflation.
--    À chaque nouveau dépôt, le solde déjà présent est d'abord "réglé" à
--    sa valeur actuelle (selon l'inflation déjà passée depuis le dernier
--    dépôt), puis le nouveau montant s'ajoute, et la base d'inflation est
--    remise au niveau actuel. Le gouvernement peut piger dedans sans
--    permission (voir plus bas), c'est le prix de la protection.
--  - Type "conseil" : pas de protection d'inflation, mais le conseiller
--    désigné (ou le propriétaire lui-même) peut investir l'argent
--    disponible en capital d'entreprises — le capital appartient alors à
--    la banque, pas à une personne.
--  - Banque publique : une fois 10 M R$ ou un titre octroyé par le
--    gouvernement, elle peut se déclarer publique et recevoir des
--    demandes d'adhésion de citoyens.
--
-- HYPOTHÈSE (prélèvement gouvernemental) : le texte donnait d'abord une
-- règle claire ("même pourcentage pour tout le monde") puis une
-- explication plus floue pour protéger les petits comptes. Un
-- prélèvement à POURCENTAGE UNIFORME (montant demandé ÷ total des
-- comptes à fructification) remplit déjà cet objectif : chacun perd la
-- même fraction, donc personne n'est désavantagé relativement aux
-- autres. C'est ce qui est implémenté, littéralement conforme à la
-- phrase "chaque personne devra payer le même montant en pourcentage".
-- Le reste de la gestion "banque publique" (gérer l'épargne des gens à
-- la place d'un conseiller financier, virements du gouvernement vers des
-- banques publiques) reste à construire — seule la déclaration et la
-- demande d'adhésion sont posées ici, pour ne pas improviser un système
-- de délégation complet sans base solide.
-- ============================================================


-- ============================================================
-- 1) BANQUES PRIVÉES
-- ============================================================
create table if not exists banques_privees (
  id               uuid primary key default gen_random_uuid(),
  nom              text not null,
  type             text not null check (type in ('fructification','conseil')),
  proprietaire_id  uuid not null references auth.users(id),
  conseiller_id    uuid references auth.users(id),
  tresorerie       numeric not null default 0,
  publique         boolean not null default false,
  degre_gouvernemental boolean not null default false,
  description      text,
  cree_le          timestamptz not null default now()
);
alter table banques_privees enable row level security;
drop policy if exists "Lecture publique des banques privées" on banques_privees;
create policy "Lecture publique des banques privées" on banques_privees for select using (true);

create table if not exists banques_comptes (
  id             uuid primary key default gen_random_uuid(),
  banque_id      uuid not null references banques_privees(id) on delete cascade,
  citoyen_id     uuid not null references auth.users(id),
  solde          numeric not null default 0,
  inflation_base numeric not null default 0,
  cree_le        timestamptz not null default now(),
  unique (banque_id, citoyen_id)
);
alter table banques_comptes enable row level security;
drop policy if exists "Voir son propre compte, celui de sa banque, ou tout si admin" on banques_comptes;
create policy "Voir son propre compte, celui de sa banque, ou tout si admin" on banques_comptes for select
  using (citoyen_id = auth.uid() or est_admin_actuel()
    or exists (select 1 from banques_privees b where b.id = banques_comptes.banque_id and b.proprietaire_id = auth.uid()));

-- Le capital investi par une banque "conseil" se pose dans la même table
-- que les détenteurs de capital habituels (le trigger de partage des
-- profits fonctionne alors automatiquement, sans modification).
alter table entreprises_capital_detenteurs add column if not exists banque_id uuid references banques_privees(id);
alter table entreprises_capital_detenteurs alter column citoyen_id drop not null;
create unique index if not exists capital_detenteur_banque_unique on entreprises_capital_detenteurs (entreprise_id, banque_id) where banque_id is not null;

create or replace function creer_banque(p_nom text, p_type text, p_conseiller_username text default null)
returns banques_privees language plpgsql security definer set search_path = public as $$
declare v_row banques_privees; v_conseiller uuid;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if p_nom is null or char_length(trim(p_nom)) = 0 then raise exception 'Nom de banque requis.'; end if;
  if p_type not in ('fructification','conseil') then raise exception 'Type de banque invalide.'; end if;
  if p_type = 'conseil' and p_conseiller_username is not null then
    select id into v_conseiller from citoyens where lower(username) = lower(trim(p_conseiller_username));
    if v_conseiller is null then raise exception 'Conseiller introuvable.'; end if;
  else
    v_conseiller := auth.uid();
  end if;
  insert into banques_privees (nom, type, proprietaire_id, conseiller_id) values (trim(p_nom), p_type, auth.uid(), v_conseiller)
    returning * into v_row;
  return v_row;
end; $$;
grant execute on function creer_banque(text, text, text) to authenticated;

create or replace function liste_banques()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', b.id, 'nom', b.nom, 'type', b.type, 'proprietaire', c.username, 'conseiller', cc.username,
    'publique', b.publique, 'degre_gouvernemental', b.degre_gouvernemental, 'description', b.description,
    'tresorerie', case when b.type = 'conseil' then b.tresorerie end,
    'total_fructification', case when b.type = 'fructification' then (select coalesce(sum(_valeur_compte_banque(bc.id)), 0) from banques_comptes bc where bc.banque_id = b.id) end
  ) order by b.nom), '[]'::jsonb)
  from banques_privees b join citoyens c on c.id = b.proprietaire_id left join citoyens cc on cc.id = b.conseiller_id;
$$;
grant execute on function liste_banques() to authenticated, anon;

-- ---- Fructification (indexée sur l'inflation) ----
create or replace function _valeur_compte_banque(p_compte_id uuid)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare bc banques_comptes; v_inflation_actuelle numeric;
begin
  select * into bc from banques_comptes where id = p_compte_id;
  if bc.id is null then return 0; end if;
  v_inflation_actuelle := inflation_pourcentage();
  return round(bc.solde * (1 + v_inflation_actuelle / 100.0) / (1 + bc.inflation_base / 100.0), 4);
end; $$;
grant execute on function _valeur_compte_banque(uuid) to authenticated, anon;

create or replace function banque_deposer(p_banque_id uuid, p_montant numeric)
returns void language plpgsql security definer set search_path = public as $$
declare b banques_privees; bc banques_comptes; v_inflation numeric; v_dispo numeric;
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select * into b from banques_privees where id = p_banque_id;
  if b.id is null then raise exception 'Banque introuvable.'; end if;

  v_dispo := _ma_tresorerie();
  if v_dispo < p_montant then raise exception 'Trésorerie insuffisante.'; end if;
  perform _debiter_ma_tresorerie(p_montant);

  if b.type = 'fructification' then
    v_inflation := inflation_pourcentage();
    select * into bc from banques_comptes where banque_id = p_banque_id and citoyen_id = auth.uid() for update;
    if bc.id is null then
      insert into banques_comptes (banque_id, citoyen_id, solde, inflation_base) values (p_banque_id, auth.uid(), p_montant, v_inflation);
    else
      update banques_comptes set solde = _valeur_compte_banque(bc.id) + p_montant, inflation_base = v_inflation where id = bc.id;
    end if;
  else
    insert into banques_comptes (banque_id, citoyen_id, solde) values (p_banque_id, auth.uid(), p_montant)
      on conflict (banque_id, citoyen_id) do update set solde = banques_comptes.solde + p_montant;
    update banques_privees set tresorerie = tresorerie + p_montant where id = p_banque_id;
  end if;
end; $$;
grant execute on function banque_deposer(uuid, numeric) to authenticated;

create or replace function banque_retirer(p_banque_id uuid, p_montant numeric)
returns void language plpgsql security definer set search_path = public as $$
declare b banques_privees; bc banques_comptes; v_valeur numeric;
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select * into b from banques_privees where id = p_banque_id;
  select * into bc from banques_comptes where banque_id = p_banque_id and citoyen_id = auth.uid() for update;
  if bc.id is null then raise exception 'Aucun compte dans cette banque.'; end if;

  if b.type = 'fructification' then
    v_valeur := _valeur_compte_banque(bc.id);
    if v_valeur < p_montant then raise exception 'Solde insuffisant (disponible : % R$).', v_valeur; end if;
    update banques_comptes set solde = v_valeur - p_montant, inflation_base = inflation_pourcentage() where id = bc.id;
  else
    if bc.solde < p_montant then raise exception 'Solde insuffisant (disponible : % R$).', bc.solde; end if;
    if b.tresorerie < p_montant then raise exception 'Trésorerie de la banque insuffisante (argent investi en capital) : % R$ disponibles.', b.tresorerie; end if;
    update banques_comptes set solde = solde - p_montant where id = bc.id;
    update banques_privees set tresorerie = tresorerie - p_montant where id = p_banque_id;
  end if;
  perform _crediter_ma_tresorerie(p_montant);
end; $$;
grant execute on function banque_retirer(uuid, numeric) to authenticated;

create or replace function mes_comptes_bancaires()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'banque_id', b.id, 'nom', b.nom, 'type', b.type,
    'solde', case when b.type = 'fructification' then _valeur_compte_banque(bc.id) else bc.solde end
  ) order by b.nom), '[]'::jsonb)
  from banques_comptes bc join banques_privees b on b.id = bc.banque_id where bc.citoyen_id = auth.uid();
$$;
grant execute on function mes_comptes_bancaires() to authenticated;

-- ---- Conseil (investissement en capital) ----
create or replace function _est_gestionnaire_banque(p_banque_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from banques_privees where id = p_banque_id and (proprietaire_id = auth.uid() or conseiller_id = auth.uid()));
$$;

create or replace function banque_investir_capital(p_banque_id uuid, p_entreprise_id uuid, p_pourcentage numeric)
returns void language plpgsql security definer set search_path = public as $$
declare b banques_privees; v_ent entreprises; v_cout numeric; v_deja numeric; v_bonus numeric; v_tresor_apres_cout numeric;
begin
  select * into b from banques_privees where id = p_banque_id and type = 'conseil';
  if b.id is null then raise exception 'Banque introuvable (ou pas une banque à conseil).'; end if;
  if not _est_gestionnaire_banque(p_banque_id) then raise exception 'Réservé au propriétaire ou au conseiller de la banque.'; end if;

  select * into v_ent from entreprises where id = p_entreprise_id and statut = 'acceptee' for update;
  if v_ent.id is null or v_ent.capital_prix_par_centieme is null then raise exception 'Aucune offre en cours pour cette entreprise.'; end if;
  if p_pourcentage < v_ent.capital_min_achat_pct or p_pourcentage > v_ent.capital_en_vente_pct then raise exception 'Pourcentage invalide.'; end if;

  v_cout := (p_pourcentage / 0.01) * v_ent.capital_prix_par_centieme;
  if b.tresorerie < v_cout then raise exception 'Trésorerie de la banque insuffisante (coût : % R$).', v_cout; end if;

  v_bonus := round(p_pourcentage / 100.0 * coalesce(v_ent.tresorerie_mise_en_vente, 0), 2);
  v_tresor_apres_cout := v_ent.tresorerie + v_cout;
  v_bonus := least(v_bonus, greatest(v_tresor_apres_cout, 0));

  update banques_privees set tresorerie = tresorerie - v_cout where id = p_banque_id;
  perform _sans_partage(true);
  update entreprises set tresorerie = tresorerie + v_cout - v_bonus, capital_en_vente_pct = capital_en_vente_pct - p_pourcentage where id = p_entreprise_id;
  perform _sans_partage(false);

  insert into entreprises_capital_detenteurs (entreprise_id, banque_id, pourcentage, solde, solde_all_time)
    values (p_entreprise_id, p_banque_id, p_pourcentage, v_bonus, v_bonus)
  on conflict (entreprise_id, banque_id) where banque_id is not null do update set
    pourcentage = entreprises_capital_detenteurs.pourcentage + p_pourcentage,
    solde = entreprises_capital_detenteurs.solde + v_bonus,
    solde_all_time = entreprises_capital_detenteurs.solde_all_time + v_bonus;
  perform _entreprise_regler_dette_employes(p_entreprise_id);
  perform _entreprise_maj_pdg_capital(p_entreprise_id);
end; $$;
grant execute on function banque_investir_capital(uuid, uuid, numeric) to authenticated;

-- Le capital retiré d'une entreprise rejoint la trésorerie disponible de la banque (jamais un dépositaire en particulier).
create or replace function banque_retirer_capital(p_banque_id uuid, p_entreprise_id uuid)
returns numeric language plpgsql security definer set search_path = public as $$
declare v_solde numeric;
begin
  if not _est_gestionnaire_banque(p_banque_id) then raise exception 'Réservé au propriétaire ou au conseiller de la banque.'; end if;
  select solde into v_solde from entreprises_capital_detenteurs where entreprise_id = p_entreprise_id and banque_id = p_banque_id for update;
  if v_solde is null or v_solde <= 0 then raise exception 'Aucun montant à retirer.'; end if;
  update entreprises_capital_detenteurs set solde = 0 where entreprise_id = p_entreprise_id and banque_id = p_banque_id;
  update banques_privees set tresorerie = tresorerie + v_solde where id = p_banque_id;
  return v_solde;
end; $$;
grant execute on function banque_retirer_capital(uuid, uuid) to authenticated;

create or replace function banque_mes_capitaux(p_banque_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('entreprise', e.nom, 'entreprise_id', e.id, 'pourcentage', d.pourcentage, 'solde', d.solde)), '[]'::jsonb)
  from entreprises_capital_detenteurs d join entreprises e on e.id = d.entreprise_id where d.banque_id = p_banque_id;
$$;
grant execute on function banque_mes_capitaux(uuid) to authenticated, anon;

create or replace function banque_modifier_conseiller(p_banque_id uuid, p_conseiller_username text)
returns void language plpgsql security definer set search_path = public as $$
declare v_cid uuid;
begin
  if not exists (select 1 from banques_privees where id = p_banque_id and proprietaire_id = auth.uid()) then
    raise exception 'Réservé au propriétaire de la banque.';
  end if;
  if p_conseiller_username is null or trim(p_conseiller_username) = '' then
    update banques_privees set conseiller_id = auth.uid() where id = p_banque_id;
  else
    select id into v_cid from citoyens where lower(username) = lower(trim(p_conseiller_username));
    if v_cid is null then raise exception 'Conseiller introuvable.'; end if;
    update banques_privees set conseiller_id = v_cid where id = p_banque_id;
  end if;
end; $$;
grant execute on function banque_modifier_conseiller(uuid, text) to authenticated;

create or replace function banque_dissoudre(p_banque_id uuid, p_mdp text)
returns void language plpgsql security definer set search_path = public as $$
declare b banques_privees; bc record;
begin
  select * into b from banques_privees where id = p_banque_id;
  if b.id is null or b.proprietaire_id <> auth.uid() then raise exception 'Réservé au propriétaire de la banque.'; end if;
  if not _verifier_mdp(p_mdp) then raise exception 'Mot de passe incorrect.'; end if;
  if exists (select 1 from entreprises_capital_detenteurs where banque_id = p_banque_id and pourcentage > 0) then
    raise exception 'La banque détient encore du capital d''entreprise : retirez-le d''abord.';
  end if;
  for bc in select * from banques_comptes where banque_id = p_banque_id loop
    update citoyens set tresorerie = tresorerie + (case when b.type = 'fructification' then _valeur_compte_banque(bc.id) else bc.solde end)
      where id = bc.citoyen_id;
  end loop;
  delete from banques_privees where id = p_banque_id;
end; $$;
grant execute on function banque_dissoudre(uuid, text) to authenticated;


-- ============================================================
-- 2) PRÉLÈVEMENT GOUVERNEMENTAL DANS LES BANQUES À FRUCTIFICATION
-- ============================================================
create or replace function gouv_piger_banques_fructification(p_montant_demande numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_total numeric; v_pourcentage numeric; v_preleve numeric := 0; bc record; v_part numeric;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  if p_montant_demande <= 0 then raise exception 'Montant invalide.'; end if;

  select coalesce(sum(_valeur_compte_banque(bc2.id)), 0) into v_total
    from banques_comptes bc2 join banques_privees b on b.id = bc2.banque_id where b.type = 'fructification';
  if v_total <= 0 then return jsonb_build_object('preleve', 0, 'pourcentage', 0); end if;

  v_pourcentage := least(1, p_montant_demande / v_total);
  for bc in select bc2.id, _valeur_compte_banque(bc2.id) as valeur from banques_comptes bc2
      join banques_privees b on b.id = bc2.banque_id where b.type = 'fructification' loop
    v_part := round(bc.valeur * v_pourcentage, 4);
    update banques_comptes set solde = bc.valeur - v_part, inflation_base = inflation_pourcentage() where id = bc.id;
    v_preleve := v_preleve + v_part;
  end loop;
  update tresor_public set solde = solde + v_preleve where id = 1;
  return jsonb_build_object('preleve', round(v_preleve, 2), 'pourcentage', round(v_pourcentage * 100, 4));
end; $$;
grant execute on function gouv_piger_banques_fructification(numeric) to authenticated;

create or replace function gouv_total_banques_privees()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not est_admin_actuel() then '{}'::jsonb else jsonb_build_object(
    'total_fructification', (select coalesce(sum(_valeur_compte_banque(bc.id)), 0) from banques_comptes bc join banques_privees b on b.id = bc.banque_id where b.type = 'fructification'),
    'total_conseil', (select coalesce(sum(tresorerie), 0) from banques_privees where type = 'conseil'),
    'nb_banques', (select count(*) from banques_privees)
  ) end;
$$;
grant execute on function gouv_total_banques_privees() to authenticated;


-- ============================================================
-- 3) BANQUE PUBLIQUE (déclaration + octroi gouvernemental + demandes d'adhésion)
-- ============================================================
create or replace function banque_declarer_publique(p_banque_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare b banques_privees; v_total numeric;
begin
  select * into b from banques_privees where id = p_banque_id;
  if b.id is null or b.proprietaire_id <> auth.uid() then raise exception 'Réservé au propriétaire de la banque.'; end if;
  if b.publique then raise exception 'Cette banque est déjà publique.'; end if;
  if b.degre_gouvernemental then
    update banques_privees set publique = true where id = p_banque_id; return;
  end if;
  v_total := case when b.type = 'fructification'
    then (select coalesce(sum(_valeur_compte_banque(bc.id)), 0) from banques_comptes bc where bc.banque_id = p_banque_id)
    else b.tresorerie end;
  if v_total < 10000000 then raise exception 'La banque doit atteindre 10 000 000 R$ (actuellement : % R$), ou recevoir un titre du gouvernement.', round(v_total, 2); end if;
  update banques_privees set publique = true where id = p_banque_id;
end; $$;
grant execute on function banque_declarer_publique(uuid) to authenticated;

create or replace function gouv_octroyer_degre_banque(p_banque_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  update banques_privees set degre_gouvernemental = true where id = p_banque_id;
  if not found then raise exception 'Banque introuvable.'; end if;
end; $$;
grant execute on function gouv_octroyer_degre_banque(uuid) to authenticated;

create table if not exists banques_demandes_adhesion (
  id         uuid primary key default gen_random_uuid(),
  banque_id  uuid not null references banques_privees(id) on delete cascade,
  citoyen_id uuid not null references auth.users(id),
  motif      text not null,
  statut     text not null default 'en_attente' check (statut in ('en_attente','acceptee','refusee')),
  cree_le    timestamptz not null default now()
);
alter table banques_demandes_adhesion enable row level security;
drop policy if exists "Voir ses demandes d'adhésion ou celles de sa banque" on banques_demandes_adhesion;
create policy "Voir ses demandes d'adhésion ou celles de sa banque" on banques_demandes_adhesion for select
  using (citoyen_id = auth.uid() or est_admin_actuel()
    or exists (select 1 from banques_privees b where b.id = banques_demandes_adhesion.banque_id and b.proprietaire_id = auth.uid()));

create or replace function demander_adhesion_banque(p_banque_id uuid, p_motif text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from banques_privees where id = p_banque_id and publique) then raise exception 'Cette banque n''est pas publique.'; end if;
  if p_motif is null or char_length(trim(p_motif)) < 10 then raise exception 'Justification requise (10 caractères minimum).'; end if;
  if exists (select 1 from banques_demandes_adhesion where banque_id = p_banque_id and citoyen_id = auth.uid() and statut = 'en_attente') then
    raise exception 'Une demande est déjà en attente.';
  end if;
  insert into banques_demandes_adhesion (banque_id, citoyen_id, motif) values (p_banque_id, auth.uid(), trim(p_motif));
end; $$;
grant execute on function demander_adhesion_banque(uuid, text) to authenticated;

create or replace function banque_traiter_adhesion(p_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
declare v_banque uuid;
begin
  select banque_id into v_banque from banques_demandes_adhesion where id = p_id and statut = 'en_attente';
  if v_banque is null then raise exception 'Demande introuvable ou déjà traitée.'; end if;
  if not _est_gestionnaire_banque(v_banque) then raise exception 'Réservé au propriétaire ou au conseiller de la banque.'; end if;
  if p_decision not in ('acceptee','refusee') then raise exception 'Décision invalide.'; end if;
  update banques_demandes_adhesion set statut = p_decision where id = p_id;
end; $$;
grant execute on function banque_traiter_adhesion(uuid, text) to authenticated;

create or replace function banque_demandes_adhesion(p_banque_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'username', c.username, 'motif', d.motif, 'cree_le', d.cree_le) order by d.cree_le), '[]'::jsonb)
  from banques_demandes_adhesion d join citoyens c on c.id = d.citoyen_id where d.banque_id = p_banque_id and d.statut = 'en_attente';
$$;
grant execute on function banque_demandes_adhesion(uuid) to authenticated;

-- ============================================================
-- FIN
-- ============================================================
