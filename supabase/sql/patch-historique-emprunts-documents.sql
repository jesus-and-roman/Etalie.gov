-- ============================================================
-- Correctif — Nom d'utilisateur visible sur les messages,
-- historique des paiements/virements, nouveaux paliers de
-- virement, emprunts avec signatures, documents contractuels
-- ============================================================

-- ------------------------------------------------------------
-- 1) NOM D'UTILISATEUR DE L'EXPÉDITEUR SUR LES MESSAGES
-- ------------------------------------------------------------
alter table messages add column if not exists expediteur_username text;

create or replace function envoyer_message(p_destinataire_username text, p_titre text, p_contenu text)
returns messages language plpgsql security definer set search_path = public as $$
declare v_dest uuid; v_row messages; v_mon_username text;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if char_length(p_contenu) > 500 then raise exception 'Message limité à 500 caractères.'; end if;
  if char_length(p_titre) > 120 then raise exception 'Titre trop long.'; end if;
  if contient_emoji(p_contenu) or contient_emoji(p_titre) then raise exception 'Les émojis ne sont pas acceptés.'; end if;

  select id into v_dest from citoyens where lower(username) = lower(p_destinataire_username);
  if v_dest is null then raise exception 'Destinataire introuvable.'; end if;
  select username into v_mon_username from citoyens where id = auth.uid();

  insert into messages (type, expediteur_id, expediteur_username, destinataire_id, titre, contenu)
  values ('normal', auth.uid(), v_mon_username, v_dest, p_titre, p_contenu)
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function envoyer_message(text,text,text) to authenticated;

create or replace function agent_envoyer_message(p_destinataire_username text, p_titre text, p_contenu text, p_en_tant_agent boolean)
returns messages language plpgsql security definer set search_path = public as $$
declare v_dest uuid; v_row messages; v_mon_username text;
begin
  if not est_agent_actuel() and not est_admin_actuel() then raise exception 'Accès refusé : réservé aux agents de la paix.'; end if;
  if char_length(p_contenu) > 500 then raise exception 'Message limité à 500 caractères.'; end if;
  select id into v_dest from citoyens where lower(username) = lower(p_destinataire_username);
  if v_dest is null then raise exception 'Destinataire introuvable.'; end if;
  select username into v_mon_username from citoyens where id = auth.uid();

  insert into messages (type, expediteur_id, expediteur_username, destinataire_id, titre, contenu, nom_affiche)
  values (case when p_en_tant_agent then 'agent' else 'normal' end,
          auth.uid(), v_mon_username, v_dest, p_titre, p_contenu,
          case when p_en_tant_agent then 'Agent de la paix' else null end)
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function agent_envoyer_message(text, text, text, boolean) to authenticated;

create or replace function admin_envoyer_message(
  p_destinataires text[], p_tous boolean, p_type text, p_titre text, p_contenu text,
  p_est_avertissement boolean default false, p_nom_affiche text default null, p_liste_gouvernementale text default null
) returns int
language plpgsql security definer set search_path = public as $$
declare v_dest_ids uuid[]; v_count int := 0; v_id uuid; v_mon_username text;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé à l''administrateur.'; end if;
  if p_type not in ('normal','gouvernemental') then raise exception 'Type de message invalide.'; end if;
  if p_type = 'gouvernemental' and (p_nom_affiche is null or p_liste_gouvernementale is null) then
    raise exception 'Un message gouvernemental doit avoir un nom affiché et une liste.';
  end if;
  select username into v_mon_username from citoyens where id = auth.uid();

  if p_tous then
    select array_agg(id) into v_dest_ids from citoyens;
  else
    select array_agg(id) into v_dest_ids from citoyens where lower(username) = any (select lower(u) from unnest(p_destinataires) as u);
  end if;
  if v_dest_ids is null or array_length(v_dest_ids, 1) is null then raise exception 'Aucun destinataire valide.'; end if;

  foreach v_id in array v_dest_ids loop
    insert into messages (type, expediteur_id, expediteur_username, destinataire_id, nom_affiche, liste_gouvernementale, titre, contenu, est_avertissement)
    values (p_type, auth.uid(), v_mon_username, v_id,
            case when p_type = 'gouvernemental' then p_nom_affiche else null end,
            case when p_type = 'gouvernemental' then p_liste_gouvernementale else null end,
            p_titre, p_contenu, p_est_avertissement);
    v_count := v_count + 1;
  end loop;
  return v_count;
