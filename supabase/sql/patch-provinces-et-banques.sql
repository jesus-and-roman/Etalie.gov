-- ============================================================
-- patch-provinces-et-banques.sql
-- À exécuter après patch-gouvernement-tresoreries.sql. Idempotent.
--
-- CONTENU :
--  1. Fusion de provinces (nouvelles unions) dans banque_provinces
--     (répartition de livraison) et province_residence_banque
--     (banque payeuse du salaire), avec migration des citoyens déjà
--     inscrits vers les nouveaux noms.
--  2. CORRECTION IMPORTANTE : "trésorerie provinciale" retiré partout,
--     remplacé par la trésorerie des BANQUES NATIONALES (comme demandé) :
--       - renflouement automatique à 50 000 R$ dès qu'une banque
--         nationale atteint 0 (au lieu d'une "trésorerie provinciale"
--         qui n'aurait jamais dû exister) ;
--       - gouv_payer_civil() pige maintenant dans la trésorerie de la
--         banque nationale de la province de résidence, pas dans une
--         table provinciale séparée ;
--       - transferts manuels gouvernement <-> banque nationale.
--     La table tresoreries_provinciales et ses fonctions associées
--     sont retirées.
--
-- HYPOTHÈSES faites faute de précision (à corriger vous-même par SQL
-- si ce n'est pas ce que vous vouliez) :
--  - "Grande-Capitale se séparera de la ville de Lataylon qui rejoindra
--    Marcio" : j'ai comrpis que dans le territoire de livraison de la
--    Banque Lataylon (L), Grande-Capitale fusionne avec Marcio (Marcio
--    hérite de sa population). Grande-Capitale reste inchangée du côté
--    de la Banque de la Capitale (C).
--  - L'Union d'Alanbie-Brien-Jance mélange des provinces de deux
--    banques différentes (Alanbie/Jance = Newhouse H, Brien = Lataylon
--    L). Je l'ai rattachée à la banque H (majoritaire, 2 provinces sur
--    3), donc Brien quitte le territoire de livraison de L.
--  - "Korsk-Cadic (Agort)", qui rejoint Gibaltage, n'a aucune donnée de
--    population dans ce qui m'a été fourni : population = 0 pour cette
--    partie de l'union. Ajustez au besoin.
-- ============================================================


-- ============================================================
-- 1) FUSION DES PROVINCES — banque_provinces (répartition de livraison)
-- ============================================================

-- ============================================================
-- patch-provinces-et-banques.sql
-- À exécuter après patch-gouvernement-tresoreries.sql. Idempotent.
--
-- CONTENU :
--  1. Fusion de provinces (nouvelles unions) dans banque_provinces
--     (répartition de livraison) et province_residence_banque
--     (banque payeuse du salaire), avec migration des citoyens déjà
--     inscrits vers les nouveaux noms.
--  2. CORRECTION IMPORTANTE : "trésorerie provinciale" retiré partout,
--     remplacé par la trésorerie des BANQUES NATIONALES :
--       - renflouement automatique à 50 000 R$ dès qu'une banque
--         nationale atteint 0 ;
--       - gouv_payer_civil() pige maintenant dans la trésorerie de la
--         banque nationale de la province de résidence ;
--       - transferts manuels gouvernement <-> banque nationale.
--     La table tresoreries_provinciales et ses fonctions associées
--     sont retirées.
--
-- HYPOTHÈSES :
--  - Grande-Capitale fusionne avec Marcio dans le territoire de
--    livraison de la Banque Lataylon (L).
--  - Grande-Capitale reste inchangée du côté de la Banque de la
--    Capitale (C).
--  - L'Union d'Alanbie-Brien-Jance est rattachée à la banque H
--    (Newhouse), car Alanbie/Jance sont déjà chez H.
--  - Korsk-Cadic (Agort) rejoint Gibaltage sans population fournie :
--    population = 0 pour cette partie.
-- ============================================================


-- ============================================================
-- 1) FUSION DES PROVINCES — banque_provinces
--    (répartition de livraison)
-- ============================================================

-- ---- H (Newhouse) ----
delete from banque_provinces
where banque_tag = 'H'
  and province in (
    'Alanbie',
    'Jance',
    'Vénéz',
    'Alonse',
    'Hors-Grande-Vénésie',
    'Côte d''Avoigne',
    'Côte-Anglaise'
  );

