-- ============================================================
-- patch-cib-entreprise-avancee-17.sql
-- À exécuter après patch-cib-entreprise-avancee-16.sql. Additif et rejouable.
--
-- Fonctions de LECTURE manquantes pour que le front-end du bureau de poste
-- (patch 16) soit utilisable : listes, détails, mes affiliations, mes votes.
-- Aucune logique métier n'est modifiée ici, seulement des SELECT.
-- ============================================================

-- Les bureaux de poste dont je suis membre, avec mon rôle/poste et les pourcentages actuels.
create or replace function mon_bureau_poste()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'entreprise_id', e.id, 'nom', e.nom, 'role', m.role, 'poste_bureau', m.poste_bureau,
    'localisation_actuelle', m.localisation_actuelle,
    'pourcentage_livreurs', e.pourcentage_livreurs, 'pourcentage_analystes', e.pourcentage_analystes
  ) order by e.nom), '[]'::jsonb)
  from entreprises_membres m join entreprises e on e.id = m.entreprise_id
  where m.citoyen_id = auth.uid() and e.secteur = 'bureau_poste';
$$;
grant execute on function mon_bureau_poste() to authenticated;

-- Liste publique des bureaux de poste (pour qu'un vendeur demande une affiliation).
create or replace function bureau_poste_liste_publique()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'nom', e.nom, 'note', note_moyenne_bureau_poste(e.id)) order by e.nom), '[]'::jsonb)
  from entreprises e where e.secteur = 'bureau_poste' and e.statut = 'acceptee';
$$;
grant execute on function bureau_poste_liste_publique() to authenticated;

-- Membres d'un bureau de poste (pour que le PDG assigne les postes).
create or replace function bureau_poste_membres(p_entreprise_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_role text;
begin
  select role into v_role from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_role is distinct from 'pdg' and not est_admin_actuel() then raise exception 'Réservé au PDG du bureau de poste.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'citoyen_id', m.citoyen_id, 'username', c.username, 'role', m.role, 'poste_bureau', m.poste_bureau,
    'localisation_actuelle', m.localisation_actuelle
  ) order by c.username) from entreprises_membres m join citoyens c on c.id = m.citoyen_id where m.entreprise_id = p_entreprise_id), '[]'::jsonb);
end; $$;
grant execute on function bureau_poste_membres(uuid) to authenticated;

-- Mes affiliations (en tant que vendeur/entreprise demandeuse) + leur statut/code.
create or replace function bureau_poste_mes_affiliations()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', a.id, 'bureau_poste', e.nom, 'bureau_poste_id', a.bureau_poste_id, 'cible_type', a.cible_type,
    'statut', a.statut, 'unite', a.unite, 'prix_par_unite', a.prix_par_unite, 'duree_jours', a.duree_jours,
    'code', a.code, 'code_expire_le', a.code_expire_le, 'cree_le', a.cree_le
  ) order by a.cree_le desc), '[]'::jsonb)
  from bureau_poste_affiliations a join entreprises e on e.id = a.bureau_poste_id
  where a.demandeur_id = auth.uid()
    or (a.entreprise_cible_id is not null and exists (select 1 from entreprises_membres m where m.entreprise_id = a.entreprise_cible_id and m.citoyen_id = auth.uid() and m.role in ('pdg','co_pdg')));
$$;
grant execute on function bureau_poste_mes_affiliations() to authenticated;

-- Demandes d'affiliation en attente pour un bureau de poste (PDG/manager).
create or replace function bureau_poste_demandes_affiliation(p_entreprise_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_role text; v_poste text;
begin
  select role, poste_bureau into v_role, v_poste from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_role is distinct from 'pdg' and v_poste is distinct from 'manager' and not est_admin_actuel() then raise exception 'Réservé au PDG ou à un manager.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', a.id, 'cible_type', a.cible_type, 'demandeur', c.username, 'justification', a.justification,
    'duree_jours', a.duree_jours, 'unite', a.unite, 'prix_par_unite', a.prix_par_unite,
    'entreprise_cible', ec.nom, 'annonce_titre', an.titre, 'cree_le', a.cree_le
  ) order by a.cree_le) from bureau_poste_affiliations a
    join citoyens c on c.id = a.demandeur_id
    left join entreprises ec on ec.id = a.entreprise_cible_id
    left join marche_annonces an on an.id = a.annonce_id
    where a.bureau_poste_id = p_entreprise_id and a.statut = 'en_attente'), '[]'::jsonb);
end; $$;
grant execute on function bureau_poste_demandes_affiliation(uuid) to authenticated;

