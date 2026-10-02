-- ============================================================
-- patch-cib-entreprise-avancee-10.sql
-- À exécuter après patch-cib-entreprise-avancee-9.sql. Additif et rejouable.
--
--  1. CORRECTIF : dans client_repondre_demande_conseiller, la variable
--     locale "d" et l'alias de table "d" (conseiller_demandes d) portaient
--     le même nom, ce qui rend TOUTE colonne "d.xxx" ambiguë pour
--     Postgres (il ne sait pas si c'est la variable ou l'alias). C'est
--     exactement l'erreur "column reference d.lien_id is ambiguous" en
--     cliquant Accepter. Alias renommé en "dd", variable inchangée.
--  2. RATTRAPAGE DES RELEVÉS MENSUELS DES CITOYENS : la fonction
--     citoyens_rattraper_releves() existait déjà, mais rien ne
--     l'appelait jamais côté client (seule entreprises_rattraper_rapports
--     était appelée) — et pg_cron n'est visiblement pas actif sur ce
--     projet. Donc aucun relevé n'a jamais été généré. Ce patch :
--       a) exécute IMMÉDIATEMENT le rattrapage pour tous les citoyens
--          existants (relevé de septembre, période 2026-09, généré ici
--          même si ce n'est pas encore le 2 du mois) ;
--       b) enlève la dépendance à pg_cron pour le mois courant : le
--          rattrapage se déclenche désormais à CHAQUE connexion d'un
--          citoyen (la fonction est déjà protégée par "on conflict" /
--          vérification d'existence, donc rejouable sans créer de
--          doublons) — il faut aussi ajouter l'appel côté client (fourni
--          plus bas, à coller dans portail-citoyen.html si ce n'est pas
--          déjà fait par la mise à jour fournie en même temps que ce patch).
-- ============================================================


-- ============================================================
-- 1) CORRECTIF DE L'AMBIGUÏTÉ (conseiller financier)
-- ============================================================
create or replace function client_repondre_demande_conseiller(p_demande_id uuid, p_decision text, p_motif_refus text default null)
returns void language plpgsql security definer set search_path = public as $$
declare d conseiller_demandes; v_client uuid;
begin
  select dd.* into d from conseiller_demandes dd join conseiller_liens l on l.id = dd.lien_id
    where dd.id = p_demande_id and l.client_id = auth.uid() and dd.statut = 'en_attente';
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


-- ============================================================
-- 1 bis) CORRECTIF : _citoyen_generer_releve utilisait mon_argent_attendu(),
-- qui lit auth.uid() — donc quand le rattrapage d'UN citoyen déclenche la
-- génération du relevé d'UN AUTRE (ce qui arrive : la connexion de
-- n'importe qui lance le rattrapage pour tout le monde), le relevé de
-- l'autre personne affichait l'argent attendu du citoyen connecté, pas le
-- sien. Remplacé par une lecture directe sur p_citoyen_id.
-- ============================================================
create or replace function _citoyen_generer_releve(p_citoyen_id uuid, p_periode text)
returns citoyens_releves language plpgsql security definer set search_path = public as $$
declare
  c citoyens; v_debut timestamptz; v_fin timestamptz; v_jours numeric;
  v_virements jsonb; v_paiements jsonb; v_entreprises jsonb; v_logs_ent jsonb;
  v_constats_payes jsonb; v_constats_attente jsonb; v_permis jsonb;
  v_confiance jsonb; v_emprunts_gouv jsonb; v_emprunts_civils jsonb; v_emprunts_attente jsonb;
  v_formations jsonb; v_recompenses jsonb; v_capitaux jsonb; v_capital_retraits numeric;
  v_argent_attendu jsonb; v_notes jsonb; v_depots_manuels jsonb; v_factures jsonb;
  v_salaire_ent numeric; v_taxe_rev_ent numeric; v_taxe_prev_ent numeric;
  v_salaire_net_est numeric; v_taxe_rev_est numeric; v_taxe_prev_est numeric;
  v_taxe_rev_cas_est numeric := 0; v_taxe_prev_cas_est numeric := 0;
  v_row citoyens_releves;
