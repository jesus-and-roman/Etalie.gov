-- ============================================================
-- patch-cib-entreprise-avancee-9.sql
-- À exécuter après patch-cib-entreprise-avancee-8.sql. Additif et rejouable.
--
--  1. DOCUMENTS PDF AU GOUVERNEMENT : upload vers un bucket Supabase
--     Storage privé ("documents-citoyens"), avec table de suivi.
--  2. BREVETS / DROITS D'AUTEUR : demande (PDF obligatoire + nombreux
--     champs), acceptation par le gouvernement, numéro de suivi, liste
--     publique + recherche, détenteurs multiples (citoyen OU entreprise
--     par code E-XXXXXXXX), modification des infos par les détenteurs,
--     autorisations d'usage accordées à des tiers (citoyen ou entreprise).
--
-- HYPOTHÈSE : les champs demandés pour l'approbation ("plein d'infos")
-- ne sont pas listés un par un dans la demande — j'ai repris un jeu de
-- champs standard pour ce type de dépôt (titre, description, catégorie,
-- domaine d'application, revendications, date de création). Facile à
-- étendre si des champs précis manquent.
-- ============================================================


-- ============================================================
-- 1) STORAGE : bucket privé pour les documents envoyés au gouvernement
-- ============================================================
insert into storage.buckets (id, name, public)
values ('documents-citoyens', 'documents-citoyens', false)
on conflict (id) do nothing;

drop policy if exists "Déposer ses propres documents" on storage.objects;
create policy "Déposer ses propres documents" on storage.objects for insert to authenticated
  with check (bucket_id = 'documents-citoyens' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "Voir ses propres documents ou tout si admin" on storage.objects;
create policy "Voir ses propres documents ou tout si admin" on storage.objects for select to authenticated
  using (bucket_id = 'documents-citoyens' and ((storage.foldername(name))[1] = auth.uid()::text or est_admin_actuel()));

-- Bucket public pour les PDF de brevets/copyright (justificatifs lisibles une fois acceptés).
insert into storage.buckets (id, name, public)
values ('brevets-pdf', 'brevets-pdf', true)
on conflict (id) do nothing;

drop policy if exists "Déposer un PDF de brevet" on storage.objects;
create policy "Déposer un PDF de brevet" on storage.objects for insert to authenticated
  with check (bucket_id = 'brevets-pdf' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "Lecture publique des PDF de brevets" on storage.objects;
create policy "Lecture publique des PDF de brevets" on storage.objects for select
  using (bucket_id = 'brevets-pdf');


-- ============================================================
-- 2) DOCUMENTS PDF ENVOYÉS AU GOUVERNEMENT
-- ============================================================
create table if not exists documents_gouv (
  id            uuid primary key default gen_random_uuid(),
  citoyen_id    uuid not null references auth.users(id),
  titre         text not null,
  note          text,
  chemin_fichier text not null,
  statut        text not null default 'en_attente' check (statut in ('en_attente','traite')),
  note_gouv     text,
  cree_le       timestamptz not null default now(),
  traite_le     timestamptz
);
alter table documents_gouv enable row level security;
drop policy if exists "Voir ses documents ou tout si admin" on documents_gouv;
create policy "Voir ses documents ou tout si admin" on documents_gouv for select
  using (citoyen_id = auth.uid() or est_admin_actuel());

create or replace function soumettre_document_gouv(p_titre text, p_chemin_fichier text, p_note text default null)
returns documents_gouv language plpgsql security definer set search_path = public as $$
declare v_row documents_gouv;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if p_titre is null or char_length(trim(p_titre)) = 0 then raise exception 'Titre requis.'; end if;
  if p_chemin_fichier is null or (storage.foldername(p_chemin_fichier))[1] <> auth.uid()::text then
    raise exception 'Fichier invalide.';
  end if;
  insert into documents_gouv (citoyen_id, titre, note, chemin_fichier) values (auth.uid(), trim(p_titre), p_note, p_chemin_fichier)
    returning * into v_row;
  return v_row;
end; $$;
grant execute on function soumettre_document_gouv(text, text, text) to authenticated;

create or replace function mes_documents_gouv()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(row_to_json(d) order by cree_le desc), '[]'::jsonb) from documents_gouv where citoyen_id = auth.uid();
$$;
grant execute on function mes_documents_gouv() to authenticated;

