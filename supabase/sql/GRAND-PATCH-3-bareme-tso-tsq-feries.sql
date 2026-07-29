-- ============================================================
-- GRAND-PATCH — partie 3 : nouveau barème TR, TSO, TS-Q, jours fériés
-- À exécuter APRÈS les parties 1 et 2
-- ============================================================

-- ------------------------------------------------------------
-- 1) NOUVEAU BARÈME DE LA TAXE SUR LES REVENUS
-- ------------------------------------------------------------
-- tranche = ROND(annuel / 4500)  [arrondi, pas plancher]
-- taux = 1,25 + (tranche × 0,75), plafonné à 41,75%
-- Vérifié par le plafond exact : 243 000 / 4500 = 54 -> 1,25+54×0,75 = 41,75% ✓
-- NOTE : ton exemple manuscrit (73710 -> 13,75%) donne en fait 13,25%
-- avec cette formule (16 × 0,75 = 12, + 1,25 = 13,25) — j'ai gardé la
-- règle telle que décrite plutôt que ton résultat, les deux ne
-- concordaient pas entre eux. Dis-moi si tu voulais autre chose.
create or replace function calculer_taux_revenu(p_salaire numeric)
returns numeric language sql immutable as $$
  select least(41.75, 1.25 + round((p_salaire * 39 * 30) / 4500) * 0.75);
$$;

update citoyens set taux_revenu = calculer_taux_revenu(salaire);

-- ------------------------------------------------------------
-- 2) JOURS FÉRIÉS — colonnes TSO / TS-Q
-- ------------------------------------------------------------
alter table citoyens add column if not exists tso_dernier_declenche timestamptz;
alter table citoyens add column if not exists tso_secondes_restantes numeric not null default 0;
alter table citoyens add column if not exists tsq_dernier_declenche timestamptz;
alter table citoyens add column if not exists tsq_secondes_restantes numeric not null default 0;
alter table citoyens add column if not exists tsq_actif boolean not null default false;

create or replace function est_jour_ferie(p_date date default current_date)
returns boolean language sql immutable as $$
  select (extract(month from p_date), extract(day from p_date)) in (
    (10, 17), -- Fête Étaloise
    (12, 25), -- Noël
    (1, 1),   -- Nouvel An
    (6, 24)   -- Saint-Jean-Baptiste
  );
$$;

-- ------------------------------------------------------------
-- 3) REVENU NORMAL — nouveaux taux chômage (2,75%) et retraite
--    (6,75%), aucun versement les jours fériés
-- ------------------------------------------------------------
drop function if exists deposer_revenu_citoyen(numeric);
create or replace function deposer_revenu_citoyen(p_minutes numeric default 1.0/60)
returns citoyens language plpgsql security definer set search_path = public as $$
declare
  v_citoyen citoyens;
  v_taux_preventif numeric;
  v_brut numeric; v_tr numeric; v_te numeric;
  v_chomage numeric; v_retraite numeric; v_parentalite numeric; v_net numeric;
  v_periode_60 int;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;

  select * into v_citoyen from citoyens where id = auth.uid();
  if v_citoyen is null then raise exception 'Citoyen introuvable.'; end if;

  -- Jour férié : personne n'est payé sur le revenu normal
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
  v_tr := v_brut * (v_citoyen.taux_revenu / 100.0);
  v_te := v_brut * (v_taux_preventif / 100.0);
  v_chomage := v_brut * 0.0275;
  v_retraite := v_brut * 0.0675;
  v_parentalite := v_brut * 0.0025;
  v_net := v_brut - v_tr - v_te - v_chomage - v_retraite - v_parentalite;

  update citoyens
    set tresorerie = tresorerie + v_net,
        compte_chomage = compte_chomage + v_chomage,
        compte_retraite = compte_retraite + v_retraite,
        compte_parentalite = compte_parentalite + v_parentalite,
        taxes_gouv_60j = taxes_gouv_60j + v_tr,
        taxe_preventive_60j = taxe_preventive_60j + v_te,
        derniere_synchro_tresorerie = now()
    where id = auth.uid()
    returning * into v_citoyen;

  update tresor_public set solde = solde + v_tr + v_te where id = 1;
  return v_citoyen;
end;
$$;
grant execute on function deposer_revenu_citoyen(numeric) to authenticated;

-- ============================================================
-- 4) TEMPS SUPPLÉMENTAIRE OPTIONNEL (TSO)
-- ============================================================
-- Déclenchement : 8 minutes à 125% du salaire, sans AUCUNE taxe.
-- Cooldown de 7 jours depuis le dernier déclenchement. Autorisé même
-- les jours fériés (contrairement au revenu normal).
create or replace function declencher_tso()
returns citoyens language plpgsql security definer set search_path = public as $$
declare v_citoyen citoyens;
begin
  select * into v_citoyen from citoyens where id = auth.uid();
  if v_citoyen is null then raise exception 'Non authentifié.'; end if;
  if v_citoyen.tso_secondes_restantes > 0 then
    raise exception 'Un TSO est déjà en cours.';
  end if;
  if v_citoyen.tso_dernier_declenche is not null and v_citoyen.tso_dernier_declenche > now() - interval '7 days' then
    raise exception 'TSO déjà utilisé il y a moins de 7 jours (prochain disponible le %).',
      to_char(v_citoyen.tso_dernier_declenche + interval '7 days', 'DD/MM/YYYY HH24:MI');
  end if;

  update citoyens
    set tso_secondes_restantes = 480, tso_dernier_declenche = now()
    where id = auth.uid()
    returning * into v_citoyen;
  return v_citoyen;
