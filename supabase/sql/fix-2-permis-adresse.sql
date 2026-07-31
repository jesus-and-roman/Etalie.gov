-- ============================================================
-- Correctif — Adresse de livraison sur les permis
-- ============================================================
alter table permis_citoyens add column if not exists adresse_livraison text;

create or replace function acheter_permis(p_type text, p_adresse_livraison text)
returns permis_citoyens language plpgsql security definer set search_path = public as $$
declare
  v_base numeric; v_total numeric; v_citoyen citoyens; v_expire date; v_row permis_citoyens;
begin
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
    update tresor_public set solde = solde + v_total where id = 1;
  end if;

  insert into permis_citoyens (citoyen_id, type, prix_paye, expire_le, adresse_livraison)
  values (auth.uid(), p_type, v_total, v_expire, p_adresse_livraison)
  returning * into v_row;

  return v_row;
end;
$$;
grant execute on function acheter_permis(text, text) to authenticated;