end; $$;
grant execute on function admin_envoyer_message(text[],boolean,text,text,text,boolean,text,text) to authenticated;

-- ------------------------------------------------------------
-- Contacter le gouvernement : joint automatiquement l'UUID
-- ------------------------------------------------------------
create or replace function contacter_gouvernement(p_cible text, p_titre text, p_contenu text)
returns int language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_count int := 0; v_mon_username text; v_contenu_final text;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if char_length(p_contenu) > 500 then raise exception 'Message limité à 500 caractères.'; end if;
  select username into v_mon_username from citoyens where id = auth.uid();
  v_contenu_final := p_contenu || E'\n\n— Envoyé par UUID : ' || auth.uid()::text;
  for v_id in select id from citoyens where est_admin loop
    insert into messages (type, expediteur_id, expediteur_username, destinataire_id, titre, contenu)
    values ('normal', auth.uid(), v_mon_username, v_id, '[' || p_cible || '] ' || p_titre, v_contenu_final);
    v_count := v_count + 1;
  end loop;
  if v_count = 0 then raise exception 'Aucun destinataire gouvernemental disponible pour le moment.'; end if;
  return v_count;
end; $$;
grant execute on function contacter_gouvernement(text, text, text) to authenticated;

-- ============================================================
-- 2) HISTORIQUE DES PAIEMENTS
-- ============================================================
create table if not exists paiements_historique (
  id           uuid primary key default gen_random_uuid(),
  citoyen_id   uuid not null references auth.users(id) on delete cascade,
  type         text not null check (type in ('dette','pret','constat','emprunt')),
  montant      numeric not null,
  reference_id uuid,
  cree_le      timestamptz not null default now()
);
alter table paiements_historique enable row level security;
create policy "Voir son propre historique de paiements ou tout si admin"
  on paiements_historique for select
  using (auth.uid() = citoyen_id or est_admin_actuel());

create or replace function payer_dette(p_montant numeric)
returns citoyens language plpgsql security definer set search_path = public as $$
declare v_row citoyens;
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select * into v_row from citoyens where id = auth.uid();
  if v_row.tresorerie < p_montant then raise exception 'Trésorerie insuffisante.'; end if;
  update citoyens set tresorerie = tresorerie - p_montant, dettes = greatest(0, dettes - p_montant)
    where id = auth.uid() returning * into v_row;
  insert into paiements_historique (citoyen_id, type, montant) values (auth.uid(), 'dette', p_montant);
  return v_row;
end; $$;
grant execute on function payer_dette(numeric) to authenticated;

create or replace function payer_pret(p_montant numeric)
returns citoyens language plpgsql security definer set search_path = public as $$
declare v_row citoyens;
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select * into v_row from citoyens where id = auth.uid();
  if v_row.tresorerie < p_montant then raise exception 'Trésorerie insuffisante.'; end if;
  update citoyens set tresorerie = tresorerie - p_montant, prets = greatest(0, prets - p_montant)
    where id = auth.uid() returning * into v_row;
  insert into paiements_historique (citoyen_id, type, montant) values (auth.uid(), 'pret', p_montant);
  return v_row;
end; $$;
grant execute on function payer_pret(numeric) to authenticated;

