-- ============================================================
-- patch-cib-entreprise-avancee-3.sql
-- À exécuter après patch-cib-entreprise-avancee-2.sql. Additif et rejouable.
--
--  1. virement_famille / virement_business / virement_econome acceptent
--     maintenant un CIB personnel en plus du nom d'utilisateur pour
--     identifier un destinataire citoyen. virement_famille et
--     virement_econome (destinataire unique) acceptent EN PLUS le CIB de
--     réception d'une entreprise : l'argent va alors dans sa trésorerie.
--  2. Nouveau : virement d'une entreprise vers un tiers, à partir de son
--     CIB d'envoi (droit 'transferer_argent'), vers un citoyen identifié
--     par nom d'utilisateur ou CIB personnel.
--  3. Table transferts : colonnes pour tracer une entreprise expéditrice
--     ou destinataire (l'historique détaillé reste à construire ; ceci
--     pose juste les données nécessaires sans casser l'existant).
--
-- HYPOTHÈSE : le virement business (plusieurs destinataires) reste
-- réservé aux citoyens (résolution par nom d'utilisateur OU CIB
-- personnel), pas aux entreprises — mélanger les deux complique le
-- partage par personne sans que ça ait été demandé explicitement.
-- ============================================================

alter table transferts add column if not exists entreprise_expediteur_id uuid references entreprises(id);
alter table transferts add column if not exists entreprise_destinataire_id uuid references entreprises(id);

-- Résout un texte (nom d'utilisateur OU CIB personnel actif) vers un citoyen.
create or replace function _resoudre_citoyen_ou_cib(p_texte text)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v_id uuid; v_code text;
begin
  select id into v_id from citoyens where lower(username) = lower(trim(p_texte));
  if v_id is not null then return v_id; end if;
  if trim(p_texte) ~ '^0R-0[0-9]+$' then
    select code_encrypte into v_code from cib_reserves where cib = trim(p_texte) and actif;
    if v_code is not null then select id into v_id from citoyens where code_social_encrypte = v_code; end if;
  end if;
  return v_id;
end; $$;

-- Résout un CIB de réception d'entreprise (acceptée) vers son id.
create or replace function _resoudre_entreprise_reception(p_texte text)
returns uuid language sql stable security definer set search_path = public as $$
  select c.entreprise_id from entreprises_cib c join entreprises e on e.id = c.entreprise_id
  where c.cib_reception = trim(p_texte) and e.statut = 'acceptee';
$$;

create or replace function virement_famille(p_destinataire_username text, p_montant numeric)
returns transferts language plpgsql security definer set search_path = public as $$
declare v_dest_id uuid; v_ent_id uuid; v_expediteur citoyens; v_taxe numeric; v_total numeric; v_row transferts;
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  if p_montant > 2000 then raise exception 'Le virement familial est limité à 2000 R$.'; end if;

  v_dest_id := _resoudre_citoyen_ou_cib(p_destinataire_username);
  if v_dest_id is null then v_ent_id := _resoudre_entreprise_reception(p_destinataire_username); end if;
  if v_dest_id is null and v_ent_id is null then raise exception 'Destinataire introuvable (nom d''utilisateur ou CIB).'; end if;
  if v_dest_id = auth.uid() then raise exception 'Impossible de se virer de l''argent à soi-même.'; end if;

  select * into v_expediteur from citoyens where id = auth.uid();
  v_taxe := p_montant * 0.0125;
  v_total := p_montant + v_taxe;
  if v_expediteur.tresorerie < v_total then raise exception 'Trésorerie insuffisante (total avec taxe: %).', v_total; end if;

  update citoyens set tresorerie = tresorerie - v_total where id = auth.uid();
  if v_ent_id is not null then
    update entreprises set tresorerie = tresorerie + p_montant where id = v_ent_id;
    perform _entreprise_regler_dette_employes(v_ent_id);
    perform _entreprise_log(v_ent_id, 'ajout_fonds', jsonb_build_object('citoyen_id', auth.uid(), 'montant', p_montant));
  else
    update citoyens set tresorerie = tresorerie + p_montant where id = v_dest_id;
  end if;
  update tresor_public set solde = solde + v_taxe where id = 1;

  insert into transferts (type, expediteur_id, destinataires, montant_par_personne, taxe_pourcentage, taxe_totale, total_debite, remboursable, entreprise_destinataire_id)
  values ('famille', auth.uid(), case when v_dest_id is not null then array[v_dest_id] else '{}'::uuid[] end, p_montant, 1.25, v_taxe, v_total, false, v_ent_id)
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function virement_famille(text, numeric) to authenticated;

create or replace function virement_business(p_destinataires_usernames text[], p_montant_par_personne numeric)
returns transferts language plpgsql security definer set search_path = public as $$
declare v_dest_ids uuid[] := '{}'; v_u text; v_id uuid; v_expediteur citoyens; v_total_verse numeric; v_taxe numeric; v_total_debite numeric; v_row transferts;
begin
  if p_montant_par_personne <= 0 then raise exception 'Le montant doit être positif.'; end if;
  foreach v_u in array p_destinataires_usernames loop
    v_id := _resoudre_citoyen_ou_cib(v_u);
    if v_id is not null then v_dest_ids := array_append(v_dest_ids, v_id); end if;
  end loop;
  if array_length(v_dest_ids, 1) is null then raise exception 'Aucun destinataire valide (nom d''utilisateur ou CIB).'; end if;
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

create or replace function virement_econome(p_destinataire_username text, p_montant numeric)
returns transferts language plpgsql security definer set search_path = public as $$
declare v_dest_id uuid; v_ent_id uuid; v_expediteur citoyens; v_taxe numeric; v_total numeric; v_row transferts;
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  if p_montant < 6000 or p_montant > 500000 then raise exception 'Le virement économe est réservé aux montants entre 6 000 R$ et 500 000 R$.'; end if;

  v_dest_id := _resoudre_citoyen_ou_cib(p_destinataire_username);
  if v_dest_id is null then v_ent_id := _resoudre_entreprise_reception(p_destinataire_username); end if;
  if v_dest_id is null and v_ent_id is null then raise exception 'Destinataire introuvable (nom d''utilisateur ou CIB).'; end if;
  if v_dest_id = auth.uid() then raise exception 'Impossible de se virer de l''argent à soi-même.'; end if;

  select * into v_expediteur from citoyens where id = auth.uid();
  v_taxe := p_montant * 0.0035;
  v_total := p_montant + v_taxe;
  if v_expediteur.tresorerie < v_total then raise exception 'Trésorerie insuffisante (total avec taxe: %).', v_total; end if;

  update citoyens set tresorerie = tresorerie - v_total where id = auth.uid();
  if v_ent_id is not null then
    update entreprises set tresorerie = tresorerie + p_montant where id = v_ent_id;
    perform _entreprise_regler_dette_employes(v_ent_id);
    perform _entreprise_log(v_ent_id, 'ajout_fonds', jsonb_build_object('citoyen_id', auth.uid(), 'montant', p_montant));
  else
    update citoyens set tresorerie = tresorerie + p_montant where id = v_dest_id;
  end if;
  update tresor_public set solde = solde + v_taxe where id = 1;

  insert into transferts (type, expediteur_id, destinataires, montant_par_personne, taxe_pourcentage, taxe_totale, total_debite, remboursable, entreprise_destinataire_id)
  values ('econome', auth.uid(), case when v_dest_id is not null then array[v_dest_id] else '{}'::uuid[] end, p_montant, 0.35, v_taxe, v_total, false, v_ent_id)
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function virement_econome(text, numeric) to authenticated;

-- Virement d'une entreprise (CIB d'envoi) vers un citoyen (nom d'utilisateur ou CIB personnel).
create or replace function entreprise_virement_vers_citoyen(p_entreprise_id uuid, p_destinataire text, p_montant numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_dest_id uuid; v_tresor numeric;
begin
  perform _exige_droit(p_entreprise_id, 'transferer_argent');
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  v_dest_id := _resoudre_citoyen_ou_cib(p_destinataire);
  if v_dest_id is null then raise exception 'Destinataire introuvable (nom d''utilisateur ou CIB).'; end if;

  select tresorerie into v_tresor from entreprises where id = p_entreprise_id for update;
  if v_tresor < p_montant then raise exception 'Trésorerie insuffisante.'; end if;

  update entreprises set tresorerie = tresorerie - p_montant where id = p_entreprise_id;
  update citoyens set tresorerie = tresorerie + p_montant where id = v_dest_id;
  perform _entreprise_log(p_entreprise_id, 'virement_tiers',
    jsonb_build_object('destinataire_username', (select username from citoyens where id = v_dest_id), 'montant', p_montant));
  insert into transferts (type, expediteur_id, destinataires, montant_par_personne, taxe_pourcentage, taxe_totale, total_debite, remboursable, entreprise_expediteur_id)
  values ('entreprise_tiers', auth.uid(), array[v_dest_id], p_montant, 0, 0, p_montant, false, p_entreprise_id);
end; $$;
grant execute on function entreprise_virement_vers_citoyen(uuid, text, numeric) to authenticated;

alter table transferts drop constraint if exists transferts_type_check;
alter table transferts add constraint transferts_type_check check (type in ('famille','business','econome','considerable','entreprise_tiers'));

-- ============================================================
-- FIN
-- ============================================================
