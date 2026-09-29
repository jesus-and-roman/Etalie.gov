-- ============================================================
-- patch-cib-entreprise-avancee-4.sql
-- À exécuter après patch-cib-entreprise-avancee-3.sql. Additif et rejouable.
--
--  1. Pourcentage de confiance d'un compte : le message d'origine décrivant
--     la formule était coupé ("(...jours...) × 0,001)+"). Je documente donc
--     ma propre formule, transparente et plafonnée par terme (voir
--     HYPOTHÈSE), affichée terme par terme pour que ce soit ajustable
--     facilement plus tard si la vraie formule diffère.
--  2. Page "Transfert (confiance)" : recherche un destinataire (nom
--     d'utilisateur ou CIB), affiche son calcul de confiance, puis permet
--     d'envoyer directement (taxe selon palier familial/économe existant).
--  3. Historique enrichi : dossiers, note personnelle, masquage propre à
--     chaque personne (ne supprime rien pour l'autre partie), signalement
--     au gouvernement des finances, entrées "Artificiel" (cosmétiques,
--     n'affectent aucune trésorerie), noms résolus (utilisateur ou
--     entreprise) pour l'expéditeur et le destinataire.
--
-- HYPOTHÈSE (formule de confiance, faute du texte complet) :
--   confiance % = clamp(0, 100, 50
--     + min(jours_compte × 0,1 %, 30 %)              -- ancienneté
--     − min(dettes ÷ 1000 × 2 %, 25 %)                -- dettes ouvertes
--     − (nb constats non payés × 3 %)
--     + min(nb formations obtenues × 1 %, 10 %)
--     + min(nb récompenses obtenues × 1 %, 10 %)
--     − (a un signalement de finance non traité contre lui × 5 %))
--   Chaque terme est renvoyé séparément pour audit/ajustement.
-- ============================================================


-- ============================================================
-- 1) POURCENTAGE DE CONFIANCE
-- ============================================================
create or replace function citoyen_confiance(p_citoyen_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c citoyens; v_jours numeric; v_anciennete numeric; v_dette_pen numeric; v_constats int;
  v_constats_pen numeric; v_formations int; v_formations_bonus numeric; v_recompenses int;
  v_recompenses_bonus numeric; v_signalements int; v_signalements_pen numeric; v_score numeric;
begin
  select * into c from citoyens where id = p_citoyen_id;
  if c.id is null then raise exception 'Citoyen introuvable.'; end if;

  v_jours := extract(epoch from (now() - c.cree_le)) / 86400.0;
  v_anciennete := least(v_jours * 0.1, 30);
  v_dette_pen := least(coalesce(c.dettes, 0) / 1000.0 * 2, 25);

  select count(*) into v_constats from constats_infraction where destinataire_id = p_citoyen_id and coalesce(paye, false) = false;
  v_constats_pen := v_constats * 3;

  select count(*) into v_formations from aft_attributions where citoyen_id = p_citoyen_id;
  v_formations_bonus := least(v_formations * 1, 10);

  select count(*) into v_recompenses from recompenses_attributions where citoyen_id = p_citoyen_id;
  v_recompenses_bonus := least(v_recompenses * 1, 10);

  select count(*) into v_signalements from signalements_finance where cible_id = p_citoyen_id and statut <> 'rejete';
  v_signalements_pen := v_signalements * 5;

  v_score := greatest(0, least(100, 50 + v_anciennete - v_dette_pen - v_constats_pen + v_formations_bonus + v_recompenses_bonus - v_signalements_pen));

  return jsonb_build_object(
    'score', round(v_score, 2),
    'termes', jsonb_build_object(
      'base', 50, 'jours_compte', round(v_jours), 'anciennete', round(v_anciennete, 2),
      'dettes', c.dettes, 'penalite_dettes', round(v_dette_pen, 2),
      'constats_impayes', v_constats, 'penalite_constats', round(v_constats_pen, 2),
      'formations', v_formations, 'bonus_formations', round(v_formations_bonus, 2),
      'recompenses', v_recompenses, 'bonus_recompenses', round(v_recompenses_bonus, 2),
      'signalements', v_signalements, 'penalite_signalements', round(v_signalements_pen, 2)
    )
  );
end; $$;
grant execute on function citoyen_confiance(uuid) to authenticated;

create or replace function confiance_par_identifiant(p_texte text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_id uuid;
begin
  v_id := _resoudre_citoyen_ou_cib(p_texte);
  if v_id is null then raise exception 'Citoyen introuvable (nom d''utilisateur ou CIB).'; end if;
  return jsonb_build_object('username', (select username from citoyens where id = v_id)) || citoyen_confiance(v_id);
end; $$;
grant execute on function confiance_par_identifiant(text) to authenticated;

-- Virement "avec confiance" : mêmes taxes que familial (≤2000 R$) ou
-- économe (2000 à 500000 R$), choisies automatiquement selon le montant.
create or replace function virement_confiance(p_destinataire text, p_montant numeric)
returns transferts language plpgsql security definer set search_path = public as $$
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  if p_montant <= 2000 then return virement_famille(p_destinataire, p_montant);
  else return virement_econome(p_destinataire, p_montant); end if;
end; $$;
grant execute on function virement_confiance(text, numeric) to authenticated;


-- ============================================================
-- 2) HISTORIQUE ENRICHI
-- ============================================================
create table if not exists dossiers_virements (
  id         uuid primary key default gen_random_uuid(),
  citoyen_id uuid not null references auth.users(id) on delete cascade,
  nom        text not null,
  cree_le    timestamptz not null default now(),
  unique (citoyen_id, nom)
);
alter table dossiers_virements enable row level security;
drop policy if exists "Voir ses propres dossiers" on dossiers_virements;
create policy "Voir ses propres dossiers" on dossiers_virements for select using (citoyen_id = auth.uid());

create or replace function creer_dossier_virement(p_nom text)
returns dossiers_virements language plpgsql security definer set search_path = public as $$
declare v_row dossiers_virements;
begin
  if p_nom is null or char_length(trim(p_nom)) = 0 then raise exception 'Nom de dossier requis.'; end if;
  insert into dossiers_virements (citoyen_id, nom) values (auth.uid(), trim(p_nom)) returning * into v_row;
  return v_row;
end; $$;
grant execute on function creer_dossier_virement(text) to authenticated;

create or replace function supprimer_dossier_virement(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update transferts_meta set dossier_id = null where dossier_id = p_id and citoyen_id = auth.uid();
  delete from dossiers_virements where id = p_id and citoyen_id = auth.uid();
end; $$;
grant execute on function supprimer_dossier_virement(uuid) to authenticated;

-- Métadonnées PROPRES À CHAQUE PERSONNE sur un virement partagé (ne touche jamais l'autre partie).
create table if not exists transferts_meta (
  transfert_id uuid not null references transferts(id) on delete cascade,
  citoyen_id   uuid not null references auth.users(id) on delete cascade,
  masque       boolean not null default false,
  note         text check (char_length(note) <= 500),
  dossier_id   uuid references dossiers_virements(id) on delete set null,
  primary key (transfert_id, citoyen_id)
);
alter table transferts_meta enable row level security;
drop policy if exists "Voir ses propres méta de virement" on transferts_meta;
create policy "Voir ses propres méta de virement" on transferts_meta for select using (citoyen_id = auth.uid());

create or replace function _maj_meta_transfert(p_transfert_id uuid, p_masque boolean, p_note text, p_dossier_id uuid, p_effacer_dossier boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from transferts t where t.id = p_transfert_id and (t.expediteur_id = auth.uid() or auth.uid() = any(t.destinataires))) then
    raise exception 'Ce virement ne vous concerne pas.';
  end if;
  insert into transferts_meta (transfert_id, citoyen_id, masque, note, dossier_id)
    values (p_transfert_id, auth.uid(), coalesce(p_masque, false), p_note, p_dossier_id)
  on conflict (transfert_id, citoyen_id) do update set
    masque = coalesce(p_masque, transferts_meta.masque),
    note = case when p_note is not null then p_note else transferts_meta.note end,
    dossier_id = case when p_effacer_dossier then null when p_dossier_id is not null then p_dossier_id else transferts_meta.dossier_id end;
end; $$;

create or replace function masquer_transfert(p_transfert_id uuid)
returns void language sql security definer set search_path = public as $$
  select _maj_meta_transfert(p_transfert_id, true, null, null, false);
$$;
grant execute on function masquer_transfert(uuid) to authenticated;

create or replace function noter_transfert(p_transfert_id uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_note is not null and char_length(p_note) > 500 then raise exception 'Note limitée à 500 caractères.'; end if;
  perform _maj_meta_transfert(p_transfert_id, null, coalesce(p_note, ''), null, false);
end; $$;
grant execute on function noter_transfert(uuid, text) to authenticated;

create or replace function classer_transfert(p_transfert_id uuid, p_dossier_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_dossier_id is not null and not exists (select 1 from dossiers_virements where id = p_dossier_id and citoyen_id = auth.uid()) then
    raise exception 'Dossier introuvable.';
  end if;
  perform _maj_meta_transfert(p_transfert_id, null, null, p_dossier_id, p_dossier_id is null);
end; $$;
grant execute on function classer_transfert(uuid, uuid) to authenticated;

create table if not exists signalements_finance (
  id           uuid primary key default gen_random_uuid(),
  declarant_id uuid not null references auth.users(id),
  cible_id     uuid references auth.users(id),
  transfert_id uuid references transferts(id),
  motif        text not null,
  statut       text not null default 'en_attente' check (statut in ('en_attente','traite','rejete')),
  cree_le      timestamptz not null default now()
);
alter table signalements_finance enable row level security;
drop policy if exists "Voir ses signalements ou tout si admin" on signalements_finance;
create policy "Voir ses signalements ou tout si admin" on signalements_finance for select
  using (declarant_id = auth.uid() or est_admin_actuel());

create or replace function signaler_transfert(p_transfert_id uuid, p_motif text)
returns void language plpgsql security definer set search_path = public as $$
declare t transferts;
begin
  select * into t from transferts where id = p_transfert_id;
  if t.id is null or (t.expediteur_id <> auth.uid() and not (auth.uid() = any(t.destinataires))) then
    raise exception 'Ce virement ne vous concerne pas.';
  end if;
  if p_motif is null or char_length(trim(p_motif)) < 10 then raise exception 'Motif requis (10 caractères minimum).'; end if;
  insert into signalements_finance (declarant_id, cible_id, transfert_id, motif)
    values (auth.uid(), case when t.expediteur_id = auth.uid() then null else t.expediteur_id end, p_transfert_id, trim(p_motif));
end; $$;
grant execute on function signaler_transfert(uuid, text) to authenticated;

create or replace function gouv_traiter_signalement_finance(p_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  if p_decision not in ('traite','rejete') then raise exception 'Décision invalide.'; end if;
  update signalements_finance set statut = p_decision where id = p_id;
end; $$;
grant execute on function gouv_traiter_signalement_finance(uuid, text) to authenticated;

-- Entrées "Artificiel" : purement cosmétiques, propres à chaque citoyen.
create table if not exists transferts_artificiels (
  id             uuid primary key default gen_random_uuid(),
  citoyen_id     uuid not null references auth.users(id) on delete cascade,
  type           text not null,
  montant        numeric not null,
  date_effectuee date not null,
  note           text check (char_length(note) <= 500),
  dossier_id     uuid references dossiers_virements(id) on delete set null,
  cree_le        timestamptz not null default now()
);
alter table transferts_artificiels enable row level security;
drop policy if exists "Voir ses propres entrées artificielles" on transferts_artificiels;
create policy "Voir ses propres entrées artificielles" on transferts_artificiels for select using (citoyen_id = auth.uid());

create or replace function creer_transfert_artificiel(p_type text, p_montant numeric, p_date date, p_note text, p_dossier_id uuid default null)
returns transferts_artificiels language plpgsql security definer set search_path = public as $$
declare v_row transferts_artificiels;
begin
  if p_type is null or char_length(trim(p_type)) = 0 then raise exception 'Type requis.'; end if;
  if p_dossier_id is not null and not exists (select 1 from dossiers_virements where id = p_dossier_id and citoyen_id = auth.uid()) then
    raise exception 'Dossier introuvable.';
  end if;
  insert into transferts_artificiels (citoyen_id, type, montant, date_effectuee, note, dossier_id)
    values (auth.uid(), trim(p_type), p_montant, coalesce(p_date, current_date), p_note, p_dossier_id)
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function creer_transfert_artificiel(text, numeric, date, text, uuid) to authenticated;

create or replace function supprimer_transfert_artificiel(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from transferts_artificiels where id = p_id and citoyen_id = auth.uid();
end; $$;
grant execute on function supprimer_transfert_artificiel(uuid) to authenticated;

-- Nom lisible d'une partie (citoyen ou entreprise) pour l'affichage de l'historique.
create or replace function _nom_partie(p_citoyen_id uuid, p_entreprise_id uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select nom from entreprises where id = p_entreprise_id), '@' || (select username from citoyens where id = p_citoyen_id), 'inconnu');
$$;

-- Historique complet : virements réels (avec méta perso) + entrées artificielles.
create or replace function mon_historique_virements(p_dossier_id uuid default null, p_inclure_masques boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_reels jsonb; v_art jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', t.id, 'artificiel', false, 'type', t.type, 'cree_le', t.cree_le,
    'montant_par_personne', t.montant_par_personne, 'total_debite', t.total_debite, 'rembourse', t.rembourse,
    'expediteur', _nom_partie(t.expediteur_id, t.entreprise_expediteur_id),
    'destinataires', (select coalesce(jsonb_agg(_nom_partie(d, null)), '[]'::jsonb) from unnest(t.destinataires) d),
    'entreprise_destinataire', (select nom from entreprises where id = t.entreprise_destinataire_id),
    'sens', case when t.expediteur_id = auth.uid() and t.entreprise_expediteur_id is null then 'envoye' else 'recu' end,
    'note', m.note, 'dossier_id', m.dossier_id
  ) order by t.cree_le desc), '[]'::jsonb)
  into v_reels
  from transferts t left join transferts_meta m on m.transfert_id = t.id and m.citoyen_id = auth.uid()
  where (t.expediteur_id = auth.uid() or auth.uid() = any(t.destinataires))
    and (p_inclure_masques or coalesce(m.masque, false) = false)
    and (p_dossier_id is null or m.dossier_id = p_dossier_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', a.id, 'artificiel', true, 'type', a.type, 'cree_le', a.date_effectuee::timestamptz,
    'montant_par_personne', a.montant, 'note', a.note, 'dossier_id', a.dossier_id
  ) order by a.date_effectuee desc), '[]'::jsonb)
  into v_art from transferts_artificiels a where a.citoyen_id = auth.uid()
    and (p_dossier_id is null or a.dossier_id = p_dossier_id);

  return jsonb_build_object('virements', v_reels, 'artificiels', v_art);
end; $$;
grant execute on function mon_historique_virements(uuid, boolean) to authenticated;

create or replace function mes_dossiers_virements()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nom', nom) order by nom), '[]'::jsonb)
  from dossiers_virements where citoyen_id = auth.uid();
$$;
grant execute on function mes_dossiers_virements() to authenticated;

-- ============================================================
-- FIN
-- ============================================================