create or replace function payer_constat(p_id uuid)
returns constats_infraction language plpgsql security definer set search_path = public as $$
declare v_constat constats_infraction; v_citoyen citoyens;
begin
  select * into v_constat from constats_infraction where id = p_id and destinataire_id = auth.uid();
  if v_constat is null then raise exception 'Constat introuvable.'; end if;
  if v_constat.paye then raise exception 'Ce constat a déjà été payé.'; end if;
  select * into v_citoyen from citoyens where id = auth.uid();
  if v_citoyen.tresorerie < v_constat.prix_total then raise exception 'Trésorerie insuffisante.'; end if;

  update citoyens set tresorerie = tresorerie - v_constat.prix_total where id = auth.uid();
  update tresor_public set solde = solde + v_constat.prix_total where id = 1;
  update constats_infraction set paye = true, paye_le = now() where id = p_id returning * into v_constat;
  insert into paiements_historique (citoyen_id, type, montant, reference_id) values (auth.uid(), 'constat', v_constat.prix_total, p_id);
  return v_constat;
end; $$;
grant execute on function payer_constat(uuid) to authenticated;

-- ============================================================
-- 3) VIREMENTS — nouveaux paliers, plus l'historique se lit
--    directement depuis la table transferts (déjà en place)
-- ============================================================
alter table transferts drop constraint if exists transferts_type_check;
alter table transferts add constraint transferts_type_check check (type in ('famille','business','econome'));

create or replace function virement_famille(p_destinataire_username text, p_montant numeric)
returns transferts language plpgsql security definer set search_path = public as $$
declare v_dest_id uuid; v_expediteur citoyens; v_taxe numeric; v_total numeric; v_row transferts;
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  if p_montant > 2000 then raise exception 'Le virement familial est limité à 2000 R$.'; end if;
  select id into v_dest_id from citoyens where lower(username) = lower(p_destinataire_username);
  if v_dest_id is null then raise exception 'Destinataire introuvable.'; end if;
  if v_dest_id = auth.uid() then raise exception 'Impossible de se virer de l''argent à soi-même.'; end if;

  select * into v_expediteur from citoyens where id = auth.uid();
  v_taxe := p_montant * 0.0125;
  v_total := p_montant + v_taxe;
  if v_expediteur.tresorerie < v_total then raise exception 'Trésorerie insuffisante (total avec taxe: %).', v_total; end if;

  update citoyens set tresorerie = tresorerie - v_total where id = auth.uid();
  update citoyens set tresorerie = tresorerie + p_montant where id = v_dest_id;
  update tresor_public set solde = solde + v_taxe where id = 1;

  insert into transferts (type, expediteur_id, destinataires, montant_par_personne, taxe_pourcentage, taxe_totale, total_debite, remboursable)
  values ('famille', auth.uid(), array[v_dest_id], p_montant, 1.25, v_taxe, v_total, false)
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function virement_famille(text, numeric) to authenticated;

create or replace function virement_business(p_destinataires_usernames text[], p_montant_par_personne numeric)
returns transferts language plpgsql security definer set search_path = public as $$
declare v_dest_ids uuid[]; v_expediteur citoyens; v_total_verse numeric; v_taxe numeric; v_total_debite numeric; v_id uuid; v_row transferts;
begin
  if p_montant_par_personne <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select array_agg(id) into v_dest_ids from citoyens where lower(username) = any (select lower(u) from unnest(p_destinataires_usernames) as u);
  if v_dest_ids is null or array_length(v_dest_ids, 1) is null then raise exception 'Aucun destinataire valide.'; end if;
  if auth.uid() = any(v_dest_ids) then raise exception 'Impossible de s''inclure soi-même comme destinataire.'; end if;

  v_total_verse := p_montant_par_personne * array_length(v_dest_ids, 1);
  if v_total_verse > 6000 then raise exception 'Le virement business est limité à 6000 R$ au total.'; end if;

  select * into v_expediteur from citoyens where id = auth.uid();
  v_taxe := v_total_verse * 0.0165;
  v_total_debite := v_total_verse + v_taxe;
  if v_expediteur.tresorerie < v_total_debite then raise exception 'Trésorerie insuffisante (total avec taxe: %).', v_total_debite; end if;

  update citoyens set tresorerie = tresorerie - v_total_debite where id = auth.uid();
  foreach v_id in array v_dest_ids loop
    update citoyens set tresorerie = tresorerie + p_montant_par_personne where id = v_id;
  end loop;
  update tresor_public set solde = solde + v_taxe where id = 1;

  insert into transferts (type, expediteur_id, destinataires, montant_par_personne, taxe_pourcentage, taxe_totale, total_debite, remboursable)
  values ('business', auth.uid(), v_dest_ids, p_montant_par_personne, 1.65, v_taxe, v_total_debite, true)
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function virement_business(text[], numeric) to authenticated;

