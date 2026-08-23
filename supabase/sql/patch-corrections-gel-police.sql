-- ============================================================
-- patch-corrections-gel-police.sql
-- À exécuter après patch-recompenses-et-corrections.sql. Idempotent.
--
-- CONTENU :
--  1. Corrections : gouv_transferer_depuis_banque manquante,
--     gouv_transferer_vers_banque ne doit plus jamais mettre le
--     gouvernement en négatif, gouv_payer_dus_selection doit refléter
--     la réalité du paiement (+ montant précis si une seule personne
--     est sélectionnée), le PIB de référence doit changer après un
--     rendement des contribuables.
--  2. Gel de l'économie / des messages par la police (recherche par CAS).
--  3. RHPE : le catalogue des méritas sort de Supabase, géré côté site
--     (JSON/HTML) — les fonctions acceptent maintenant le type en
--     paramètre au lieu d'une clé étrangère vers une table.
--
-- HYPOTHÈSE : les emprunts (table `emprunts`) n'ont pas de nom/description
-- libres — j'utilise leur numéro de suivi comme identifiant dans la fiche
-- policière. Le gel des messages utilise le champ existant
-- `supprime_pour_expediteur` (déjà prévu pour ça) sur les messages de
-- type 'normal' seulement (les messages 'gouvernemental' ne sont jamais
-- touchés, et il n'existe pas de type dédié "document"/"emprunt" dans la
-- table messages pour les distinguer plus finement).
-- ============================================================


-- ============================================================
-- 1) CORRECTIONS
-- ============================================================
create or replace function gouv_transferer_depuis_banque(p_banque_tag char(1), p_montant numeric, p_treasorerie_cible text default 'publique')
returns void language plpgsql security definer set search_path = public as $$
declare v_solde numeric;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if p_montant <= 0 then raise exception 'Montant invalide.'; end if;
  select tresorerie into v_solde from banques_nationales where tag = p_banque_tag for update;
  if v_solde is null then raise exception 'Banque invalide.'; end if;
  if v_solde < p_montant then raise exception 'Trésorerie de la banque insuffisante.'; end if;
  update banques_nationales set tresorerie = tresorerie - p_montant where tag = p_banque_tag;
  if p_treasorerie_cible = 'privee' then
    update tresor_public set solde_prive = solde_prive + p_montant where id = 1;
  else
    update tresor_public set solde = solde + p_montant where id = 1;
  end if;
end; $$;
grant execute on function gouv_transferer_depuis_banque(char, numeric, text) to authenticated;

create or replace function gouv_transferer_vers_banque(p_banque_tag char(1), p_montant numeric, p_treasorerie_preferee text default 'publique')
returns void language plpgsql security definer set search_path = public as $$
declare v_solde numeric; v_solde_prive numeric; v_home numeric;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if p_montant <= 0 then raise exception 'Montant invalide.'; end if;
  select solde, solde_prive into v_solde, v_solde_prive from tresor_public where id = 1 for update;
  v_home := case when p_treasorerie_preferee = 'privee' then v_solde_prive else v_solde end;
  if v_home < p_montant then raise exception 'Trésorerie du gouvernement insuffisante pour ce transfert (disponible : % R$).', v_home; end if;
  if p_treasorerie_preferee = 'privee' then
    update tresor_public set solde_prive = solde_prive - p_montant where id = 1;
  else
    update tresor_public set solde = solde - p_montant where id = 1;
  end if;
  update banques_nationales set tresorerie = tresorerie + p_montant where tag = p_banque_tag;
end; $$;
grant execute on function gouv_transferer_vers_banque(char, numeric, text) to authenticated;

