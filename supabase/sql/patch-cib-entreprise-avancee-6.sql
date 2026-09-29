-- ============================================================
-- patch-cib-entreprise-avancee-6.sql
-- À exécuter après patch-cib-entreprise-avancee-5.sql. Additif et rejouable.
--
-- CONSEILLER FINANCIER
--  - Un client ajoute un conseiller par nom d'utilisateur (conseiller_liens).
--  - Le conseiller envoie des DEMANDES d'action (conseiller_demandes),
--    chacune avec justification obligatoire. Le client accepte ou refuse
--    (refus = motif obligatoire).
--  - Action "API" (ex: message, document, demande épargne) : exécutée
--    immédiatement à l'acceptation, sans intervention supplémentaire.
--  - Action "manuelle" : l'acceptation génère un code de 50 caractères,
--    visible UNE FOIS par le conseiller seulement (jamais par le client),
--    valide 48h, usage unique. Le conseiller l'utilise sur la page
--    "Connexion par conseiller financier" (accessible SANS être connecté,
--    à côté de la demande de CAS) avec : son nom complet, son CAS
--    encrypté, une justification, le nom d'utilisateur du client et le
--    code. Cela ne crée PAS une session Supabase normale : ça renvoie un
--    jeton temporaire que les fonctions "manuelles" vérifient elles-mêmes,
--    et qui agit sur le compte du client via une IMPERSONATION SERVEUR
--    (set_config sur request.jwt.claims, le temps de l'appel — technique
--    standard pour agir "comme" un autre utilisateur sans lui voler sa
--    session), jamais visible ni réutilisable après expiration/usage.
--  - Deux modes de sécurité choisis par le CLIENT : "restreint" (accès
--    seulement aux pages listées dans pages_autorisees + toujours les
--    soldes/dettes/argent attendu/trésorerie) ou "total" (tout, avec logs).
--  - Logs : chaque connexion et chaque clic sont journalisés
--    (conseiller_logs) ; le client peut les télécharger en .txt ou les
--    envoyer à un tiers par nom d'utilisateur.
--
-- HYPOTHÈSE : la longue liste d'actions "entreprise" que le conseiller
-- peut demander est traitée par UNE seule fonction de répartition
-- (_conseiller_dispatch), avec une liste blanche de fonctions existantes
-- appelées telles quelles sous impersonation — plutôt que de dupliquer
-- chacune. Ça couvre tout ce qui a été listé, de façon uniforme et
-- auditable (une seule porte d'entrée à surveiller).
-- ============================================================


-- Refus d'une offre de prêt reçue (aucune fonction existante ne couvrait ce cas).
create or replace function refuser_emprunt(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update emprunts set statut = 'annule' where id = p_id and emprunteur_id = auth.uid() and statut = 'en_attente';
  if not found then raise exception 'Emprunt introuvable ou déjà traité.'; end if;
end; $$;
grant execute on function refuser_emprunt(uuid) to authenticated;


-- ============================================================
-- 1) LIEN CLIENT <-> CONSEILLER
-- ============================================================
create table if not exists conseiller_liens (
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid not null unique references auth.users(id) on delete cascade,
  conseiller_id   uuid not null references auth.users(id),
  mode_securite   text not null default 'restreint' check (mode_securite in ('restreint','total')),
  pages_autorisees text[] not null default '{}',
  cree_le         timestamptz not null default now()
);
alter table conseiller_liens enable row level security;
drop policy if exists "Voir son lien (client ou conseiller) ou tout si admin" on conseiller_liens;
create policy "Voir son lien (client ou conseiller) ou tout si admin" on conseiller_liens for select
  using (client_id = auth.uid() or conseiller_id = auth.uid() or est_admin_actuel());

create or replace function ajouter_conseiller_financier(p_username text)
returns conseiller_liens language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_row conseiller_liens;
begin
  select id into v_id from citoyens where lower(username) = lower(trim(p_username));
  if v_id is null then raise exception 'Conseiller introuvable.'; end if;
  if v_id = auth.uid() then raise exception 'Vous ne pouvez pas être votre propre conseiller.'; end if;
  insert into conseiller_liens (client_id, conseiller_id) values (auth.uid(), v_id)
  on conflict (client_id) do update set conseiller_id = excluded.conseiller_id, mode_securite = 'restreint', pages_autorisees = '{}'
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function ajouter_conseiller_financier(text) to authenticated;

create or replace function retirer_conseiller_financier()
returns void language sql security definer set search_path = public as $$
  delete from conseiller_liens where client_id = auth.uid();
$$;
grant execute on function retirer_conseiller_financier() to authenticated;

create or replace function definir_securite_conseiller(p_mode text, p_pages text[] default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_mode not in ('restreint','total') then raise exception 'Mode invalide.'; end if;
  update conseiller_liens set mode_securite = p_mode, pages_autorisees = case when p_mode = 'restreint' then coalesce(p_pages, pages_autorisees) else '{}' end
    where client_id = auth.uid();
  if not found then raise exception 'Aucun conseiller à configurer.'; end if;
end; $$;
grant execute on function definir_securite_conseiller(text, text[]) to authenticated;

create or replace function mon_conseiller()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when l.id is null then null else jsonb_build_object(
    'id', l.id, 'conseiller_username', c.username, 'mode_securite', l.mode_securite,
    'pages_autorisees', l.pages_autorisees, 'cree_le', l.cree_le) end
  from conseiller_liens l join citoyens c on c.id = l.conseiller_id where l.client_id = auth.uid();
$$;
grant execute on function mon_conseiller() to authenticated;

create or replace function conseiller_mes_clients()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('lien_id', l.id, 'client_username', c.username,
    'mode_securite', l.mode_securite, 'pages_autorisees', l.pages_autorisees)), '[]'::jsonb)
  from conseiller_liens l join citoyens c on c.id = l.client_id where l.conseiller_id = auth.uid();