-- Virement économe : 6 000 $ à 500 000 $, 1 seul destinataire, non
-- remboursable ("aucun litige possible"), taxe de 0,35%.
create or replace function virement_econome(p_destinataire_username text, p_montant numeric)
returns transferts language plpgsql security definer set search_path = public as $$
declare v_dest_id uuid; v_expediteur citoyens; v_taxe numeric; v_total numeric; v_row transferts;
begin
  if p_montant < 6000 or p_montant > 500000 then
    raise exception 'Le virement économe doit être entre 6 000 R$ et 500 000 R$.';
  end if;
  select id into v_dest_id from citoyens where lower(username) = lower(p_destinataire_username);
  if v_dest_id is null then raise exception 'Destinataire introuvable.'; end if;
  if v_dest_id = auth.uid() then raise exception 'Impossible de se virer de l''argent à soi-même.'; end if;

  select * into v_expediteur from citoyens where id = auth.uid();
  v_taxe := p_montant * 0.0035;
  v_total := p_montant + v_taxe;
  if v_expediteur.tresorerie < v_total then raise exception 'Trésorerie insuffisante (total avec taxe: %).', v_total; end if;

  update citoyens set tresorerie = tresorerie - v_total where id = auth.uid();
  update citoyens set tresorerie = tresorerie + p_montant where id = v_dest_id;
  update tresor_public set solde = solde + v_taxe where id = 1;

  insert into transferts (type, expediteur_id, destinataires, montant_par_personne, taxe_pourcentage, taxe_totale, total_debite, remboursable)
  values ('econome', auth.uid(), array[v_dest_id], p_montant, 0.35, v_taxe, v_total, false)
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function virement_econome(text, numeric) to authenticated;

-- ============================================================
-- 4) EMPRUNTS AVEC SIGNATURES
-- ============================================================
create table if not exists emprunts (
  id                 uuid primary key default gen_random_uuid(),
  numero_suivi       text unique not null,
  preteur_id         uuid not null references auth.users(id) on delete cascade,
  emprunteur_id      uuid not null references auth.users(id) on delete cascade,
  montant_initial    numeric not null check (montant_initial > 0),
  taux_interet       numeric not null check (taux_interet >= 0 and taux_interet <= 5),
  date_limite        date not null,
  statut             text not null default 'en_attente' check (statut in ('en_attente','actif','annule','rembourse')),
  signe_preteur      boolean not null default true,
  signe_emprunteur   boolean not null default false,
  date_signature     timestamptz,
  cree_le            timestamptz not null default now(),
  rembourse_le       timestamptz,
  plainte_deposee    boolean not null default false,
  supprime_preteur   boolean not null default false,
  supprime_emprunteur boolean not null default false
);
alter table emprunts enable row level security;
create policy "Voir ses emprunts (prêteur ou emprunteur) ou tout si admin"
  on emprunts for select
  using (
    (auth.uid() = preteur_id and not supprime_preteur)
    or (auth.uid() = emprunteur_id and not supprime_emprunteur)
    or est_admin_actuel()
  );