-- Demandes de modification de conditions en attente, visibles par les deux parties.
create or replace function bureau_poste_demandes_modif(p_affiliation_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', mc.id, 'demandeur_id', mc.demandeur_id, 'nouvelle_unite', mc.nouvelle_unite, 'nouveau_prix', mc.nouveau_prix, 'cree_le', mc.cree_le
  ) order by mc.cree_le desc), '[]'::jsonb)
  from bureau_poste_modif_conditions mc where mc.affiliation_id = p_affiliation_id and mc.statut = 'en_attente';
$$;
grant execute on function bureau_poste_demandes_modif(uuid) to authenticated;

-- Livraisons liées à un bureau de poste : à assigner, en cours, ou à analyser.
create or replace function bureau_poste_livraisons(p_entreprise_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_role text; v_poste text;
begin
  select role, poste_bureau into v_role, v_poste from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_role is distinct from 'pdg' and v_poste is null and not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', m.id, 'titre', m.titre, 'statut_livraison', m.statut_livraison, 'etape_bureau_poste', m.etape_bureau_poste,
    'livreur', lc.username, 'livreur_id', m.livreur_id, 'analyste', ac.username,
    'distance_parcourue', m.distance_parcourue, 'prix_livraison_facture', m.prix_livraison_facture,
    'livraison_facturee', m.livraison_facturee, 'livraison_delai_analyse', m.livraison_delai_analyse
  ) order by m.id) from marche_achats m
    left join citoyens lc on lc.id = m.livreur_id
    left join citoyens ac on ac.id = m.analyste_id
    where m.bureau_poste_id = p_entreprise_id), '[]'::jsonb);
end; $$;
grant execute on function bureau_poste_livraisons(uuid) to authenticated;

-- Votes actifs d'un bureau de poste + mon vote actuel (si livreur/analyste concerné).
-- Ajoute le livreur assigné et ma note du livreur (manquants côté lecture) pour que
-- le front-end puisse proposer/afficher l'évaluation séparée du livreur.
create or replace function mes_achats_marche()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id, 'titre', m.titre, 'quantite', m.quantite, 'montant_total', m.montant_total, 'mode_paiement', m.mode_paiement,
    'statut_livraison', m.statut_livraison, 'vendeur', c.username, 'cree_le', m.cree_le,
    'livreur', lc.username, 'note_livreur_rapidite', m.note_livreur_rapidite, 'note_livreur_etat', m.note_livreur_etat,
    'facture_albatros', (select jsonb_build_object('mois_total', mois_total, 'montant_mensuel', montant_mensuel, 'mois_payes', mois_payes, 'prochain_du', prochain_du, 'statut', statut, 'id', id)
      from albatros_factures where achat_id = m.id)
  ) order by m.cree_le desc), '[]'::jsonb)
  from marche_achats m join citoyens c on c.id = m.vendeur_id left join citoyens lc on lc.id = m.livreur_id where m.acheteur_id = auth.uid();
$$;
grant execute on function mes_achats_marche() to authenticated;

-- Ajoute le drapeau "publique" (manquant côté lecture) pour permettre au front-end
-- d'afficher le bouton "Quitter" uniquement sur les comptes de banques publiques.
create or replace function mes_comptes_bancaires()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'banque_id', b.id, 'nom', b.nom, 'type', b.type, 'publique', b.publique,
    'solde', case when b.type = 'fructification' then _valeur_compte_banque(bc.id) else bc.solde end
  ) order by b.nom), '[]'::jsonb)
  from banques_comptes bc join banques_privees b on b.id = bc.banque_id where bc.citoyen_id = auth.uid();
$$;
grant execute on function mes_comptes_bancaires() to authenticated;

create or replace function bureau_poste_votes_actifs(p_entreprise_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', v.id, 'poste', v.poste, 'nouveau_pourcentage', v.nouveau_pourcentage, 'statut', v.statut, 'expire_le', v.expire_le,
    'mon_choix', (select r.choix from bureau_poste_votes_reponses r where r.vote_id = v.id and r.citoyen_id = auth.uid()),
    'nb_oui', (select count(*) from bureau_poste_votes_reponses r where r.vote_id = v.id and r.choix),
    'nb_non', (select count(*) from bureau_poste_votes_reponses r where r.vote_id = v.id and not r.choix)
  ) order by v.cree_le desc), '[]'::jsonb)
  from bureau_poste_votes v where v.bureau_poste_id = p_entreprise_id and v.statut = 'en_cours';
$$;
grant execute on function bureau_poste_votes_actifs(uuid) to authenticated;