insert into banque_provinces (
  banque_tag,
  province,
  population,
  part_pourcentage
)
values
  ('H', 'Union d''Alanbie-Brien-Jance', 1090000, 0),
  ('H', 'Union Vénézienne', 671000, 0),
  ('H', 'Union de la Côte-Anglaise', 954000, 0)
on conflict (banque_tag, province)
do update set
  population = excluded.population;


-- ---- L (Lataylon) ----
-- Brien quitte L et rejoint l'union H.
delete from banque_provinces
where banque_tag = 'L'
  and province = 'Brien';


-- Grande-Capitale fusionne avec Marcio.
do $$
declare
  v_pop_gc numeric;
begin
  select population
    into v_pop_gc
  from banque_provinces
  where banque_tag = 'L'
    and province = 'Grande-Capitale';

  if v_pop_gc is not null then
    update banque_provinces
    set population = population + v_pop_gc
    where banque_tag = 'L'
      and province = 'Marcio';

    delete from banque_provinces
    where banque_tag = 'L'
      and province = 'Grande-Capitale';
  end if;
end $$;


-- ---- M (Maréchal) ----
-- Isulae + Balques -> Union des Balques
delete from banque_provinces
where banque_tag = 'M'
  and province in ('Isulae', 'Balques');

insert into banque_provinces (
  banque_tag,
  province,
  population,
  part_pourcentage
)
values
  ('M', 'Union des Balques', 1230000, 0)
on conflict (banque_tag, province)
do update set
  population = excluded.population;


-- Pruxe-Slamique -> Pruxe
update banque_provinces
set province = 'Pruxe'
where banque_tag = 'M'
  and province = 'Pruxe-Slamique';


-- ---- P (Fleury) ----
-- Milela-Cale + North Milela -> Union de Milela
delete from banque_provinces
where banque_tag = 'P'
  and province in (
    'Milela-Cale',
    'North Milela',
    'Grâdes',
    'Tivainne'
  );

insert into banque_provinces (
  banque_tag,
  province,
  population,
  part_pourcentage
)
values
  ('P', 'Union de Milela', 1194951, 0),
  ('P', 'Union de Grâdes-Tivainne', 987000, 0)
on conflict (banque_tag, province)
do update set
  population = excluded.population;


-- Gibaltage -> Union de Gibaltage
update banque_provinces
set
  province = 'Union de Gibaltage',
  population = population + 0
where banque_tag = 'P'
  and province = 'Gibaltage';


-- Recalcule les pourcentages de toutes les provinces
-- des banques touchées (H, L, M, P).
update banque_provinces bp
set part_pourcentage = round(
  bp.population::numeric
  /
  nullif(
    (
      select sum(population)
      from banque_provinces bp2
      where bp2.banque_tag = bp.banque_tag
    ),
    0
  )
  * 100,
  2
)
where bp.banque_tag in ('H', 'L', 'M', 'P');


-- ============================================================
-- 2) SUPPRESSION DE L'ANCIEN SYSTÈME DE TRÉSORERIES PROVINCIALES
--
-- IMPORTANT :
-- Cette section doit être exécutée AVANT la modification de
-- province_residence_banque, car tresoreries_provinciales possède
-- une clé étrangère vers province_residence_banque.
-- ============================================================

drop trigger if exists trg_renflouer_provinciale
on tresoreries_provinciales;

drop function if exists gouv_transferer_vers_provinciale(
  text,
  numeric,
  text
);

drop function if exists gouv_transferer_depuis_provinciale(
  text,
  numeric,
  text
);

drop function if exists gouv_liste_tresoreries_provinciales();

drop table if exists tresoreries_provinciales;


-- ============================================================
-- 3) FUSION DES PROVINCES — province_residence_banque
--    (banque payeuse)
-- ============================================================

delete from province_residence_banque
where province in (
  'Alanbie',
  'Jance',
  'Brien',
  'North Milela',
  'Milela-Cale',
  'Vénéz',
  'Alonse',
  'Hors-Grande-Vénésie',
  'Côte d''Avoigne',
  'Côte-Anglaise',
  'Isulae',
  'Balques',
  'Grâdes',
  'Tivainne',
  'Pruxe-Slamique',
  'Gibaltage'
);


insert into province_residence_banque (
  province,
  banque_tag
)
values
  ('Union d''Alanbie-Brien-Jance', 'H'),
  ('Union de Milela', 'P'),
  ('Union Vénézienne', 'H'),
  ('Union de la Côte-Anglaise', 'H'),
  ('Union des Balques', 'M'),
  ('Union de Grâdes-Tivainne', 'P'),
  ('Pruxe', 'M'),
  ('Union de Gibaltage', 'P')