create or replace function gouv_liste_documents(p_statut text default 'en_attente')
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not est_admin_actuel() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
    'id', d.id, 'username', c.username, 'titre', d.titre, 'note', d.note, 'chemin_fichier', d.chemin_fichier, 'cree_le', d.cree_le
  ) order by d.cree_le), '[]'::jsonb) end
  from documents_gouv d join citoyens c on c.id = d.citoyen_id where d.statut = p_statut;
$$;
grant execute on function gouv_liste_documents(text) to authenticated;

create or replace function gouv_traiter_document(p_id uuid, p_note_gouv text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  update documents_gouv set statut = 'traite', note_gouv = p_note_gouv, traite_le = now() where id = p_id;
end; $$;
grant execute on function gouv_traiter_document(uuid, text) to authenticated;


-- ============================================================
-- 3) BREVETS / DROITS D'AUTEUR
-- ============================================================
create table if not exists brevets (
  id                 uuid primary key default gen_random_uuid(),
  numero_suivi       text not null unique,
  type               text not null check (type in ('brevet','copyright')),
  titre              text not null,
  description        text not null,
  categorie          text,
  domaine_application text,
  revendications     text,
  date_creation      date,
  chemin_pdf         text not null,
  demandeur_id       uuid not null references auth.users(id),
  statut             text not null default 'en_attente' check (statut in ('en_attente','accepte','refuse')),
  motif_refus        text,
  cree_le            timestamptz not null default now(),
  traite_le          timestamptz
);
alter table brevets enable row level security;
drop policy if exists "Lecture publique des brevets acceptés, ou siens, ou tout si admin" on brevets;
create policy "Lecture publique des brevets acceptés, ou siens, ou tout si admin" on brevets for select
  using (statut = 'accepte' or demandeur_id = auth.uid() or est_admin_actuel());

create table if not exists brevets_detenteurs (
  id            uuid primary key default gen_random_uuid(),
  brevet_id     uuid not null references brevets(id) on delete cascade,
  citoyen_id    uuid references auth.users(id),
  entreprise_id uuid references entreprises(id),
  ajoute_le     timestamptz not null default now(),
  check ((citoyen_id is not null)::int + (entreprise_id is not null)::int = 1),
  unique (brevet_id, citoyen_id, entreprise_id)
);
alter table brevets_detenteurs enable row level security;
drop policy if exists "Lecture publique des détenteurs de brevets" on brevets_detenteurs;
create policy "Lecture publique des détenteurs de brevets" on brevets_detenteurs for select using (true);

create table if not exists brevets_autorisations (
  id            uuid primary key default gen_random_uuid(),
  brevet_id     uuid not null references brevets(id) on delete cascade,
  citoyen_id    uuid references auth.users(id),
  entreprise_id uuid references entreprises(id),
  accorde_le    timestamptz not null default now(),
  check ((citoyen_id is not null)::int + (entreprise_id is not null)::int = 1),
  unique (brevet_id, citoyen_id, entreprise_id)
);
alter table brevets_autorisations enable row level security;
drop policy if exists "Lecture publique des autorisations de brevets" on brevets_autorisations;
create policy "Lecture publique des autorisations de brevets" on brevets_autorisations for select using (true);

create or replace function _est_detenteur_brevet(p_brevet_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from brevets_detenteurs d where d.brevet_id = p_brevet_id and (
      d.citoyen_id = auth.uid()
      or d.entreprise_id in (select entreprise_id from entreprises_membres where citoyen_id = auth.uid() and role in ('pdg','co_pdg'))
    )
  );
$$;

create or replace function demander_brevet(
  p_type text, p_titre text, p_description text, p_chemin_pdf text, p_categorie text default null,
  p_domaine_application text default null, p_revendications text default null, p_date_creation date default null
) returns brevets language plpgsql security definer set search_path = public as $$
declare v_row brevets; v_numero text;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if p_type not in ('brevet','copyright') then raise exception 'Type invalide (brevet ou copyright).'; end if;
  if p_titre is null or char_length(trim(p_titre)) = 0 then raise exception 'Titre requis.'; end if;
  if p_description is null or char_length(trim(p_description)) < 20 then raise exception 'Description requise (20 caractères minimum).'; end if;
  if p_chemin_pdf is null or (storage.foldername(p_chemin_pdf))[1] <> auth.uid()::text then raise exception 'PDF requis.'; end if;

  v_numero := 'BR-' || upper(_generer_code_alnum(8));
  insert into brevets (numero_suivi, type, titre, description, categorie, domaine_application, revendications, date_creation, chemin_pdf, demandeur_id)
    values (v_numero, p_type, trim(p_titre), trim(p_description), p_categorie, p_domaine_application, p_revendications, p_date_creation, p_chemin_pdf, auth.uid())
    returning * into v_row;
  insert into brevets_detenteurs (brevet_id, citoyen_id) values (v_row.id, auth.uid());
  return v_row;