begin
  if p_periode !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception 'Période invalide.'; end if;
  v_debut := to_date(p_periode || '-01', 'YYYY-MM-DD')::timestamptz;
  v_fin := v_debut + interval '1 month';
  v_jours := extract(epoch from (least(v_fin, now()) - v_debut)) / 86400.0;
  select * into c from citoyens where id = p_citoyen_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'type', t.type, 'cree_le', t.cree_le, 'montant', t.montant_par_personne, 'total_debite', t.total_debite,
    'expediteur', _nom_partie(t.expediteur_id, t.entreprise_expediteur_id),
    'destinataires', (select coalesce(jsonb_agg(_nom_partie(d, null)), '[]'::jsonb) from unnest(t.destinataires) d),
    'entreprise_destinataire', (select nom from entreprises where id = t.entreprise_destinataire_id)
  ) order by t.cree_le), '[]'::jsonb) into v_virements
  from transferts t where (t.expediteur_id = p_citoyen_id or p_citoyen_id = any(t.destinataires)) and t.cree_le >= v_debut and t.cree_le < v_fin;

  select coalesce(jsonb_agg(jsonb_build_object('type', type, 'montant', montant, 'cree_le', cree_le) order by cree_le), '[]'::jsonb)
    into v_paiements from paiements_historique where citoyen_id = p_citoyen_id and cree_le >= v_debut and cree_le < v_fin;

  select coalesce(jsonb_agg(jsonb_build_object('entreprise', e.nom, 'role', m.role, 'salaire_horaire', m.salaire_horaire,
      'paye_ce_mois', coalesce((select sum((l.donnees->>'montant')::numeric) from entreprises_logs l
        where l.entreprise_id = e.id and l.type = 'paiement_employe' and (l.donnees->>'citoyen_id')::uuid = p_citoyen_id
        and l.cree_le >= v_debut and l.cree_le < v_fin), 0))), '[]'::jsonb),
    coalesce(sum((select sum((l.donnees->>'montant')::numeric) from entreprises_logs l
        where l.entreprise_id = e.id and l.type = 'paiement_employe' and (l.donnees->>'citoyen_id')::uuid = p_citoyen_id
        and l.cree_le >= v_debut and l.cree_le < v_fin)), 0)
    into v_entreprises, v_salaire_ent
  from entreprises_membres m join entreprises e on e.id = m.entreprise_id where m.citoyen_id = p_citoyen_id;

  select coalesce(sum((l.donnees->>'taxe_revenu')::numeric), 0), coalesce(sum((l.donnees->>'taxe_preventive')::numeric), 0)
    into v_taxe_rev_ent, v_taxe_prev_ent
    from entreprises_logs l join entreprises_membres m on m.entreprise_id = l.entreprise_id and m.citoyen_id = p_citoyen_id
    where l.type = 'paiement_employe' and (l.donnees->>'citoyen_id')::uuid = p_citoyen_id and l.cree_le >= v_debut and l.cree_le < v_fin;

  select coalesce(jsonb_agg(entreprise_logs_publics(id)), '[]'::jsonb) into v_logs_ent
    from (select distinct entreprise_id as id from entreprises_membres where citoyen_id = p_citoyen_id) x;

  select coalesce(jsonb_agg(jsonb_build_object('raison', raison, 'prix_total', prix_total, 'paye_le', paye_le)) filter (where paye), '[]'::jsonb),
         coalesce(jsonb_agg(jsonb_build_object('raison', raison, 'prix_total', prix_total, 'cree_le', cree_le)) filter (where not paye), '[]'::jsonb)
    into v_constats_payes, v_constats_attente
    from constats_infraction where destinataire_id = p_citoyen_id and cree_le >= v_debut and cree_le < v_fin;

  select coalesce(jsonb_agg(jsonb_build_object('type', type, 'prix_paye', prix_paye, 'expire_le', expire_le) order by achete_le), '[]'::jsonb)
    into v_permis from permis_citoyens where citoyen_id = p_citoyen_id and achete_le >= v_debut and achete_le < v_fin;

  v_confiance := citoyen_confiance(p_citoyen_id);

  select coalesce(jsonb_agg(jsonb_build_object('montant_demande', montant_demande, 'cree_le', cree_le,
      'montant_rembourse', case when statut = 'rembourse' then montant_du end, 'date_remboursement', rembourse_le,
      'taux', taux_valeur, 'type_taux', type_taux)), '[]'::jsonb) into v_emprunts_gouv
    from citoyens_emprunts_gouv where citoyen_id = p_citoyen_id and statut in ('acceptee','rembourse') and cree_le >= v_debut and cree_le < v_fin;

  select coalesce(jsonb_agg(jsonb_build_object('montant', montant_initial, 'cree_le', cree_le, 'taux', taux_interet,
      'date_limite', date_limite, 'rembourse_le', rembourse_le, 'role', case when preteur_id = p_citoyen_id then 'preteur' else 'emprunteur' end)), '[]'::jsonb)
    into v_emprunts_civils from emprunts where (preteur_id = p_citoyen_id or emprunteur_id = p_citoyen_id) and statut in ('actif','rembourse') and cree_le >= v_debut and cree_le < v_fin;

  select coalesce(jsonb_agg(jsonb_build_object('montant', coalesce(montant_demande, montant_initial), 'statut', statut, 'gouvernemental', (montant_demande is not null))), '[]'::jsonb)
    into v_emprunts_attente from (
      select montant_demande, null::numeric as montant_initial, statut from citoyens_emprunts_gouv where citoyen_id = p_citoyen_id and statut in ('en_attente','refusee')
      union all
      select null, montant_initial, statut from emprunts where emprunteur_id = p_citoyen_id and statut in ('en_attente')
    ) x;

  select coalesce(jsonb_agg(jsonb_build_object('nom', f.nom, 'niveau', f.niveau, 'cree_le', a.cree_le)), '[]'::jsonb) into v_formations
    from aft_attributions a join aft_formations f on f.id = a.formation_id where a.citoyen_id = p_citoyen_id and a.cree_le >= v_debut and a.cree_le < v_fin;

  select coalesce(jsonb_agg(jsonb_build_object('numero_suivi', numero_suivi_meritas, 'donne_le', donne_le)), '[]'::jsonb) into v_recompenses
    from recompenses_attributions where citoyen_id = p_citoyen_id and donne_le >= v_debut and donne_le < v_fin;

  select coalesce(jsonb_agg(jsonb_build_object('entreprise', e.nom, 'pourcentage', d.pourcentage, 'solde', d.solde)), '[]'::jsonb) into v_capitaux
    from entreprises_capital_detenteurs d join entreprises e on e.id = d.entreprise_id where d.citoyen_id = p_citoyen_id;
  select coalesce(sum(montant), 0) into v_capital_retraits from capital_retraits_historique where citoyen_id = p_citoyen_id and cree_le >= v_debut and cree_le < v_fin;

  -- Correctif : lecture directe sur p_citoyen_id (ne dépend plus de auth.uid()).
  select jsonb_build_object(
    'total', c.argent_attendu,
    'detail', coalesce((select jsonb_agg(jsonb_build_object('montant', ad.montant, 'description', ad.description, 'regle', ad.regle, 'cree_le', ad.cree_le) order by ad.cree_le desc)
      from argent_attendu_detail ad where ad.citoyen_id = p_citoyen_id), '[]'::jsonb)
  ) into v_argent_attendu;

  select coalesce(jsonb_agg(jsonb_build_object('note', note, 'cree_le', cree_le) order by cree_le desc), '[]'::jsonb) into v_notes
    from citoyens_notes_dossier where citoyen_id = p_citoyen_id;

  select coalesce(jsonb_agg(jsonb_build_object('entreprise', e.nom, 'periode', d.periode, 'cree_le', d.cree_le)), '[]'::jsonb) into v_depots_manuels
    from entreprises_depots_impots d join entreprises e on e.id = d.entreprise_id
    where d.depose_par = p_citoyen_id and d.type in ('manuel','assiste') and d.cree_le >= v_debut and d.cree_le < v_fin;

  select coalesce(jsonb_agg(row_to_json(f) order by f.cree_le) filter (where f.visible_publiquement), '[]'::jsonb)
    into v_factures from factures_manuelles f where f.citoyen_id = p_citoyen_id and f.periode = to_char(v_debut, 'YYYY-MM');
  select coalesce(sum(taxes_payees_gouv), 0), coalesce(sum(taxes_payees_tiers), 0)
    into v_taxe_rev_est, v_taxe_prev_est
    from factures_manuelles where citoyen_id = p_citoyen_id and periode = to_char(v_debut, 'YYYY-MM');

  declare v_brut_cas_est numeric; v_prev_taux numeric;
  begin
    select taux_preventif into v_prev_taux from parametres_fiscaux where id = 1;
    v_brut_cas_est := coalesce(c.salaire, 0) * 60 * 24 * v_jours;
    v_taxe_rev_cas_est := round(v_brut_cas_est * coalesce(c.taux_revenu, 0) / 100.0, 2);
    v_taxe_prev_cas_est := round(v_brut_cas_est * coalesce(v_prev_taux, 0) / 100.0, 2);
    v_salaire_net_est := round(v_brut_cas_est * (1 - coalesce(c.taux_revenu, 0) / 100.0 - coalesce(v_prev_taux, 0) / 100.0 - 0.02), 2);
  end;

  insert into citoyens_releves (citoyen_id, periode, contenu)
  values (p_citoyen_id, p_periode, jsonb_build_object(
    'genere_le', now(), 'periode', p_periode,
    'virements', v_virements, 'paiements', v_paiements,
    'entreprises', v_entreprises, 'salaire_entreprises_mois', v_salaire_ent,
    'logs_entreprises', v_logs_ent,
    'constats_payes', v_constats_payes, 'constats_en_attente', v_constats_attente,
    'permis_achetes', v_permis,
    'compte_chomage', c.compte_chomage, 'compte_retraite', c.compte_retraite, 'compte_parentalite', c.compte_parentalite,
    'tresorerie', c.tresorerie, 'dettes', c.dettes, 'prets', c.prets,
    'contribution_gouvernement_estimee', round(v_taxe_rev_ent + v_taxe_prev_ent + v_taxe_rev_cas_est + v_taxe_prev_cas_est, 2),
    'taxe_revenu_entreprises', v_taxe_rev_ent, 'taxe_preventive_entreprises', v_taxe_prev_ent,
    'taxe_revenu_cas_estimee', v_taxe_rev_cas_est, 'taxe_preventive_cas_estimee', v_taxe_prev_cas_est,
    'taxe_pourcentage', c.taux_revenu, 'salaire_net_cas_estime', v_salaire_net_est,
    'taxes_ajout_manuel_gouv', v_taxe_rev_est, 'taxes_ajout_manuel_tiers', v_taxe_prev_est,
    'demandes_epargne_mois', (select coalesce(jsonb_agg(jsonb_build_object('type', type, 'statut', statut, 'cree_le', cree_le)), '[]'::jsonb)
      from demandes_epargne where citoyen_id = p_citoyen_id and cree_le >= v_debut and cree_le < v_fin),
    'confiance', v_confiance,
    'emprunts_gouvernement', v_emprunts_gouv, 'emprunts_civils', v_emprunts_civils, 'emprunts_en_attente_ou_refuses', v_emprunts_attente,
    'formations_obtenues', v_formations, 'recompenses_obtenues', v_recompenses,
    'capitaux_possedes', v_capitaux, 'capital_retire_mois', v_capital_retraits,
    'argent_attendu', v_argent_attendu,
    'relevés_entreprises_manuels', v_depots_manuels,
    'notes_au_dossier', v_notes,
    'factures_manuelles_visibles', v_factures
  ))
  on conflict (citoyen_id, periode) do update set contenu = excluded.contenu
  returning * into v_row;
  return v_row;
