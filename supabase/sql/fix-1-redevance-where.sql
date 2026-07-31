-- ============================================================
-- Correctif — "UPDATE requires a WHERE clause"
-- admin_traiter_redevance faisait des UPDATE sans WHERE
-- ============================================================
create or replace function admin_traiter_redevance(
  p_nip text, p_decision text,
  p_congres_oui int default null, p_congres_non int default null, p_pourcentage numeric default null
) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_mon_username text; v_montant numeric; v_mot text; v_majorite numeric;
  v_gouv numeric; v_prev numeric;
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
      update citoyens set tresorerie = tresorerie + v_montant where id = v_id;
      insert into messages (type, expediteur_id, expediteur_username, destinataire_id, titre, contenu)
      values ('gouvernemental', auth.uid(), v_mon_username, v_id,
              'Rendement des contribuables',
              'Le rendement a été attribué par ' || p_congres_oui || ' chambres du Congrès (' || v_majorite || '%), vous avez été envoyé par le gouvernement : ' ||
              v_montant || ' R$ pour vous remercier de votre soutien et parce que la trésorerie du pays a fait un bénéfice ' || v_mot || '.');
    end if;
  end loop;

  update citoyens set taxes_gouv_60j = 0, taxe_preventive_60j = 0 where true;
  return 'Redevance attribuée à ' || p_pourcentage || '% (plafond 5000 R$/personne).';
end;
$$;
grant execute on function admin_traiter_redevance(text, text, int, int, numeric) to authenticated;