end; $$;
grant execute on function demander_brevet(text, text, text, text, text, text, text, date) to authenticated;

create or replace function gouv_liste_brevets(p_statut text default 'en_attente')
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not est_admin_actuel() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
    'id', b.id, 'numero_suivi', b.numero_suivi, 'type', b.type, 'titre', b.titre, 'description', b.description,
    'categorie', b.categorie, 'domaine_application', b.domaine_application, 'revendications', b.revendications,
    'date_creation', b.date_creation, 'chemin_pdf', b.chemin_pdf, 'demandeur_username', c.username, 'cree_le', b.cree_le
  ) order by b.cree_le), '[]'::jsonb) end
  from brevets b join citoyens c on c.id = b.demandeur_id where b.statut = p_statut;
$$;
grant execute on function gouv_liste_brevets(text) to authenticated;

create or replace function gouv_traiter_brevet(p_id uuid, p_decision text, p_motif_refus text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  if p_decision not in ('accepte','refuse') then raise exception 'Décision invalide.'; end if;
  update brevets set statut = p_decision, motif_refus = p_motif_refus, traite_le = now()
    where id = p_id and statut = 'en_attente';
  if not found then raise exception 'Demande introuvable ou déjà traitée.'; end if;
end; $$;
grant execute on function gouv_traiter_brevet(uuid, text, text) to authenticated;

create or replace function mes_demandes_brevets()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(row_to_json(b) order by cree_le desc), '[]'::jsonb) from brevets where demandeur_id = auth.uid();
$$;
grant execute on function mes_demandes_brevets() to authenticated;

-- Ajouter un détenteur : par nom d'utilisateur (citoyen) ou code d'entreprise E-XXXXXXXX.
create or replace function brevet_ajouter_detenteur(p_numero_suivi text, p_identifiant text)
returns void language plpgsql security definer set search_path = public as $$
declare v_brevet uuid; v_cid uuid; v_eid uuid;
begin
  select id into v_brevet from brevets where numero_suivi = p_numero_suivi and statut = 'accepte';
  if v_brevet is null then raise exception 'Brevet introuvable ou non accepté.'; end if;
  if not _est_detenteur_brevet(v_brevet) then raise exception 'Réservé aux détenteurs de ce brevet.'; end if;

  if p_identifiant ~ '^E-' then
    select id into v_eid from entreprises where code = upper(p_identifiant) and statut = 'acceptee';
    if v_eid is null then raise exception 'Entreprise introuvable.'; end if;
    insert into brevets_detenteurs (brevet_id, entreprise_id) values (v_brevet, v_eid) on conflict do nothing;
  else
    select id into v_cid from citoyens where lower(username) = lower(trim(p_identifiant));
    if v_cid is null then raise exception 'Citoyen introuvable.'; end if;
    insert into brevets_detenteurs (brevet_id, citoyen_id) values (v_brevet, v_cid) on conflict do nothing;
  end if;
end; $$;
grant execute on function brevet_ajouter_detenteur(text, text) to authenticated;