drop function if exists gouv_payer_dus_selection(uuid[]);
create or replace function gouv_payer_dus_selection(p_citoyen_ids uuid[], p_montant_precis numeric default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_paye numeric; v_resultats jsonb := '[]'::jsonb; v_du numeric; v_plafond numeric;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé au gouvernement.'; end if;
  if p_montant_precis is not null and (p_citoyen_ids is null or array_length(p_citoyen_ids,1) <> 1) then
    raise exception 'Un montant précis ne peut être utilisé que pour une seule personne sélectionnée à la fois.';
  end if;
  foreach v_id in array p_citoyen_ids loop
    v_plafond := null;
    if p_montant_precis is not null then
      select argent_attendu into v_du from citoyens where id = v_id;
      if p_montant_precis > coalesce(v_du,0) then
        raise exception 'Le montant précis (% R$) dépasse le montant dû (% R$).', p_montant_precis, coalesce(v_du,0);
      end if;
      v_plafond := p_montant_precis;
    end if;
    v_paye := gouv_regler_argent_attendu(v_id, 'publique', v_plafond);
    v_resultats := v_resultats || jsonb_build_object('citoyen_id', v_id, 'paye', v_paye);
  end loop;
  return v_resultats;
end; $$;
grant execute on function gouv_payer_dus_selection(uuid[], numeric) to authenticated;

-- Le PIB de référence change désormais aussi après un rendement des
-- contribuables (en plus du rafraîchissement automatique à 59 jours).
create or replace function admin_traiter_redevance(
  p_nip text, p_decision text,
  p_congres_oui int default null, p_congres_non int default null, p_pourcentage numeric default null
) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_mon_username text; v_montant numeric; v_mot text; v_majorite numeric;
  v_gouv numeric; v_prev numeric; v_res jsonb;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé à l''administrateur.'; end if;
  if p_decision not in ('oui','non') then raise exception 'Décision invalide.'; end if;

  if not dans_fenetre_redevance() then
    if p_nip is null or p_nip <> '7000' then raise exception 'NIP invalide.'; end if;
  end if;

  select username into v_mon_username from citoyens where id = auth.uid();

  if p_decision = 'non' then
    update citoyens set taxes_gouv_60j = 0, taxe_preventive_60j = 0 where true;
    delete from transferts where true;
    return 'Redevance refusée : compteurs et historique de virements réinitialisés.';
  end if;

  if p_congres_oui is null or p_congres_non is null or p_pourcentage is null then
    raise exception 'Votes du Congrès et pourcentage requis pour attribuer une redevance.';
  end if;
  if p_pourcentage < 0 or p_pourcentage > 5 then
    raise exception 'Le pourcentage de rendement doit être entre 0%% et 5%%.';
  end if;

  v_majorite := round((p_congres_oui::numeric / nullif(p_congres_oui + p_congres_non, 0)) * 100, 2);

  if p_pourcentage <= 0.50 then v_mot := 'significatif';
  elsif p_pourcentage <= 3.00 then v_mot := 'conséquent';
  elsif p_pourcentage <= 4.51 then v_mot := 'considérable';
  else v_mot := 'exceptionnel';
  end if;

  for v_id, v_gouv, v_prev in select id, taxes_gouv_60j, taxe_preventive_60j from citoyens loop
    v_montant := least(5000, round((v_gouv + v_prev) * (p_pourcentage / 100.0), 2));
    if v_montant > 0 then
      v_res := gouv_payer_civil(v_id, v_montant, 'publique');
      insert into messages (type, expediteur_id, expediteur_username, destinataire_id, titre, contenu)
      values ('gouvernemental', auth.uid(), v_mon_username, v_id,
              'Rendement des contribuables',
              'Le rendement a été attribué par ' || p_congres_oui || ' chambres du Congrès (' || v_majorite || '%), vous avez été envoyé par le gouvernement : ' ||
              v_montant || ' R$ pour vous remercier de votre soutien et parce que la trésorerie du pays a fait un bénéfice ' || v_mot || '.' ||
              case when (v_res->>'manque')::numeric > 0 then ' (' || (v_res->>'manque') || ' R$ de ce montant a été placé en argent attendu, faute de fonds suffisants.)' else '' end);
    end if;
  end loop;

  update citoyens set taxes_gouv_60j = 0, taxe_preventive_60j = 0 where true;
  update tresor_public set taxes_totales_periode = 0 where id = 1;
  update pib_historique set pib_reference = pib_actuel(), date_reference = now() where id = 1;
  perform gouv_distribuer_argent_attendu();
  return 'Redevance attribuée à ' || p_pourcentage || '% (plafond 5000 R$/personne).';
end;
$$;
grant execute on function admin_traiter_redevance(text, text, int, int, numeric) to authenticated;


-- ============================================================
-- 2) GEL DE L'ÉCONOMIE / DES MESSAGES PAR LA POLICE (recherche CAS)
-- ============================================================
alter table citoyens add column if not exists economie_gelee boolean not null default false;
alter table citoyens add column if not exists messages_geles boolean not null default false;
alter table citoyens add column if not exists pays_naissance text;