$$;
grant execute on function conseiller_mes_clients() to authenticated;


-- ============================================================
-- 2) DEMANDES D'ACTION
-- ============================================================
-- Catalogue des actions (documenté ici, appliqué dans _conseiller_est_manuelle) :
--   API      : demande_retraite, demande_chomage, envoyer_message, envoyer_document
--   MANUELLE : voir_paiements, voir_permis, voir_constats, voir_epargne,
--              creer_emprunt, signer_emprunt, page_supplementaire (accès à une page en mode restreint),
--              entreprise_creer, entreprise_voir_cib_joueur, entreprise_voir_cib,
--              entreprise_creer_role, entreprise_modifier_mode_paiement, entreprise_payer_employes,
--              entreprise_modifier_option_defaillance, entreprise_emprunter_gouv,
--              entreprise_transferer_argent, entreprise_vendre_capital, entreprise_vendre_capital_gouv,
--              entreprise_enregistrer_depense, entreprise_faire_releve, entreprise_gerer_prix_capital
create or replace function _conseiller_est_manuelle(p_type text)
returns boolean language sql immutable as $$
  select p_type not in ('demande_retraite','demande_chomage','envoyer_message','envoyer_document');
$$;

create table if not exists conseiller_demandes (
  id              uuid primary key default gen_random_uuid(),
  lien_id         uuid not null references conseiller_liens(id) on delete cascade,
  type_action     text not null,
  manuelle        boolean not null,
  justification   text not null,
  donnees         jsonb not null default '{}'::jsonb,
  statut          text not null default 'en_attente' check (statut in ('en_attente','acceptee','refusee')),
  motif_refus     text,
  code_temporaire text,
  code_genere_le  timestamptz,
  code_expire_le  timestamptz,
  code_utilise    boolean not null default false,
  cree_le         timestamptz not null default now(),
  traite_le       timestamptz
);
alter table conseiller_demandes enable row level security;
drop policy if exists "Voir les demandes de son lien" on conseiller_demandes;
create policy "Voir les demandes de son lien" on conseiller_demandes for select
  using (exists (select 1 from conseiller_liens l where l.id = conseiller_demandes.lien_id
    and (l.client_id = auth.uid() or l.conseiller_id = auth.uid())) or est_admin_actuel());