end;
$$;
grant execute on function declencher_tso() to authenticated;

-- Avance le TSO d'un "tick" (appelé chaque seconde par le client tant
-- qu'il reste du temps de TSO) : payé à 125%, aucune taxe, peut être
-- mis en pause simplement en cessant d'appeler cette fonction (le
-- reste se conserve, pas de décompte pendant la déconnexion).
create or replace function avancer_tso(p_secondes numeric default 1)
returns citoyens language plpgsql security definer set search_path = public as $$
declare v_citoyen citoyens; v_secondes numeric; v_montant numeric;
begin
  select * into v_citoyen from citoyens where id = auth.uid();
  if v_citoyen is null then raise exception 'Non authentifié.'; end if;
  if v_citoyen.tso_secondes_restantes <= 0 then
    raise exception 'Aucun TSO actif.';
  end if;

  v_secondes := least(p_secondes, v_citoyen.tso_secondes_restantes);
  v_montant := (v_citoyen.salaire / 60.0) * 1.25 * v_secondes;

  update citoyens
    set tresorerie = tresorerie + v_montant,
        tso_secondes_restantes = tso_secondes_restantes - v_secondes
    where id = auth.uid()
    returning * into v_citoyen;
  return v_citoyen;
end;
$$;
grant execute on function avancer_tso(numeric) to authenticated;

-- ============================================================
-- 5) TEMPS SUPPLÉMENTAIRE OBLIGATOIRE (TS-Q)
-- ============================================================
-- Déclenché aléatoirement par le serveur (vérifié à intervalle
-- régulier par le client), garanti au moins 1 fois par 35 jours.
create or replace function verifier_declenchement_tsq()
returns citoyens language plpgsql security definer set search_path = public as $$
declare v_citoyen citoyens; v_jours numeric; v_ref timestamptz;
begin
  select * into v_citoyen from citoyens where id = auth.uid();
  if v_citoyen is null then raise exception 'Non authentifié.'; end if;
  if v_citoyen.tsq_actif then return v_citoyen; end if;

  v_ref := coalesce(v_citoyen.tsq_dernier_declenche, v_citoyen.cree_le);
  v_jours := extract(epoch from (now() - v_ref)) / 86400.0;

  -- Déclenchement garanti après 35 jours, ou aléatoire (chance
  -- modeste à chaque vérification, environ chaque minute côté client)
  if v_jours >= 35 or random() < 0.00002 then
    update citoyens
      set tsq_actif = true, tsq_secondes_restantes = 180, tsq_dernier_declenche = now()
      where id = auth.uid()
      returning * into v_citoyen;
  end if;

  return v_citoyen;
end;
$$;
grant execute on function verifier_declenchement_tsq() to authenticated;

-- Avance le TS-Q d'un tick (chaque seconde pendant que le citoyen
-- reste connecté). Aucun paiement avant la fin des 3 minutes.
create or replace function avancer_tsq(p_secondes numeric default 1)
returns citoyens language plpgsql security definer set search_path = public as $$
declare v_citoyen citoyens; v_secondes numeric; v_montant numeric;
begin
  select * into v_citoyen from citoyens where id = auth.uid();
  if v_citoyen is null or not v_citoyen.tsq_actif then raise exception 'Aucun TS-Q actif.'; end if;

  v_secondes := least(p_secondes, v_citoyen.tsq_secondes_restantes);

  if v_citoyen.tsq_secondes_restantes - v_secondes <= 0 then
    v_montant := (v_citoyen.salaire * 3) * 1.5;
    update citoyens
      set tresorerie = tresorerie + v_montant, tsq_secondes_restantes = 0, tsq_actif = false
      where id = auth.uid()
      returning * into v_citoyen;
  else
    update citoyens
      set tsq_secondes_restantes = tsq_secondes_restantes - v_secondes
      where id = auth.uid()
      returning * into v_citoyen;
  end if;

  return v_citoyen;
end;
$$;
grant execute on function avancer_tsq(numeric) to authenticated;

-- ------------------------------------------------------------
-- 6) GRANTS DE SÉCURITÉ (au cas où les privilèges par défaut
--    n'incluraient pas déjà l'exécution publique)
-- ------------------------------------------------------------
grant execute on function dans_fenetre_redevance() to anon, authenticated;
grant execute on function periode_60j_actuelle() to anon, authenticated;
grant execute on function periode_30j_virements() to anon, authenticated;
grant execute on function est_jour_ferie(date) to anon, authenticated;
grant execute on function calculer_taux_revenu(numeric) to anon, authenticated;
grant execute on function calculer_taux_virement_considerable(numeric) to anon, authenticated;