create or replace function creer_emprunt(p_emprunteur_username text, p_montant numeric, p_taux_interet numeric, p_date_limite date)
returns emprunts language plpgsql security definer set search_path = public as $$
declare v_emprunteur_id uuid; v_row emprunts; v_numero text; v_mon_username text;
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  if p_taux_interet < 0 or p_taux_interet > 5 then raise exception 'Le taux d''intérêt doit être entre 0 et 5%% par mois.'; end if;
  if p_date_limite <= current_date then raise exception 'La date limite doit être dans le futur.'; end if;

  select id into v_emprunteur_id from citoyens where lower(username) = lower(p_emprunteur_username);
  if v_emprunteur_id is null then raise exception 'Emprunteur introuvable.'; end if;
  if v_emprunteur_id = auth.uid() then raise exception 'Impossible de s''emprunter de l''argent à soi-même.'; end if;

  v_numero := 'EMP-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));

  insert into emprunts (numero_suivi, preteur_id, emprunteur_id, montant_initial, taux_interet, date_limite)
  values (v_numero, auth.uid(), v_emprunteur_id, p_montant, p_taux_interet, p_date_limite)
  returning * into v_row;

  select username into v_mon_username from citoyens where id = auth.uid();
  insert into messages (type, expediteur_id, expediteur_username, destinataire_id, titre, contenu)
  values ('normal', auth.uid(), v_mon_username, v_emprunteur_id,
          'Offre de prêt reçue (' || v_numero || ')',
          'Vous avez reçu une offre de prêt de ' || p_montant || ' R$ à ' || p_taux_interet || '% par mois, remboursable avant le ' || to_char(p_date_limite,'DD/MM/YYYY') || '. Consultez l''onglet Signatures pour l''accepter.');

  return v_row;
end; $$;
grant execute on function creer_emprunt(text, numeric, numeric, date) to authenticated;

create or replace function signer_emprunt(p_id uuid)
returns emprunts language plpgsql security definer set search_path = public as $$
declare v_emprunt emprunts; v_preteur citoyens;
begin
  select * into v_emprunt from emprunts where id = p_id and emprunteur_id = auth.uid();
  if v_emprunt is null then raise exception 'Emprunt introuvable.'; end if;
  if v_emprunt.statut <> 'en_attente' then raise exception 'Ce contrat n''est plus en attente de signature.'; end if;

  select * into v_preteur from citoyens where id = v_emprunt.preteur_id;
  if v_preteur.tresorerie < v_emprunt.montant_initial then
    update emprunts set statut = 'annule' where id = p_id returning * into v_emprunt;
    return v_emprunt;
  end if;

  update citoyens set tresorerie = tresorerie - v_emprunt.montant_initial where id = v_emprunt.preteur_id;
  update citoyens set tresorerie = tresorerie + v_emprunt.montant_initial where id = auth.uid();

  update emprunts set signe_emprunteur = true, statut = 'actif', date_signature = now()
    where id = p_id returning * into v_emprunt;
  return v_emprunt;
end; $$;
grant execute on function signer_emprunt(uuid) to authenticated;

-- Montant dû aujourd'hui (intérêt simple, prorata journalier, gelé après la date limite)
create or replace function emprunt_montant_du(p_id uuid)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare v emprunts; v_jours numeric;
begin
  select * into v from emprunts where id = p_id;
  if v is null or v.date_signature is null then return 0; end if;
  v_jours := least(current_date, v.date_limite) - v.date_signature::date;
  if v_jours < 0 then v_jours := 0; end if;
  return round(v.montant_initial * (1 + (v.taux_interet / 100.0) * (v_jours / 30.0)), 2);
end; $$;
grant execute on function emprunt_montant_du(uuid) to authenticated;

create or replace function rembourser_emprunt(p_id uuid)
returns emprunts language plpgsql security definer set search_path = public as $$
declare v_emprunt emprunts; v_emprunteur citoyens; v_montant_du numeric;
begin
  select * into v_emprunt from emprunts where id = p_id and emprunteur_id = auth.uid();
  if v_emprunt is null then raise exception 'Emprunt introuvable.'; end if;
  if v_emprunt.statut <> 'actif' then raise exception 'Ce contrat n''est pas actif.'; end if;

  v_montant_du := emprunt_montant_du(p_id);
  select * into v_emprunteur from citoyens where id = auth.uid();
  if v_emprunteur.tresorerie < v_montant_du then raise exception 'Trésorerie insuffisante (dû: % R$).', v_montant_du; end if;

  update citoyens set tresorerie = tresorerie - v_montant_du where id = auth.uid();
  update citoyens set tresorerie = tresorerie + v_montant_du where id = v_emprunt.preteur_id;

  update emprunts set statut = 'rembourse', rembourse_le = now() where id = p_id returning * into v_emprunt;
  insert into paiements_historique (citoyen_id, type, montant, reference_id) values (auth.uid(), 'emprunt', v_montant_du, p_id);
  return v_emprunt;