create or replace function conseiller_demander_action(p_client_username text, p_type_action text, p_justification text, p_donnees jsonb default '{}'::jsonb)
returns conseiller_demandes language plpgsql security definer set search_path = public as $$
declare v_lien conseiller_liens; v_row conseiller_demandes;
begin
  if p_justification is null or char_length(trim(p_justification)) < 10 then raise exception 'Justification requise (10 caractères minimum).'; end if;
  select l.* into v_lien from conseiller_liens l join citoyens c on c.id = l.client_id
    where lower(c.username) = lower(trim(p_client_username)) and l.conseiller_id = auth.uid();
  if v_lien.id is null then raise exception 'Vous n''êtes pas le conseiller financier de ce client.'; end if;
  insert into conseiller_demandes (lien_id, type_action, manuelle, justification, donnees)
    values (v_lien.id, p_type_action, _conseiller_est_manuelle(p_type_action), trim(p_justification), coalesce(p_donnees, '{}'::jsonb))
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function conseiller_demander_action(text, text, text, jsonb) to authenticated;

create or replace function mes_demandes_conseiller_recues()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'type_action', d.type_action, 'manuelle', d.manuelle,
    'justification', d.justification, 'donnees', d.donnees, 'statut', d.statut, 'motif_refus', d.motif_refus, 'cree_le', d.cree_le)
    order by d.cree_le desc), '[]'::jsonb)
  from conseiller_demandes d join conseiller_liens l on l.id = d.lien_id where l.client_id = auth.uid();
$$;
grant execute on function mes_demandes_conseiller_recues() to authenticated;

create or replace function mes_demandes_conseiller_envoyees()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'client_username', c.username, 'type_action', d.type_action,
    'manuelle', d.manuelle, 'justification', d.justification, 'statut', d.statut, 'motif_refus', d.motif_refus,
    'code_disponible', (d.manuelle and d.statut = 'acceptee' and not d.code_utilise and d.code_expire_le > now()), 'cree_le', d.cree_le)
    order by d.cree_le desc), '[]'::jsonb)
  from conseiller_demandes d join conseiller_liens l on l.id = d.lien_id join citoyens c on c.id = l.client_id
  where l.conseiller_id = auth.uid();
$$;
grant execute on function mes_demandes_conseiller_envoyees() to authenticated;

create or replace function _generer_code_conseiller()
returns text language sql as $$
  select string_agg(substr('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789', (floor(random()*62)+1)::int, 1), '')
  from generate_series(1, 50);
$$;

-- Le client répond (accepte : exécute l'action API immédiatement, ou
-- génère le code pour une action manuelle ; refuse : motif obligatoire).
create or replace function client_repondre_demande_conseiller(p_demande_id uuid, p_decision text, p_motif_refus text default null)
returns void language plpgsql security definer set search_path = public as $$
declare d conseiller_demandes; v_client uuid;
begin
  select d.* into d from conseiller_demandes d join conseiller_liens l on l.id = d.lien_id
    where d.id = p_demande_id and l.client_id = auth.uid() and d.statut = 'en_attente';
  if d.id is null then raise exception 'Demande introuvable ou déjà traitée.'; end if;
  select client_id into v_client from conseiller_liens where id = d.lien_id;
  if p_decision not in ('acceptee','refusee') then raise exception 'Décision invalide.'; end if;

  if p_decision = 'refusee' then
    if p_motif_refus is null or char_length(trim(p_motif_refus)) < 5 then raise exception 'Motif de refus requis (5 caractères minimum).'; end if;
    update conseiller_demandes set statut = 'refusee', motif_refus = trim(p_motif_refus), traite_le = now() where id = p_demande_id;
    return;
  end if;

  if d.manuelle then
    update conseiller_demandes set statut = 'acceptee', traite_le = now(),
      code_temporaire = _generer_code_conseiller(), code_genere_le = now(), code_expire_le = now() + interval '48 hours'
      where id = p_demande_id;
  else
    perform _conseiller_executer_api(d, v_client);
    update conseiller_demandes set statut = 'acceptee', traite_le = now() where id = p_demande_id;
  end if;