on conflict (province)
do nothing;


-- ============================================================
-- 4) MIGRATION DES CITOYENS
-- ============================================================

update citoyens
set province_residence = 'Union d''Alanbie-Brien-Jance'
where province_residence in (
  'Alanbie',
  'Brien',
  'Jance'
);


update citoyens
set province_residence = 'Union de Milela'
where province_residence in (
  'North Milela',
  'Milela-Cale'
);


update citoyens
set province_residence = 'Union Vénézienne'
where province_residence in (
  'Vénéz',
  'Alonse'
);


update citoyens
set province_residence = 'Union de la Côte-Anglaise'
where province_residence in (
  'Hors-Grande-Vénésie',
  'Côte d''Avoigne',
  'Côte-Anglaise'
);


update citoyens
set province_residence = 'Union des Balques'
where province_residence in (
  'Isulae',
  'Balques'
);


update citoyens
set province_residence = 'Union de Grâdes-Tivainne'
where province_residence in (
  'Grâdes',
  'Tivainne'
);


update citoyens
set province_residence = 'Pruxe'
where province_residence = 'Pruxe-Slamique';


update citoyens
set province_residence = 'Union de Gibaltage'
where province_residence = 'Gibaltage';


-- ============================================================
-- 5) NOUVEAU SYSTÈME : TRÉSORERIE DES BANQUES NATIONALES
-- ============================================================

-- Renfloue automatiquement une banque nationale à 50 000 R$
-- dès que sa trésorerie atteint 0 ou moins.
--
-- Le gouvernement peut donc être mis en dette si nécessaire.
create or replace function _renflouer_banque_nationale()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin

  if new.tresorerie <= 0 then

    perform gouv_puiser_interne(
      50000,
      'publique'
    );

    new.tresorerie := new.tresorerie + 50000;

  end if;

  return new;

end;
$$;


drop trigger if exists trg_renflouer_banque
on banques_nationales;


create trigger trg_renflouer_banque
before insert or update
on banques_nationales
for each row
execute function _renflouer_banque_nationale();


-- ============================================================
-- 6) TRANSFERT GOUVERNEMENT -> BANQUE NATIONALE
-- ============================================================

create or replace function gouv_transferer_vers_banque(
  p_banque_tag char(1),
  p_montant numeric,
  p_treasorerie_preferee text default 'publique'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin

  if not est_admin_actuel() then
    raise exception
      'Accès refusé : réservé au gouvernement.';
  end if;

  if p_montant <= 0 then
    raise exception
      'Montant invalide.';
  end if;

  perform gouv_puiser_interne(
    p_montant,
    p_treasorerie_preferee
  );

  update banques_nationales
  set tresorerie = tresorerie + p_montant
  where tag = p_banque_tag;

end;
$$;


grant execute on function gouv_transferer_vers_banque(
  char,
  numeric,
  text
) to authenticated;


-- ============================================================
-- 7) TRANSFERT BANQUE NATIONALE -> GOUVERNEMENT
-- ============================================================

create or replace function gouv_transferer_depuis_banque(
  p_banque_tag char(1),
  p_montant numeric,
  p_tresorerie_cible text default 'publique'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_solde numeric;
begin

  if not est_admin_actuel() then
    raise exception
      'Accès refusé : réservé au gouvernement.';
  end if;

  select tresorerie
    into v_solde
  from banques_nationales
  where tag = p_banque_tag
  for update;

  if v_solde is null then
    raise exception
      'Banque invalide.';
  end if;

  if v_solde < p_montant then
    raise exception
      'Trésorerie de la banque insuffisante.';
  end if;

  update banques_nationales
  set tresorerie = tresorerie - p_montant
  where tag = p_banque_tag;

  if p_tresorerie_cible = 'privee' then

    update tresor_public
    set solde_prive = solde_prive + p_montant
    where id = 1;

  else

    update tresor_public
    set solde = solde + p_montant
    where id = 1;

  end if;

end;
$$;


grant execute on function gouv_transferer_depuis_banque(
  char,
  numeric,
  text
) to authenticated;


-- ============================================================
-- 8) PAIEMENT D'UN CIVIL
--    Banque nationale de la province en premier,
--    puis trésorerie gouvernementale.
-- ============================================================