end; $$;
grant execute on function rembourser_emprunt(uuid) to authenticated;

create or replace function porter_plainte_emprunt(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_emprunt emprunts; v_id uuid; v_mon_username text;
begin
  select * into v_emprunt from emprunts where id = p_id and preteur_id = auth.uid();
  if v_emprunt is null then raise exception 'Emprunt introuvable.'; end if;
  if v_emprunt.statut <> 'actif' or v_emprunt.date_limite >= current_date then
    raise exception 'La plainte n''est possible qu''après la date limite d''un contrat actif.';
  end if;
  update emprunts set plainte_deposee = true where id = p_id;

  select username into v_mon_username from citoyens where id = auth.uid();
  for v_id in select id from citoyens where est_admin loop
    insert into messages (type, expediteur_id, expediteur_username, destinataire_id, titre, contenu)
    values ('normal', auth.uid(), v_mon_username, v_id,
            'Plainte — emprunt ' || v_emprunt.numero_suivi,
            'Plainte déposée pour non-remboursement du contrat ' || v_emprunt.numero_suivi ||
            '. Montant dû : ' || emprunt_montant_du(p_id) || ' R$. Emprunteur (UUID) : ' || v_emprunt.emprunteur_id::text);
  end loop;
end; $$;
grant execute on function porter_plainte_emprunt(uuid) to authenticated;

create or replace function supprimer_emprunt(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_emprunt emprunts;
begin
  select * into v_emprunt from emprunts where id = p_id and (preteur_id = auth.uid() or emprunteur_id = auth.uid());
  if v_emprunt is null then raise exception 'Emprunt introuvable.'; end if;
  if v_emprunt.statut <> 'rembourse' then raise exception 'Le contrat doit être remboursé avant de pouvoir être retiré.'; end if;
  if auth.uid() = v_emprunt.preteur_id then
    update emprunts set supprime_preteur = true where id = p_id;
  else
    update emprunts set supprime_emprunteur = true where id = p_id;
  end if;
end; $$;
grant execute on function supprimer_emprunt(uuid) to authenticated;

-- ============================================================
-- 5) DOCUMENTS CONTRACTUELS
-- ============================================================
create table if not exists documents_contractuels (
  id                  uuid primary key default gen_random_uuid(),
  expediteur_id       uuid not null references auth.users(id) on delete cascade,
  destinataire_id     uuid not null references auth.users(id) on delete cascade,
  titre               text not null,
  contenu             text not null check (char_length(contenu) <= 3000),
  date_debut          date not null,
  date_expiration     text not null, -- une date (JJ/MM/AAAA) ou "X" si permanent
  signe_expediteur    boolean not null default true,
  signe_destinataire  boolean not null default true,
  cree_le             timestamptz not null default now()
);
alter table documents_contractuels enable row level security;
create policy "Voir ses documents (envoyés ou reçus) ou tout si admin"
  on documents_contractuels for select
  using (auth.uid() = expediteur_id or auth.uid() = destinataire_id or est_admin_actuel());

create or replace function envoyer_document(p_destinataire_username text, p_titre text, p_contenu text, p_date_debut date, p_date_expiration text)
returns documents_contractuels language plpgsql security definer set search_path = public as $$
declare v_dest uuid; v_row documents_contractuels;
begin
  if char_length(p_contenu) > 3000 then raise exception 'Document limité à 3000 caractères.'; end if;
  select id into v_dest from citoyens where lower(username) = lower(p_destinataire_username);
  if v_dest is null then raise exception 'Destinataire introuvable.'; end if;
  if v_dest = auth.uid() then raise exception 'Impossible de s''envoyer un document à soi-même.'; end if;

  insert into documents_contractuels (expediteur_id, destinataire_id, titre, contenu, date_debut, date_expiration)
  values (auth.uid(), v_dest, p_titre, p_contenu, p_date_debut, p_date_expiration)
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function envoyer_document(text, text, text, date, text) to authenticated;

-- ============================================================
-- 6) REALTIME pour les nouvelles tables
-- ============================================================
alter publication supabase_realtime add table emprunts;
alter publication supabase_realtime add table transferts;