create or replace function _est_agent_ou_gouv()
returns boolean language sql stable security definer set search_path = public as $$
  select est_admin_actuel() or coalesce((select est_agent_paix from citoyens where id = auth.uid()), false);
$$;

create or replace function police_geler_economie(p_citoyen_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not _est_agent_ou_gouv() then raise exception 'Accès refusé : réservé aux agents de la paix.'; end if;
  update citoyens set economie_gelee = true where id = p_citoyen_id;
end; $$;
grant execute on function police_geler_economie(uuid) to authenticated;

create or replace function police_degeler_economie(p_citoyen_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not _est_agent_ou_gouv() then raise exception 'Accès refusé : réservé aux agents de la paix.'; end if;
  update citoyens set economie_gelee = false where id = p_citoyen_id;
end; $$;
grant execute on function police_degeler_economie(uuid) to authenticated;

create or replace function police_geler_messages(p_citoyen_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not _est_agent_ou_gouv() then raise exception 'Accès refusé : réservé aux agents de la paix.'; end if;
  update citoyens set messages_geles = true where id = p_citoyen_id;
  update messages set supprime_pour_expediteur = true where expediteur_id = p_citoyen_id and type = 'normal';
end; $$;
grant execute on function police_geler_messages(uuid) to authenticated;

create or replace function police_degeler_messages(p_citoyen_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not _est_agent_ou_gouv() then raise exception 'Accès refusé : réservé aux agents de la paix.'; end if;
  update citoyens set messages_geles = false where id = p_citoyen_id;
end; $$;
grant execute on function police_degeler_messages(uuid) to authenticated;

-- Fiche complète pour la police (via CAS) : diplômes tiers (DFTN1/DFTN2/
-- DRAEE, jamais RHPE), infos personnelles, contrats actifs, historique
-- de virements.
create or replace function police_chercher_par_cas(p_cas text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_citoyen citoyens; v_diplomes jsonb; v_emprunts jsonb; v_virements jsonb;
begin
  if not _est_agent_ou_gouv() then raise exception 'Accès refusé : réservé aux agents de la paix.'; end if;
  select * into v_citoyen from citoyens where code_social_encrypte = p_cas;
  if v_citoyen is null then raise exception 'Aucun citoyen trouvé pour ce code d''assurance social.'; end if;

  select coalesce(jsonb_agg(jsonb_build_object('formation', f.nom, 'niveau', f.niveau, 'code', a.code, 'date_fin', a.date_fin)), '[]'::jsonb)
    into v_diplomes
    from aft_attributions a join aft_formations f on f.id = a.formation_id
    where a.citoyen_id = v_citoyen.id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'numero_suivi', e.numero_suivi, 'montant_initial', e.montant_initial,
    'taux_interet', e.taux_interet, 'role', case when e.preteur_id = v_citoyen.id then 'preteur' else 'emprunteur' end,
    'date_limite', e.date_limite
  )), '[]'::jsonb) into v_emprunts
  from emprunts e where (e.preteur_id = v_citoyen.id or e.emprunteur_id = v_citoyen.id) and e.statut = 'actif';

  select coalesce(jsonb_agg(jsonb_build_object(
    'type', t.type, 'expediteur_id', t.expediteur_id, 'destinataires', t.destinataires,
    'montant_par_personne', t.montant_par_personne, 'total_debite', t.total_debite, 'cree_le', t.cree_le
  ) order by t.cree_le desc), '[]'::jsonb) into v_virements
  from transferts t where t.expediteur_id = v_citoyen.id or v_citoyen.id = any(t.destinataires);

  return jsonb_build_object(
    'nom', v_citoyen.nom, 'prenom', v_citoyen.prenom, 'date_naissance', v_citoyen.date_naissance,
    'age_toutouien', age_toutouien(v_citoyen.date_naissance), 'pays_naissance', v_citoyen.pays_naissance,
    'email', v_citoyen.email, 'cree_le', v_citoyen.cree_le, 'id', v_citoyen.id, 'username', v_citoyen.username,
    'tresorerie', v_citoyen.tresorerie, 'dettes', v_citoyen.dettes, 'prets', v_citoyen.prets,
    'argent_attendu', v_citoyen.argent_attendu, 'economie_gelee', v_citoyen.economie_gelee,
    'messages_geles', v_citoyen.messages_geles,
    'diplomes_tiers', v_diplomes, 'contrats_actifs', v_emprunts, 'historique_virements', v_virements
  );
end; $$;
grant execute on function police_chercher_par_cas(text) to authenticated;

-- Retrofit des blocages "économie gelée" sur les fonctions déjà connues
-- (virements, permis, salaire). Chômage/retraite/acceptation d'emprunt et
-- l'onglet banque ne sont PAS retouchés ici : je n'ai pas encore vu leurs
-- fonctions exactes et je préfère ne pas deviner leur signature — dites-moi
-- si vous voulez que je les ajoute et je vérifierai leur code d'abord.

create or replace function virement_famille(p_destinataire_username text, p_montant numeric)
returns transferts language plpgsql security definer set search_path = public as $$
declare v_dest_id uuid; v_expediteur citoyens; v_taxe numeric; v_total numeric; v_row transferts;
begin
  if (select economie_gelee from citoyens where id = auth.uid()) then raise exception 'Votre économie est gelée : virements désactivés.'; end if;
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  if p_montant > 2000 then raise exception 'Le virement familial est limité à 2000 R$.'; end if;
  select id into v_dest_id from citoyens where lower(username) = lower(p_destinataire_username);
  if v_dest_id is null then raise exception 'Destinataire introuvable.'; end if;
  if v_dest_id = auth.uid() then raise exception 'Impossible de se virer de l''argent à soi-même.'; end if;
  if (select economie_gelee from citoyens where id = v_dest_id) then raise exception 'L''économie du destinataire est gelée : encaissement refusé.'; end if;

  select * into v_expediteur from citoyens where id = auth.uid();
  v_taxe := p_montant * 0.0125;
  v_total := p_montant + v_taxe;
  if v_expediteur.tresorerie < v_total then raise exception 'Trésorerie insuffisante (total avec taxe: %).', v_total; end if;

  update citoyens set tresorerie = tresorerie - v_total where id = auth.uid();
  update citoyens set tresorerie = tresorerie + p_montant where id = v_dest_id;
  update tresor_public set solde_prive = solde_prive + v_taxe where id = 1;

  insert into transferts (type, expediteur_id, destinataires, montant_par_personne, taxe_pourcentage, taxe_totale, total_debite, remboursable)
  values ('famille', auth.uid(), array[v_dest_id], p_montant, 1.25, v_taxe, v_total, false)
  returning * into v_row;
  perform gouv_distribuer_argent_attendu();
  return v_row;
end; $$;
grant execute on function virement_famille(text, numeric) to authenticated;

create or replace function virement_business(p_destinataires_usernames text[], p_montant_par_personne numeric)
returns transferts language plpgsql security definer set search_path = public as $$
declare v_dest_ids uuid[]; v_expediteur citoyens; v_total_verse numeric; v_taxe numeric; v_total_debite numeric; v_id uuid; v_row transferts;
begin
  if (select economie_gelee from citoyens where id = auth.uid()) then raise exception 'Votre économie est gelée : virements désactivés.'; end if;
  if p_montant_par_personne <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select array_agg(id) into v_dest_ids from citoyens where lower(username) = any (select lower(u) from unnest(p_destinataires_usernames) as u);
  if v_dest_ids is null or array_length(v_dest_ids, 1) is null then raise exception 'Aucun destinataire valide.'; end if;
  if auth.uid() = any(v_dest_ids) then raise exception 'Impossible de s''inclure soi-même comme destinataire.'; end if;
  if exists (select 1 from citoyens where id = any(v_dest_ids) and economie_gelee) then
    raise exception 'L''économie d''au moins un destinataire est gelée : virement refusé.';
  end if;

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
  update tresor_public set solde_prive = solde_prive + v_taxe where id = 1;

  insert into transferts (type, expediteur_id, destinataires, montant_par_personne, taxe_pourcentage, taxe_totale, total_debite, remboursable)
  values ('business', auth.uid(), v_dest_ids, p_montant_par_personne, 1.65, v_taxe, v_total_debite, true)
  returning * into v_row;
  perform gouv_distribuer_argent_attendu();
  return v_row;
end; $$;
grant execute on function virement_business(text[], numeric) to authenticated;

create or replace function virement_econome(p_destinataire_username text, p_montant numeric)
returns transferts language plpgsql security definer set search_path = public as $$
declare v_dest_id uuid; v_expediteur citoyens; v_taxe numeric; v_total numeric; v_row transferts;
begin
  if (select economie_gelee from citoyens where id = auth.uid()) then raise exception 'Votre économie est gelée : virements désactivés.'; end if;
  if p_montant < 6000 or p_montant > 500000 then
    raise exception 'Le virement économe doit être entre 6 000 R$ et 500 000 R$.';
  end if;
  select id into v_dest_id from citoyens where lower(username) = lower(p_destinataire_username);
  if v_dest_id is null then raise exception 'Destinataire introuvable.'; end if;
  if v_dest_id = auth.uid() then raise exception 'Impossible de se virer de l''argent à soi-même.'; end if;
  if (select economie_gelee from citoyens where id = v_dest_id) then raise exception 'L''économie du destinataire est gelée : encaissement refusé.'; end if;

  select * into v_expediteur from citoyens where id = auth.uid();
  v_taxe := p_montant * 0.0035;
  v_total := p_montant + v_taxe;
  if v_expediteur.tresorerie < v_total then raise exception 'Trésorerie insuffisante (total avec taxe: %).', v_total; end if;

  update citoyens set tresorerie = tresorerie - v_total where id = auth.uid();
  update citoyens set tresorerie = tresorerie + p_montant where id = v_dest_id;
  update tresor_public set solde_prive = solde_prive + v_taxe where id = 1;

  insert into transferts (type, expediteur_id, destinataires, montant_par_personne, taxe_pourcentage, taxe_totale, total_debite, remboursable)
  values ('econome', auth.uid(), array[v_dest_id], p_montant, 0.35, v_taxe, v_total, false)
  returning * into v_row;
  perform gouv_distribuer_argent_attendu();
  return v_row;
end; $$;
grant execute on function virement_econome(text, numeric) to authenticated;

create or replace function tenter_accepter_virement_considerable(p_id uuid, p_nip text)
returns text language plpgsql security definer set search_path = public as $$
declare v_row virements_considerables; v_mon_username text;
begin
  if (select economie_gelee from citoyens where id = auth.uid()) then raise exception 'Votre économie est gelée : encaissement refusé.'; end if;
  select * into v_row from virements_considerables where id = p_id and destinataire_id = auth.uid();
  if v_row is null then raise exception 'Virement introuvable.'; end if;
  if v_row.statut = 'accepte' then raise exception 'Ce virement a déjà été accepté.'; end if;
  if v_row.statut = 'supprime' then raise exception 'Ce virement a été annulé.'; end if;
  if v_row.bloque_jusqua is not null and v_row.bloque_jusqua > now() then
    raise exception 'Virement temporairement bloqué jusqu''à %.', v_row.bloque_jusqua;
  end if;

  if p_nip = v_row.nip_acceptation then
    update citoyens set tresorerie = tresorerie + v_row.montant where id = auth.uid();
    update tresor_public set solde_prive = solde_prive + v_row.taxe_montant where id = 1;
    update virements_considerables set statut = 'accepte', traite_le = now() where id = p_id;
    perform gouv_distribuer_argent_attendu();
    return 'accepte';
  end if;

  update virements_considerables set tentatives = tentatives + 1 where id = p_id returning * into v_row;

  if v_row.tentatives = 1 then
    return 'echec_1';
  elsif v_row.tentatives = 2 then
    update virements_considerables set statut = 'bloque_1h', bloque_jusqua = now() + interval '1 hour' where id = p_id;
    return 'bloque_1h';
  elsif v_row.tentatives = 3 then
    update virements_considerables set statut = 'bloque_15j', bloque_jusqua = now() + interval '15 days' where id = p_id;
    return 'bloque_15j';
  else
    update citoyens set tresorerie = tresorerie + v_row.montant + v_row.taxe_montant where id = v_row.expediteur_id;
    update virements_considerables set statut = 'supprime', traite_le = now() where id = p_id;
    select username into v_mon_username from citoyens where id = auth.uid();
    insert into messages (type, expediteur_id, expediteur_username, destinataire_id, titre, contenu)
    values ('normal', v_row.destinataire_id, v_mon_username, v_row.expediteur_id,
            'Virement considérable annulé',
            'Le destinataire a échoué 4 fois à entrer le NIP d''acceptation. Le virement de ' || v_row.montant || ' R$ (+ taxes) vous a été remboursé intégralement.');
    return 'supprime';
  end if;
end;
$$;
grant execute on function tenter_accepter_virement_considerable(uuid, text) to authenticated;

create or replace function acheter_permis(p_type text, p_adresse_livraison text)
returns permis_citoyens language plpgsql security definer set search_path = public as $$
declare
  v_base numeric; v_total numeric; v_citoyen citoyens; v_expire date; v_row permis_citoyens;
begin
  if (select economie_gelee from citoyens where id = auth.uid()) then raise exception 'Votre économie est gelée : achats désactivés.'; end if;
  if p_type not in ('peche','chasse','travail') then raise exception 'Type de permis invalide.'; end if;
  if p_adresse_livraison is null or char_length(trim(p_adresse_livraison)) = 0 then
    raise exception 'Une adresse de livraison est requise.';
  end if;

  if exists (
    select 1 from permis_citoyens
    where citoyen_id = auth.uid() and type = p_type and (expire_le is null or expire_le >= current_date)
  ) then
    raise exception 'Vous détenez déjà un permis de ce type, encore valide.';
  end if;

  v_base := case p_type when 'peche' then 65.59 when 'chasse' then 178.59 else 0 end;
  v_total := round(v_base * 1.15, 2);
  v_expire := case when p_type = 'travail' then null else (current_date + interval '1 year')::date end;

  select * into v_citoyen from citoyens where id = auth.uid();
  if v_citoyen.tresorerie < v_total then raise exception 'Trésorerie insuffisante.'; end if;

  if v_total > 0 then
    update citoyens set tresorerie = tresorerie - v_total where id = auth.uid();
    update tresor_public set solde_prive = solde_prive + v_total where id = 1;
  end if;

  insert into permis_citoyens (citoyen_id, type, prix_paye, expire_le, adresse_livraison)
  values (auth.uid(), p_type, v_total, v_expire, p_adresse_livraison)
  returning * into v_row;

  perform gouv_distribuer_argent_attendu();
  return v_row;
end;
$$;
grant execute on function acheter_permis(text, text) to authenticated;

-- Salaire désactivé quand l'économie est gelée : reste fixe.
create or replace function deposer_revenu_citoyen(p_minutes numeric default 1.0/60)
returns public.citoyens language plpgsql security definer set search_path = public as $$
declare
  v_citoyen public.citoyens; v_taux_preventif numeric; v_brut numeric; v_periode_60 int;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  select * into v_citoyen from citoyens where id = auth.uid();
  if v_citoyen is null then raise exception 'Citoyen introuvable.'; end if;

  if v_citoyen.economie_gelee then
    update citoyens set derniere_synchro_tresorerie = now() where id = auth.uid() returning * into v_citoyen;
    return v_citoyen;
  end if;

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


-- ============================================================
-- 3) RHPE : catalogue sorti de Supabase (géré côté site désormais)
-- ============================================================
alter table recompenses_demandes add column if not exists type_nom text;
alter table recompenses_demandes add column if not exists categorie text;
alter table recompenses_demandes alter column type_id drop not null;

alter table recompenses_attributions add column if not exists type_nom text;
alter table recompenses_attributions add column if not exists categorie text;
alter table recompenses_attributions add column if not exists image text;
alter table recompenses_attributions alter column type_id drop not null;

create or replace function recompenses_demander(
  p_type_nom text, p_categorie text, p_quand text, p_ou text, p_nom_personne_affectee text, p_nom_meritant text,
  p_raison text, p_date_acte date, p_heure_acte text, p_promesse_fidelite boolean,
  p_informations_supplementaires jsonb default '{}'::jsonb
) returns public.recompenses_demandes language plpgsql security definer set search_path = public as $$
declare v_row public.recompenses_demandes;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if p_nom_meritant is null or p_raison is null then raise exception 'Nom du méritant et raison sont requis.'; end if;
  if p_categorie not in ('rhpe_royale','rhpe_excellence','rhpe_base','draee') then raise exception 'Catégorie invalide.'; end if;

  insert into recompenses_demandes (type_nom, categorie, demandeur_id, quand, où, nom_personne_affectee, nom_meritant,
    raison, date_acte, heure_acte, promesse_fidelite, informations_supplementaires, numero_suivi_demande)
  values (p_type_nom, p_categorie, auth.uid(), p_quand, p_ou, p_nom_personne_affectee, p_nom_meritant,
    p_raison, p_date_acte, p_heure_acte, coalesce(p_promesse_fidelite,false), coalesce(p_informations_supplementaires,'{}'::jsonb),
    'DEM-' || _generer_code_alnum(10))
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function recompenses_demander(text,text,text,text,text,text,text,date,text,boolean,jsonb) to authenticated;

create or replace function mes_demandes_recompenses()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id, 'type', type_nom, 'categorie', categorie, 'statut', statut,
    'numero_suivi_demande', numero_suivi_demande, 'cree_le', cree_le, 'reponse', reponse
  ) order by cree_le desc), '[]'::jsonb)
  from recompenses_demandes where demandeur_id = auth.uid();