end; $$;


-- ============================================================
-- 2) RATTRAPAGE IMMÉDIAT DES RELEVÉS MENSUELS DES CITOYENS
-- ============================================================
-- Exécuté une fois ici pour tout le monde (septembre, et tout mois passé
-- manquant s'il y en avait). Rejouable sans risque (ignore ce qui existe déjà).
do $$
declare v_mois_manquant text; v_periode_iter date;
begin
  -- Génère tous les mois manquants depuis la création du compte le plus ancien
  -- jusqu'au mois précédent inclus (généralement un seul mois : le précédent).
  for v_periode_iter in
    select generate_series(
      date_trunc('month', (select min(cree_le) from citoyens)),
      date_trunc('month', current_date) - interval '1 month',
      interval '1 month'
    )::date
  loop
    v_mois_manquant := to_char(v_periode_iter, 'YYYY-MM');
    perform _citoyen_generer_releve(c.id, v_mois_manquant)
      from citoyens c
      where c.cree_le < date_trunc('month', current_date)
        and c.cree_le <= (v_periode_iter + interval '1 month')
        and not exists (select 1 from citoyens_releves r where r.citoyen_id = c.id and r.periode = v_mois_manquant);
  end loop;
end $$;

-- Rattrapage à chaque connexion, sans dépendre de pg_cron : appelé par
-- enregistrer_mon_cib (déjà appelé à chaque connexion par le site), pour
-- garantir qu'un relevé est généré dès le 1er du mois même si pg_cron
-- n'est pas actif sur ce projet.
create or replace function enregistrer_mon_cib(p_cib_fichier text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_code text; v_actuel text; v_force text;
begin
  perform citoyens_rattraper_releves();
  perform entreprises_rattraper_rapports();

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