-- ============================================================
-- 7) COMMISSION DES AGENTS SUR LES CONSTATS RETIRÉS
-- ============================================================
-- Le constat doit maintenant connaître le NOM D'UTILISATEUR (pas
-- seulement le matricule/nom légal) de chacun des agents impliqués,
-- pour pouvoir leur verser une commission.
alter table constats_infraction add column if not exists username_agent_vu text;
alter table constats_infraction add column if not exists username_agent_donne text;
alter table constats_infraction add column if not exists username_agent_assiste text;

create or replace function agent_creer_constat(
  p_destinataire_username text, p_raison text, p_justification text,
  p_date_infraction date, p_date_infraction_toutouienne text, p_heure_infraction time,
  p_infraction text, p_numero_infraction text,
  p_matricule_agent_vu text, p_matricule_agent_donne text, p_matricule_agent_assiste text,
  p_nom_agent_vu text, p_nom_agent_donne text, p_nom_agent_assiste text,
  p_username_agent_vu text, p_username_agent_donne text, p_username_agent_assiste text,
  p_lieu_rue text, p_lieu_ville text, p_lieu_province text,
  p_prix_infraction numeric, p_prix_taxes numeric,
  p_commissariat text, p_commissariat_type text
) returns constats_infraction
language plpgsql security definer set search_path = public as $$
declare v_dest uuid; v_row constats_infraction; v_titre text;
begin
  if not est_agent_actuel() and not est_admin_actuel() then raise exception 'Accès refusé : réservé aux agents de la paix.'; end if;
  select id into v_dest from citoyens where lower(username) = lower(p_destinataire_username);
  if v_dest is null then raise exception 'Destinataire introuvable.'; end if;

  if not exists (select 1 from citoyens where lower(username) = lower(p_username_agent_vu)) then
    raise exception 'Nom d''utilisateur de l''agent "vu" introuvable.';
  end if;
  if not exists (select 1 from citoyens where lower(username) = lower(p_username_agent_donne)) then
    raise exception 'Nom d''utilisateur de l''agent "donné" introuvable.';
  end if;
  if p_username_agent_assiste is not null and p_username_agent_assiste <> '' and
     not exists (select 1 from citoyens where lower(username) = lower(p_username_agent_assiste)) then
    raise exception 'Nom d''utilisateur de l''agent assistant introuvable.';
  end if;

  insert into constats_infraction (
    destinataire_id, agent_emetteur_id, raison, justification, date_infraction,
    date_infraction_toutouienne, heure_infraction, infraction, numero_infraction,
    matricule_agent_vu, matricule_agent_donne, matricule_agent_assiste,
    nom_agent_vu, nom_agent_donne, nom_agent_assiste,
    username_agent_vu, username_agent_donne, username_agent_assiste,
    lieu_rue, lieu_ville, lieu_province,
    prix_infraction, prix_taxes, prix_total, commissariat, commissariat_type
  ) values (
    v_dest, auth.uid(), p_raison, p_justification, p_date_infraction,
    p_date_infraction_toutouienne, p_heure_infraction, p_infraction, p_numero_infraction,
    p_matricule_agent_vu, p_matricule_agent_donne, p_matricule_agent_assiste,
    p_nom_agent_vu, p_nom_agent_donne, p_nom_agent_assiste,
    lower(p_username_agent_vu), lower(p_username_agent_donne),
    nullif(lower(coalesce(p_username_agent_assiste, '')), ''),
    p_lieu_rue, p_lieu_ville, p_lieu_province,
    p_prix_infraction, p_prix_taxes, p_prix_infraction + p_prix_taxes, p_commissariat, p_commissariat_type
  ) returning * into v_row;

  v_titre := 'Constat d''infraction commis le ' || to_char(p_date_infraction, 'DD/MM/YYYY');
  insert into messages (type, expediteur_id, destinataire_id, titre, contenu, nom_affiche)
  values ('agent', auth.uid(), v_dest, v_titre,
          'Un constat d''infraction a été émis à votre nom. Consultez l''onglet Constats de votre tableau de bord pour le détail et le paiement.',
          'Agent de la paix');

  return v_row;
