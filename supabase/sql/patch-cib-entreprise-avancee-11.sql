-- ============================================================
-- patch-cib-entreprise-avancee-11.sql
-- À exécuter après patch-cib-entreprise-avancee-10.sql. Additif et rejouable.
--
--  1. BAN / KICK / MAINTENANCE : le compte reste normalement inscrit
--     (pas de suppression), mais la connexion est bloquée. Vérifié
--     juste après la connexion Supabase Auth (qui, elle, ne sait rien de
--     ça) : le client appelle verifier_acces_connexion() et, si bloqué,
--     se déconnecte immédiatement et affiche le message. Pas une
--     sécurité blindée (une session déjà ouverte avant le ban continue
--     de fonctionner jusqu'à la prochaine vérification), mais cohérent
--     avec le reste du site.
--  2. CONTESTATION DE CONSTAT : à la place de payer, le citoyen peut
--     contester avec un motif et, optionnellement, une preuve (PDF/image,
--     bucket "documents-citoyens" déjà créé par le patch 9). Le paiement
--     est bloqué tant qu'une contestation est en attente. Si acceptée,
--     le constat est annulé (aucun montant à payer) ; si refusée, le
--     constat redevient payable normalement.
-- ============================================================


-- ============================================================
-- 1) BAN / KICK / MAINTENANCE
-- ============================================================
alter table citoyens add column if not exists compte_banni boolean not null default false;
alter table citoyens add column if not exists compte_banni_motif text;
alter table citoyens add column if not exists compte_suspendu_jusqua timestamptz;
alter table citoyens add column if not exists compte_suspendu_motif text;

alter table parametres_fiscaux add column if not exists portail_desactive boolean not null default false;
alter table parametres_fiscaux add column if not exists portail_message_desactivation text;

create or replace function gouv_bannir_compte(p_username text, p_motif text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  if p_motif is null or char_length(trim(p_motif)) = 0 then raise exception 'Motif requis.'; end if;
  update citoyens set compte_banni = true, compte_banni_motif = trim(p_motif) where lower(username) = lower(trim(p_username));
  if not found then raise exception 'Citoyen introuvable.'; end if;
end; $$;
grant execute on function gouv_bannir_compte(text, text) to authenticated;

create or replace function gouv_debannir_compte(p_username text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  update citoyens set compte_banni = false, compte_banni_motif = null where lower(username) = lower(trim(p_username));
  if not found then raise exception 'Citoyen introuvable.'; end if;
end; $$;
grant execute on function gouv_debannir_compte(text) to authenticated;

create or replace function gouv_suspendre_compte(p_username text, p_heures numeric, p_motif text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  if p_heures is null or p_heures <= 0 then raise exception 'Durée invalide.'; end if;
  if p_motif is null or char_length(trim(p_motif)) = 0 then raise exception 'Motif requis.'; end if;
  update citoyens set compte_suspendu_jusqua = now() + (p_heures || ' hours')::interval, compte_suspendu_motif = trim(p_motif)
    where lower(username) = lower(trim(p_username));
  if not found then raise exception 'Citoyen introuvable.'; end if;
end; $$;
grant execute on function gouv_suspendre_compte(text, numeric, text) to authenticated;

create or replace function gouv_lever_suspension(p_username text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  update citoyens set compte_suspendu_jusqua = null, compte_suspendu_motif = null where lower(username) = lower(trim(p_username));
  if not found then raise exception 'Citoyen introuvable.'; end if;
end; $$;
grant execute on function gouv_lever_suspension(text) to authenticated;

create or replace function gouv_definir_etat_portail(p_desactive boolean, p_message text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  update parametres_fiscaux set portail_desactive = p_desactive,
    portail_message_desactivation = case when p_desactive then coalesce(p_message, portail_message_desactivation) else portail_message_desactivation end
    where id = 1;
end; $$;
grant execute on function gouv_definir_etat_portail(boolean, text) to authenticated;

-- Callable SANS connexion : affiché avant même le formulaire de connexion.
create or replace function etat_portail()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('desactive', coalesce(portail_desactive, false), 'message', portail_message_desactivation)
  from parametres_fiscaux where id = 1;
$$;
grant execute on function etat_portail() to authenticated, anon;

-- Appelé juste après une connexion réussie. Si bloqué, le client doit se
-- déconnecter (sb.auth.signOut()) et afficher le message correspondant.
create or replace function verifier_acces_connexion()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c citoyens; v_etat record;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  select * into c from citoyens where id = auth.uid();
  if c.compte_banni then
    return jsonb_build_object('ok', false, 'raison', 'banni', 'motif', c.compte_banni_motif);
  end if;
  if c.compte_suspendu_jusqua is not null and c.compte_suspendu_jusqua > now() then
    return jsonb_build_object('ok', false, 'raison', 'suspendu', 'motif', c.compte_suspendu_motif, 'jusqu_a', c.compte_suspendu_jusqua);
  end if;
  select portail_desactive, portail_message_desactivation into v_etat from parametres_fiscaux where id = 1;
  if v_etat.portail_desactive and not est_admin_actuel() then
    return jsonb_build_object('ok', false, 'raison', 'maintenance', 'message', v_etat.portail_message_desactivation);
  end if;
  return jsonb_build_object('ok', true);
end; $$;
grant execute on function verifier_acces_connexion() to authenticated;


-- ============================================================
-- 2) CONTESTATION DE CONSTAT D'INFRACTION
-- ============================================================
alter table constats_infraction add column if not exists annule boolean not null default false;
alter table constats_infraction add column if not exists annule_motif text;

create table if not exists constats_contestations (
  id             uuid primary key default gen_random_uuid(),
  constat_id     uuid not null references constats_infraction(id) on delete cascade,
  citoyen_id     uuid not null references auth.users(id),
  motif          text not null,
  preuve_chemin  text,
  statut         text not null default 'en_attente' check (statut in ('en_attente','acceptee','refusee')),
  motif_decision text,
  cree_le        timestamptz not null default now(),
  traite_le      timestamptz
);
alter table constats_contestations enable row level security;
drop policy if exists "Voir ses contestations ou tout si admin" on constats_contestations;
create policy "Voir ses contestations ou tout si admin" on constats_contestations for select
  using (citoyen_id = auth.uid() or est_admin_actuel());

create or replace function contester_constat(p_constat_id uuid, p_motif text, p_preuve_chemin text default null)
returns constats_contestations language plpgsql security definer set search_path = public as $$
declare v_constat constats_infraction; v_row constats_contestations;
begin
  select * into v_constat from constats_infraction where id = p_constat_id and destinataire_id = auth.uid();
  if v_constat.id is null then raise exception 'Constat introuvable.'; end if;
  if v_constat.paye then raise exception 'Ce constat a déjà été payé.'; end if;
  if v_constat.annule then raise exception 'Ce constat est déjà annulé.'; end if;
  if p_motif is null or char_length(trim(p_motif)) < 10 then raise exception 'Motif requis (10 caractères minimum).'; end if;
  if exists (select 1 from constats_contestations where constat_id = p_constat_id and statut = 'en_attente') then
    raise exception 'Une contestation est déjà en attente pour ce constat.';
  end if;
  if p_preuve_chemin is not null and (storage.foldername(p_preuve_chemin))[1] <> auth.uid()::text then
    raise exception 'Fichier de preuve invalide.';
  end if;
  insert into constats_contestations (constat_id, citoyen_id, motif, preuve_chemin)
    values (p_constat_id, auth.uid(), trim(p_motif), p_preuve_chemin) returning * into v_row;
  return v_row;
end; $$;
grant execute on function contester_constat(uuid, text, text) to authenticated;

create or replace function mes_contestations_constats()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'constat_id', constat_id, 'motif', motif, 'statut', statut,
    'motif_decision', motif_decision, 'cree_le', cree_le) order by cree_le desc), '[]'::jsonb)
  from constats_contestations where citoyen_id = auth.uid();
$$;
grant execute on function mes_contestations_constats() to authenticated;

create or replace function gouv_liste_contestations_constats(p_statut text default 'en_attente')
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not est_admin_actuel() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
    'id', k.id, 'username', c.username, 'motif', k.motif, 'preuve_chemin', k.preuve_chemin, 'cree_le', k.cree_le,
    'constat_infraction', ci.infraction, 'constat_raison', ci.raison, 'constat_prix_total', ci.prix_total
  ) order by k.cree_le), '[]'::jsonb) end
  from constats_contestations k join citoyens c on c.id = k.citoyen_id join constats_infraction ci on ci.id = k.constat_id
  where k.statut = p_statut;