create or replace function gouv_payer_civil(
  p_citoyen_id uuid,
  p_montant numeric,
  p_treasorerie_preferee text default 'publique',
  p_province text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare

  v_banque_tag char(1);
  v_solde_banque numeric;
  v_obtenu_banque numeric := 0;

  v_solde numeric;
  v_solde_prive numeric;

  v_home numeric;
  v_other numeric;

  v_pris_home numeric;
  v_pris_other numeric;

  v_obtenu_nat numeric := 0;

  v_reste numeric;
  v_total_obtenu numeric;
  v_manque numeric;

begin

  if p_montant is null or p_montant <= 0 then

    return jsonb_build_object(
      'obtenu',
      0,
      'manque',
      0
    );

  end if;


  v_reste := p_montant;


  -- ----------------------------------------------------------
  -- 1. Banque nationale correspondant à la province
  -- ----------------------------------------------------------

  if p_province is not null then

    select banque_tag
      into v_banque_tag
    from province_residence_banque
    where province = p_province;


    if v_banque_tag is not null then

      select tresorerie
        into v_solde_banque
      from banques_nationales
      where tag = v_banque_tag
      for update;


      if v_solde_banque is not null
         and v_solde_banque > 0 then

        v_obtenu_banque :=
          least(
            v_reste,
            v_solde_banque
          );


        update banques_nationales
        set tresorerie =
          tresorerie - v_obtenu_banque
        where tag = v_banque_tag;


        v_reste :=
          v_reste - v_obtenu_banque;

      end if;

    end if;

  end if;


  -- ----------------------------------------------------------
  -- 2. Trésorerie gouvernementale
  -- ----------------------------------------------------------

  if v_reste > 0 then

    select
      solde,
      solde_prive
    into
      v_solde,
      v_solde_prive
    from tresor_public
    where id = 1
    for update;


    if p_treasorerie_preferee = 'privee' then

      v_home := v_solde_prive;
      v_other := v_solde;

    else

      v_home := v_solde;
      v_other := v_solde_prive;

    end if;


    v_pris_home :=
      least(
        v_reste,
        greatest(0, v_home)
      );


    v_pris_other :=
      least(
        v_reste - v_pris_home,
        greatest(0, v_other)
      );


    v_obtenu_nat :=
      v_pris_home + v_pris_other;


    if p_treasorerie_preferee = 'privee' then

      update tresor_public
      set
        solde_prive =
          solde_prive - v_pris_home,
        solde =
          solde - v_pris_other
      where id = 1;

    else

      update tresor_public
      set
        solde =
          solde - v_pris_home,
        solde_prive =
          solde_prive - v_pris_other
      where id = 1;

    end if;


    v_reste :=
      v_reste - v_obtenu_nat;

  end if;


  -- ----------------------------------------------------------
  -- 3. Résultat
  -- ----------------------------------------------------------

  v_total_obtenu :=
    p_montant - v_reste;

  v_manque :=
    v_reste;


  -- Argent effectivement payé
  if v_total_obtenu > 0 then

    update citoyens
    set tresorerie =
      tresorerie + v_total_obtenu
    where id = p_citoyen_id;

  end if;


  -- Argent restant dû
  if v_manque > 0 then

    update citoyens
    set argent_attendu =
      argent_attendu + v_manque
    where id = p_citoyen_id;


    insert into argent_attendu_log (
      citoyen_id,
      montant_initial,
      montant_restant
    )
    values (
      p_citoyen_id,
      v_manque,
      v_manque
    );

  end if;


  return jsonb_build_object(
    'obtenu',
    v_total_obtenu,
    'manque',
    v_manque
  );

end;
$$;


revoke all on function gouv_payer_civil(
  uuid,
  numeric,
  text,
  text
) from public;


-- ============================================================
-- 9) LISTE DES TRÉSORERIES DES BANQUES NATIONALES
-- ============================================================

create or replace function gouv_liste_tresoreries_banques()
returns table(
  tag char(1),
  nom text,
  tresorerie numeric
)
language sql
stable
security definer
set search_path = public
as $$

  select
    tag,
    nom,
    tresorerie
  from banques_nationales
  order by tag;

$$;


grant execute on function gouv_liste_tresoreries_banques()
to authenticated;


-- ============================================================
-- FIN
-- ============================================================

-- ============================================================
-- FIN
-- ============================================================