$$;
grant execute on function mes_demandes_recompenses() to authenticated;

create or replace function gouv_liste_demandes_recompenses(p_statut text default 'en_attente')
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not est_admin_actuel() then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
    'id', d.id, 'type', d.type_nom, 'categorie', d.categorie, 'demandeur_username', c.username,
    'nom_meritant', d.nom_meritant, 'raison', d.raison, 'quand', d.quand, 'où', d.où,
    'date_acte', d.date_acte, 'numero_suivi_demande', d.numero_suivi_demande, 'cree_le', d.cree_le
  ) order by d.cree_le), '[]'::jsonb) end
  from recompenses_demandes d join citoyens c on c.id = d.demandeur_id
  where d.statut = p_statut;
$$;
grant execute on function gouv_liste_demandes_recompenses(text) to authenticated;

create or replace function gouv_traiter_demande_recompense(
  p_demande_id uuid, p_decision text, p_reponse text, p_longueur_code int,
  p_image text, p_verifie_par_username text, p_supervise_par_username text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_demande public.recompenses_demandes; v_code text; v_attrib public.recompenses_attributions;
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
    v_code := v_demande.categorie || '-' || _generer_code_alnum(coalesce(p_longueur_code, 10));
    insert into recompenses_attributions (type_nom, categorie, image, demande_id, citoyen_id, numero_suivi_meritas, verifie_par_username, supervise_par_username)
      values (v_demande.type_nom, v_demande.categorie, p_image, v_demande.id, v_demande.demandeur_id, v_code, p_verifie_par_username, p_supervise_par_username)
      returning * into v_attrib;
    return jsonb_build_object('demande', to_jsonb(v_demande), 'attribution', to_jsonb(v_attrib));
  end if;
  return jsonb_build_object('demande', to_jsonb(v_demande));
end; $$;
grant execute on function gouv_traiter_demande_recompense(uuid,text,text,int,text,text,text) to authenticated;

create or replace function recompenses_vitrine(p_username text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_id uuid;
begin
  if p_username is null then v_id := auth.uid();
  else select id into v_id from citoyens where lower(username) = lower(p_username); end if;
  if v_id is null then return '[]'::jsonb; end if;

  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', a.id, 'type', a.type_nom, 'categorie', a.categorie, 'image', a.image,
    'numero_suivi_meritas', a.numero_suivi_meritas, 'donne_le', a.donne_le
  ) order by a.donne_le desc) from recompenses_attributions a where a.citoyen_id = v_id), '[]'::jsonb);
end; $$;
grant execute on function recompenses_vitrine(text) to authenticated, anon;

create or replace function recompenses_detail_attribution(p_attribution_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'attribution', jsonb_build_object(
      'numero_suivi_meritas', a.numero_suivi_meritas, 'donne_le', a.donne_le,
      'verifie_par', a.verifie_par_username, 'supervise_par', a.supervise_par_username,
      'type', a.type_nom, 'categorie', a.categorie, 'image', a.image
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
  left join recompenses_demandes d on d.id = a.demande_id
  where a.id = p_attribution_id;
$$;
grant execute on function recompenses_detail_attribution(uuid) to authenticated, anon;

-- ============================================================
-- FIN
-- ============================================================