$$;
grant execute on function gouv_liste_contestations_constats(text) to authenticated;

create or replace function gouv_traiter_contestation_constat(p_id uuid, p_decision text, p_motif_decision text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_constat_id uuid;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  if p_decision not in ('acceptee','refusee') then raise exception 'Décision invalide.'; end if;
  select constat_id into v_constat_id from constats_contestations where id = p_id and statut = 'en_attente';
  if v_constat_id is null then raise exception 'Contestation introuvable ou déjà traitée.'; end if;
  update constats_contestations set statut = p_decision, motif_decision = p_motif_decision, traite_le = now() where id = p_id;
  if p_decision = 'acceptee' then
    update constats_infraction set annule = true, annule_motif = coalesce(p_motif_decision, 'Contestation acceptée') where id = v_constat_id;
  end if;
end; $$;
grant execute on function gouv_traiter_contestation_constat(uuid, text, text) to authenticated;

-- payer_constat : refuse si une contestation est en attente ou si annulé par contestation acceptée.
create or replace function payer_constat(p_id uuid)
returns constats_infraction language plpgsql security definer set search_path = public as $$
declare v_constat constats_infraction; v_citoyen citoyens;
begin
  select * into v_constat from constats_infraction where id = p_id and destinataire_id = auth.uid();
  if v_constat.id is null then raise exception 'Constat introuvable.'; end if;
  if v_constat.paye then raise exception 'Ce constat a déjà été payé.'; end if;
  if v_constat.annule then raise exception 'Ce constat a été annulé (contestation acceptée).'; end if;
  if exists (select 1 from constats_contestations where constat_id = p_id and statut = 'en_attente') then
    raise exception 'Une contestation est en attente pour ce constat : paiement bloqué jusqu''à la décision.';
  end if;

  select * into v_citoyen from citoyens where id = auth.uid();
  if v_citoyen.tresorerie < v_constat.prix_total then raise exception 'Trésorerie insuffisante.'; end if;

  update citoyens set tresorerie = tresorerie - v_constat.prix_total where id = auth.uid();
  update tresor_public set solde_prive = solde_prive + v_constat.prix_total where id = 1;
  update constats_infraction set paye = true, paye_le = now() where id = p_id returning * into v_constat;
  return v_constat;
end; $$;
grant execute on function payer_constat(uuid) to authenticated;

-- ============================================================
-- FIN
-- ============================================================