end; $$;
grant execute on function client_repondre_demande_conseiller(uuid, text, text) to authenticated;

-- Actions API : exécutées immédiatement, comme si le client l'avait fait lui-même.
create or replace function _conseiller_executer_api(d conseiller_demandes, p_client uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_saved text;
begin
  v_saved := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_client::text, 'role', 'authenticated')::text, true);
  if d.type_action = 'demande_retraite' then
    perform demander_epargne('retraite', d.donnees->>'texte');
  elsif d.type_action = 'demande_chomage' then
    perform demander_epargne('chomage', d.donnees->>'texte');
  elsif d.type_action = 'envoyer_message' then
    perform envoyer_message(d.donnees->>'destinataire', d.donnees->>'titre', d.donnees->>'message');
  elsif d.type_action = 'envoyer_document' then
    perform envoyer_document(d.donnees->>'destinataire', d.donnees->>'titre', d.donnees->>'message',
      (d.donnees->>'date_debut')::date, d.donnees->>'date_expiration');
  else
    raise exception 'Action API inconnue.';
  end if;
  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);
exception when others then
  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);
  raise;
end; $$;

-- Le conseiller voit le code UNE FOIS (tant qu'il n'a pas expiré/servi) ; le client ne le voit jamais.
create or replace function conseiller_voir_code(p_demande_id uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare d conseiller_demandes;
begin
  select dd.* into d from conseiller_demandes dd join conseiller_liens l on l.id = dd.lien_id
    where dd.id = p_demande_id and l.conseiller_id = auth.uid();
  if d.id is null then raise exception 'Demande introuvable.'; end if;
  if not d.manuelle or d.statut <> 'acceptee' then raise exception 'Aucun code pour cette demande.'; end if;
  if d.code_utilise then raise exception 'Ce code a déjà été utilisé.'; end if;
  if d.code_expire_le < now() then raise exception 'Ce code a expiré.'; end if;
  return d.code_temporaire;
end; $$;
grant execute on function conseiller_voir_code(uuid) to authenticated;


-- ============================================================
-- 3) CONNEXION PAR CONSEILLER FINANCIER (page pré-connexion) + JETON
-- ============================================================
create table if not exists conseiller_sessions (
  jeton         uuid primary key default gen_random_uuid(),
  demande_id    uuid not null references conseiller_demandes(id),
  client_id     uuid not null references auth.users(id),
  conseiller_id uuid not null references auth.users(id),
  expire_le     timestamptz not null,
  cree_le       timestamptz not null default now()
);
alter table conseiller_sessions enable row level security;  -- aucune politique : accessible seulement par fonctions

create table if not exists conseiller_logs (
  id            uuid primary key default gen_random_uuid(),
  lien_id       uuid not null references conseiller_liens(id) on delete cascade,
  demande_id    uuid references conseiller_demandes(id),
  evenement     text not null,
  details       text,
  cree_le       timestamptz not null default now()
);
alter table conseiller_logs enable row level security;
drop policy if exists "Voir les logs de son lien" on conseiller_logs;
create policy "Voir les logs de son lien" on conseiller_logs for select
  using (exists (select 1 from conseiller_liens l where l.id = conseiller_logs.lien_id and l.client_id = auth.uid()) or est_admin_actuel());