create or replace function brevet_retirer_detenteur(p_numero_suivi text, p_detenteur_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_brevet uuid;
begin
  select id into v_brevet from brevets where numero_suivi = p_numero_suivi and statut = 'accepte';
  if v_brevet is null then raise exception 'Brevet introuvable.'; end if;
  if not _est_detenteur_brevet(v_brevet) then raise exception 'Réservé aux détenteurs de ce brevet.'; end if;
  if (select count(*) from brevets_detenteurs where brevet_id = v_brevet) <= 1 then
    raise exception 'Impossible de retirer le dernier détenteur.';
  end if;
  delete from brevets_detenteurs where id = p_detenteur_id and brevet_id = v_brevet;
end; $$;
grant execute on function brevet_retirer_detenteur(uuid, uuid) to authenticated;

-- Modifier les infos (titre/description/catégorie/domaine/revendications) : détenteurs seulement.
create or replace function brevet_modifier_infos(p_numero_suivi text, p_titre text, p_description text, p_categorie text, p_domaine_application text, p_revendications text)
returns void language plpgsql security definer set search_path = public as $$
declare v_brevet uuid;
begin
  select id into v_brevet from brevets where numero_suivi = p_numero_suivi and statut = 'accepte';
  if v_brevet is null then raise exception 'Brevet introuvable.'; end if;
  if not _est_detenteur_brevet(v_brevet) then raise exception 'Réservé aux détenteurs de ce brevet.'; end if;
  update brevets set
    titre = coalesce(nullif(trim(p_titre), ''), titre),
    description = coalesce(nullif(trim(p_description), ''), description),
    categorie = p_categorie, domaine_application = p_domaine_application, revendications = p_revendications
    where id = v_brevet;
end; $$;
grant execute on function brevet_modifier_infos(text, text, text, text, text, text) to authenticated;

-- Autoriser un tiers (citoyen ou entreprise) à utiliser le brevet.
create or replace function brevet_accorder_autorisation(p_numero_suivi text, p_identifiant text)
returns void language plpgsql security definer set search_path = public as $$
declare v_brevet uuid; v_cid uuid; v_eid uuid;
begin
  select id into v_brevet from brevets where numero_suivi = p_numero_suivi and statut = 'accepte';
  if v_brevet is null then raise exception 'Brevet introuvable ou non accepté.'; end if;
  if not _est_detenteur_brevet(v_brevet) then raise exception 'Réservé aux détenteurs de ce brevet.'; end if;

  if p_identifiant ~ '^E-' then
    select id into v_eid from entreprises where code = upper(p_identifiant) and statut = 'acceptee';
    if v_eid is null then raise exception 'Entreprise introuvable.'; end if;
    insert into brevets_autorisations (brevet_id, entreprise_id) values (v_brevet, v_eid) on conflict do nothing;
  else
    select id into v_cid from citoyens where lower(username) = lower(trim(p_identifiant));
    if v_cid is null then raise exception 'Citoyen introuvable.'; end if;
    insert into brevets_autorisations (brevet_id, citoyen_id) values (v_brevet, v_cid) on conflict do nothing;
  end if;
end; $$;
grant execute on function brevet_accorder_autorisation(text, text) to authenticated;

create or replace function brevet_retirer_autorisation(p_autorisation_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_brevet uuid;
begin
  select brevet_id into v_brevet from brevets_autorisations where id = p_autorisation_id;
  if v_brevet is null or not _est_detenteur_brevet(v_brevet) then raise exception 'Réservé aux détenteurs de ce brevet.'; end if;
  delete from brevets_autorisations where id = p_autorisation_id;
end; $$;
grant execute on function brevet_retirer_autorisation(uuid) to authenticated;

-- Recherche publique + fiche détaillée (par numéro de suivi ou mot-clé dans le titre).
create or replace function rechercher_brevets(p_recherche text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('numero_suivi', numero_suivi, 'type', type, 'titre', titre, 'categorie', categorie, 'cree_le', cree_le) order by cree_le desc), '[]'::jsonb)
  from brevets where statut = 'accepte' and (numero_suivi ilike '%' || trim(p_recherche) || '%' or titre ilike '%' || trim(p_recherche) || '%');
$$;
grant execute on function rechercher_brevets(text) to authenticated, anon;

create or replace function brevet_detail(p_numero_suivi text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b brevets; v_detenteurs jsonb; v_autorisations jsonb;
begin
  select * into b from brevets where numero_suivi = p_numero_suivi and statut = 'accepte';
  if b.id is null then raise exception 'Brevet introuvable.'; end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'username', c.username, 'entreprise', e.nom, 'entreprise_code', e.code)), '[]'::jsonb)
    into v_detenteurs from brevets_detenteurs d left join citoyens c on c.id = d.citoyen_id left join entreprises e on e.id = d.entreprise_id
    where d.brevet_id = b.id;
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'username', c.username, 'entreprise', e.nom, 'entreprise_code', e.code)), '[]'::jsonb)
    into v_autorisations from brevets_autorisations a left join citoyens c on c.id = a.citoyen_id left join entreprises e on e.id = a.entreprise_id
    where a.brevet_id = b.id;

  return jsonb_build_object(
    'numero_suivi', b.numero_suivi, 'type', b.type, 'titre', b.titre, 'description', b.description,
    'categorie', b.categorie, 'domaine_application', b.domaine_application, 'revendications', b.revendications,
    'date_creation', b.date_creation, 'chemin_pdf', b.chemin_pdf, 'cree_le', b.cree_le,
    'detenteurs', v_detenteurs, 'autorisations', v_autorisations,
    'mes_droits', _est_detenteur_brevet(b.id)
  );
end; $$;
grant execute on function brevet_detail(text) to authenticated, anon;

-- ============================================================
-- FIN
-- ============================================================