end; $$;
grant execute on function agent_creer_constat(text,text,text,date,text,time,text,text,text,text,text,text,text,text,text,text,text,text,text,text,numeric,numeric,text,text) to authenticated;

-- Retrait d'un constat payé : verse d'abord une commission (0,25% à 2,25%
-- du prix total, choisie par celui qui retire) à CHACUN des agents nommés
-- (vu / donné / assistant s'il existe), puis marque le retrait. Remplace
-- citoyen_supprimer_constat et agent_supprimer_constat.
drop function if exists citoyen_supprimer_constat(uuid);
drop function if exists agent_supprimer_constat(uuid);

create or replace function retirer_constat_paye(p_id uuid, p_pourcentage numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_constat constats_infraction; v_montant numeric; v_uid uuid;
begin
  select * into v_constat from constats_infraction where id = p_id;
  if v_constat is null then raise exception 'Constat introuvable.'; end if;
  if not v_constat.paye then raise exception 'Le constat doit être payé avant de pouvoir être retiré.'; end if;
  if p_pourcentage < 0.25 or p_pourcentage > 2.25 then
    raise exception 'Le pourcentage de commission doit être entre 0,25%% et 2,25%%.';
  end if;
  if auth.uid() <> v_constat.destinataire_id and auth.uid() <> v_constat.agent_emetteur_id and not est_admin_actuel() then
    raise exception 'Accès refusé.';
  end if;

  v_montant := round(v_constat.prix_total * (p_pourcentage / 100.0), 2);

  if v_constat.username_agent_vu is not null then
    select id into v_uid from citoyens where lower(username) = v_constat.username_agent_vu;
    if v_uid is not null then
      update citoyens set tresorerie = tresorerie + v_montant where id = v_uid;
      update tresor_public set solde = greatest(0, solde - v_montant) where id = 1;
    end if;
  end if;

  if v_constat.username_agent_donne is not null and v_constat.username_agent_donne <> v_constat.username_agent_vu then
    select id into v_uid from citoyens where lower(username) = v_constat.username_agent_donne;
    if v_uid is not null then
      update citoyens set tresorerie = tresorerie + v_montant where id = v_uid;
      update tresor_public set solde = greatest(0, solde - v_montant) where id = 1;
    end if;
  end if;

  if v_constat.username_agent_assiste is not null
     and v_constat.username_agent_assiste <> v_constat.username_agent_vu
     and v_constat.username_agent_assiste <> v_constat.username_agent_donne then
    select id into v_uid from citoyens where lower(username) = v_constat.username_agent_assiste;
    if v_uid is not null then
      update citoyens set tresorerie = tresorerie + v_montant where id = v_uid;
      update tresor_public set solde = greatest(0, solde - v_montant) where id = 1;
    end if;
  end if;

  if auth.uid() = v_constat.destinataire_id then
    update constats_infraction set supprime_par_citoyen = true where id = p_id;
  else
    update constats_infraction set supprime_par_agent = true where id = p_id;
  end if;
end; $$;
grant execute on function retirer_constat_paye(uuid, numeric) to authenticated;