-- Callable SANS connexion (anon) : c'est tout le principe de cette page.
create or replace function conseiller_connexion(p_nom_complet text, p_cas_conseiller text, p_justification text, p_username_client text, p_code text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_client uuid; d conseiller_demandes; v_jeton uuid; v_lien_id uuid;
begin
  if p_nom_complet is null or p_cas_conseiller is null or p_justification is null or char_length(trim(p_justification)) < 10 then
    raise exception 'Tous les champs sont requis (justification : 10 caractères minimum).';
  end if;
  select id into v_client from citoyens where lower(username) = lower(trim(p_username_client));
  if v_client is null then raise exception 'Client introuvable.'; end if;

  select dd.* into d from conseiller_demandes dd join conseiller_liens l on l.id = dd.lien_id
    where l.client_id = v_client and dd.code_temporaire = p_code and dd.manuelle and dd.statut = 'acceptee';
  if d.id is null then raise exception 'Code invalide.'; end if;
  if d.code_utilise then raise exception 'Ce code a déjà été utilisé.'; end if;
  if d.code_expire_le < now() then raise exception 'Ce code a expiré.'; end if;

  update conseiller_demandes set code_utilise = true where id = d.id;
  insert into conseiller_sessions (demande_id, client_id, conseiller_id, expire_le)
    values (d.id, v_client, (select conseiller_id from conseiller_liens where id = d.lien_id), d.code_expire_le)
    returning jeton into v_jeton;

  select lien_id into v_lien_id from conseiller_demandes where id = d.id;
  insert into conseiller_logs (lien_id, demande_id, evenement, details) values (v_lien_id, d.id, 'connexion',
    'Nom complet : ' || p_nom_complet || ' | CAS (encrypté) : ' || p_cas_conseiller || ' | Justification : ' || p_justification
    || ' | Client : ' || p_username_client);
  return v_jeton;
end; $$;
grant execute on function conseiller_connexion(text, text, text, text, text) to authenticated, anon;

-- Vérifie un jeton et renvoie (client_id, demande) ; interne aux fonctions manuelles.
create or replace function _conseiller_verifier_jeton(p_jeton uuid)
returns conseiller_sessions language plpgsql stable security definer set search_path = public as $$
declare s conseiller_sessions;
begin
  select * into s from conseiller_sessions where jeton = p_jeton;
  if s.jeton is null then raise exception 'Session conseiller invalide.'; end if;
  if s.expire_le < now() then raise exception 'Session conseiller expirée.'; end if;
  return s;
end; $$;

create or replace function conseiller_log_clic(p_jeton uuid, p_element text)
returns void language plpgsql security definer set search_path = public as $$
declare s conseiller_sessions; v_lien_id uuid;
begin
  s := _conseiller_verifier_jeton(p_jeton);
  select lien_id into v_lien_id from conseiller_demandes where id = s.demande_id;
  insert into conseiller_logs (lien_id, demande_id, evenement, details) values (v_lien_id, s.demande_id, 'clic', p_element);
end; $$;
grant execute on function conseiller_log_clic(uuid, text) to authenticated, anon;

-- Vérifie que la page/action demandée correspond à ce qui a été accepté (et au mode "restreint" du client).
create or replace function _conseiller_page_autorisee(s conseiller_sessions, p_page text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare d conseiller_demandes; v_mode text; v_pages text[];
begin
  select * into d from conseiller_demandes where id = s.demande_id;
  select mode_securite, pages_autorisees into v_mode, v_pages from conseiller_liens where client_id = s.client_id;
  if d.type_action = p_page then return true; end if;
  if v_mode = 'total' then return true; end if;
  return p_page = any(coalesce(v_pages, '{}'));
end; $$;

-- Lecture de pages simples (paiements, permis, constats, épargne).
create or replace function conseiller_lire(p_jeton uuid, p_page text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s conseiller_sessions; v_res jsonb;
begin
  s := _conseiller_verifier_jeton(p_jeton);
  if not _conseiller_page_autorisee(s, 'voir_' || p_page) then raise exception 'Accès non autorisé à cette page.'; end if;
  if p_page = 'paiements' then
    select coalesce(jsonb_agg(row_to_json(p)), '[]'::jsonb) into v_res from paiements_historique p where citoyen_id = s.client_id;
  elsif p_page = 'permis' then
    select coalesce(jsonb_agg(row_to_json(p)), '[]'::jsonb) into v_res from permis_citoyens p where citoyen_id = s.client_id;
  elsif p_page = 'constats' then
    select coalesce(jsonb_agg(row_to_json(c)), '[]'::jsonb) into v_res from constats_infraction c where destinataire_id = s.client_id;
  elsif p_page = 'epargne' then
    select jsonb_build_object('compte_chomage', compte_chomage, 'compte_retraite', compte_retraite, 'compte_parentalite', compte_parentalite,
      'taxes_gouv_60j', taxes_gouv_60j, 'taxe_preventive_60j', taxe_preventive_60j) into v_res from citoyens where id = s.client_id;
  else
    raise exception 'Page inconnue.';
  end if;
  return v_res;
end; $$;
grant execute on function conseiller_lire(uuid, text) to authenticated, anon;

-- Toujours visible (soldes de base), quel que soit le mode de sécurité.
create or replace function conseiller_soldes(p_jeton uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s conseiller_sessions;
begin
  s := _conseiller_verifier_jeton(p_jeton);
  return jsonb_build_object('tresorerie', (select tresorerie from citoyens where id = s.client_id),
    'dettes', (select dettes from citoyens where id = s.client_id), 'prets', (select prets from citoyens where id = s.client_id),
    'argent_attendu', (select argent_attendu from citoyens where id = s.client_id));
end; $$;
grant execute on function conseiller_soldes(uuid) to authenticated, anon;

-- Signatures : créer un emprunt (le client est prêteur) ou signer un emprunt existant.
create or replace function conseiller_creer_emprunt(p_jeton uuid, p_emprunteur_username text, p_montant numeric, p_taux numeric, p_date_limite date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s conseiller_sessions; v_saved text; v_row emprunts;
begin
  s := _conseiller_verifier_jeton(p_jeton);
  if not _conseiller_page_autorisee(s, 'creer_emprunt') then raise exception 'Accès non autorisé.'; end if;
  v_saved := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', s.client_id::text, 'role', 'authenticated')::text, true);
  select * into v_row from creer_emprunt(p_emprunteur_username, p_montant, p_taux, p_date_limite);
  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);
  return to_jsonb(v_row);
exception when others then
  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);
  raise;
end; $$;
grant execute on function conseiller_creer_emprunt(uuid, text, numeric, numeric, date) to authenticated, anon;

-- p_id : identifiant du contrat (numéro de suivi, ex. "EMP-A1B2C3D4").
create or replace function conseiller_signer_emprunt(p_jeton uuid, p_numero_suivi text, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
declare s conseiller_sessions; v_saved text; v_id uuid;
begin
  s := _conseiller_verifier_jeton(p_jeton);
  if not _conseiller_page_autorisee(s, 'signer_emprunt') then raise exception 'Accès non autorisé.'; end if;
  select id into v_id from emprunts where numero_suivi = p_numero_suivi and emprunteur_id = s.client_id;
  if v_id is null then raise exception 'Contrat introuvable.'; end if;
  v_saved := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', s.client_id::text, 'role', 'authenticated')::text, true);
  if p_decision = 'accepter' then perform signer_emprunt(v_id); else perform refuser_emprunt(v_id); end if;
  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);
exception when others then
  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);
  raise;
end; $$;
grant execute on function conseiller_signer_emprunt(uuid, text, text) to authenticated, anon;

-- Répartiteur unique pour toutes les actions d'entreprise (voir HYPOTHÈSE en tête de fichier).
create or replace function conseiller_executer_entreprise(p_jeton uuid, p_fonction text, p_args jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s conseiller_sessions; v_saved text; v_res jsonb;
  v_permis text[] := array['entreprise_demander','entreprise_ajouter_employe','entreprise_modifier_salaire',
    'entreprise_payer_employe','entreprise_definir_mode_paiement','entreprise_definir_option_defaillance',
    'entreprise_creer_role','entreprise_modifier_droits_role','virement_entrepreneur','entreprise_mettre_capital_en_vente',
    'entreprise_offrir_capital_gouvernement','entreprise_enregistrer_depense','entreprise_demander_emprunt_gouv',
    'entreprise_deposer_impot','entreprise_generer_rapport_auto','entreprise_mes_cib'];
begin
  s := _conseiller_verifier_jeton(p_jeton);
  if not (p_fonction = any(v_permis)) then raise exception 'Fonction non autorisée pour le conseiller financier.'; end if;
  if not _conseiller_page_autorisee(s, 'entreprise_' || p_fonction) and not _conseiller_page_autorisee(s, p_fonction) then
    raise exception 'Accès non autorisé à cette action.';
  end if;

  v_saved := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', s.client_id::text, 'role', 'authenticated')::text, true);

  if p_fonction = 'entreprise_demander' then
    v_res := to_jsonb((select r from entreprise_demander(p_args->>'nom', (p_args->>'depenses')::numeric, (p_args->>'achats')::numeric,
      p_args->>'type_vente', p_args->>'mode_vente', p_args->>'boutique_principale', p_args->>'boutiques_secondaires',
      p_args->>'sieges', p_args->>'fondateur_cas', coalesce(p_args->'employes', '[]'::jsonb)) r));
  elsif p_fonction = 'entreprise_ajouter_employe' then
    perform entreprise_ajouter_employe((p_args->>'entreprise_id')::uuid, p_args->>'cas', (p_args->>'salaire_horaire')::numeric, p_args->>'cib');
  elsif p_fonction = 'entreprise_modifier_salaire' then
    perform entreprise_modifier_salaire((p_args->>'entreprise_id')::uuid, (p_args->>'citoyen_id')::uuid, (p_args->>'salaire')::numeric);
  elsif p_fonction = 'entreprise_payer_employe' then
    perform entreprise_payer_employe((p_args->>'entreprise_id')::uuid, (p_args->>'citoyen_id')::uuid, (p_args->>'taux')::numeric, (p_args->>'heures')::numeric);
  elsif p_fonction = 'entreprise_definir_mode_paiement' then
    perform entreprise_definir_mode_paiement((p_args->>'entreprise_id')::uuid, p_args->>'mode');
  elsif p_fonction = 'entreprise_definir_option_defaillance' then
    perform entreprise_definir_option_defaillance((p_args->>'entreprise_id')::uuid, (p_args->>'option')::int,
      case when p_args->'cibs' is not null then array(select jsonb_array_elements_text(p_args->'cibs')) end);
  elsif p_fonction = 'entreprise_creer_role' then
    v_res := to_jsonb((select r from entreprise_creer_role((p_args->>'entreprise_id')::uuid, p_args->>'nom',
      array(select jsonb_array_elements_text(coalesce(p_args->'droits', '[]'::jsonb)))) r));
  elsif p_fonction = 'entreprise_modifier_droits_role' then
    perform entreprise_modifier_droits_role((p_args->>'role_id')::uuid, array(select jsonb_array_elements_text(coalesce(p_args->'droits', '[]'::jsonb))));
  elsif p_fonction = 'virement_entrepreneur' then
    perform virement_entrepreneur((p_args->>'entreprise_id')::uuid, p_args->>'destinataire', (p_args->>'montant')::numeric);
  elsif p_fonction = 'entreprise_mettre_capital_en_vente' then
    perform entreprise_mettre_capital_en_vente((p_args->>'entreprise_id')::uuid, (p_args->>'pourcentage')::numeric,
      (p_args->>'max_par_individu')::numeric, (p_args->>'prix_par_centieme')::numeric, (p_args->>'min_achat_pct')::numeric, p_args->>'description');
  elsif p_fonction = 'entreprise_offrir_capital_gouvernement' then
    perform entreprise_offrir_capital_gouvernement((p_args->>'entreprise_id')::uuid, (p_args->>'pourcentage')::numeric, (p_args->>'prix_par_centieme')::numeric, p_args->>'message');
  elsif p_fonction = 'entreprise_enregistrer_depense' then
    perform entreprise_enregistrer_depense((p_args->>'entreprise_id')::uuid, (p_args->>'montant')::numeric, p_args->>'note');
  elsif p_fonction = 'entreprise_demander_emprunt_gouv' then
    v_res := to_jsonb((select r from entreprise_demander_emprunt_gouv((p_args->>'entreprise_id')::uuid, (p_args->>'montant')::numeric,
      p_args->>'type_taux', (p_args->>'taux_valeur')::numeric, p_args->>'justification') r));
  elsif p_fonction = 'entreprise_deposer_impot' then
    perform entreprise_deposer_impot((p_args->>'entreprise_id')::uuid, p_args->>'periode', (p_args->>'benefices')::numeric, (p_args->>'depenses')::numeric, p_args->>'note');
  elsif p_fonction = 'entreprise_generer_rapport_auto' then
    v_res := to_jsonb((select r from entreprise_generer_rapport_auto((p_args->>'entreprise_id')::uuid, p_args->>'periode') r));
  elsif p_fonction = 'entreprise_mes_cib' then
    v_res := entreprise_mes_cib((p_args->>'entreprise_id')::uuid);
  end if;

  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);
  return coalesce(v_res, '{}'::jsonb);
exception when others then
  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);
  raise;
end; $$;
grant execute on function conseiller_executer_entreprise(uuid, text, jsonb) to authenticated, anon;

-- Voir le CIB d'un membre d'entreprise, via un conseiller autorisé (mot de passe du PDG toujours requis).
create or replace function conseiller_voir_cib_membre(p_jeton uuid, p_entreprise_id uuid, p_citoyen_id uuid, p_mdp text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s conseiller_sessions; v_saved text; v_res jsonb;
begin
  s := _conseiller_verifier_jeton(p_jeton);
  if not _conseiller_page_autorisee(s, 'entreprise_voir_cib') then raise exception 'Accès non autorisé.'; end if;
  v_saved := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', s.client_id::text, 'role', 'authenticated')::text, true);
  v_res := entreprise_voir_cib_membre(p_entreprise_id, p_citoyen_id, p_mdp);
  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);
  return v_res;
exception when others then
  perform set_config('request.jwt.claims', coalesce(v_saved, ''), true);
  raise;
end; $$;
grant execute on function conseiller_voir_cib_membre(uuid, uuid, uuid, text) to authenticated, anon;


-- ============================================================
-- 4) LOGS TÉLÉCHARGEABLES / ENVOYABLES
-- ============================================================
create or replace function conseiller_logs_texte(p_lien_id uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_client uuid; v_texte text;
begin
  select client_id into v_client from conseiller_liens where id = p_lien_id;
  if v_client is distinct from auth.uid() and not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  select string_agg(to_char(cree_le, 'YYYY-MM-DD HH24:MI:SS') || ' [' || evenement || '] ' || coalesce(details, ''), E'\n' order by cree_le)
    into v_texte from conseiller_logs where lien_id = p_lien_id;
  return coalesce(v_texte, 'Aucun log.');
end; $$;
grant execute on function conseiller_logs_texte(uuid) to authenticated;

create or replace function conseiller_envoyer_logs(p_lien_id uuid, p_destinataire_username text)
returns void language plpgsql security definer set search_path = public as $$
declare v_texte text;
begin
  v_texte := conseiller_logs_texte(p_lien_id);
  perform envoyer_document(p_destinataire_username, 'Logs de connexion — conseiller financier',
    left(v_texte, 3000), current_date, 'X');
end; $$;
grant execute on function conseiller_envoyer_logs(uuid, text) to authenticated;

-- ============================================================
-- FIN
-- ============================================================
