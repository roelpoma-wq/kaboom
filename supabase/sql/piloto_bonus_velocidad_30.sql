create or replace function public.kaboom_teacher_set_pilot_free(
  p_activity_id uuid,
  p_bonus boolean,
  p_items boolean,
  p_speed integer
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if auth.uid() is null or not exists (
    select 1 from public.kaboom_teachers where user_id = auth.uid()
  ) then
    raise exception 'Acceso docente requerido';
  end if;

  if p_bonus is null or p_items is null or p_speed is null or p_speed not between 1 and 30 then
    raise exception 'Configuración de ronda bonus inválida';
  end if;

  update public.kaboom_activities
     set difficulty_config = jsonb_set(
       coalesce(difficulty_config, '{}'::jsonb),
       '{pilot_free}',
       jsonb_build_object('bonus', p_bonus, 'items', p_items, 'speed', p_speed)
     )
   where id = p_activity_id and visibility in ('free', 'both');

  if not found then
    raise exception 'Actividad de Modo Libre no encontrada';
  end if;
  return jsonb_build_object('updated', true);
end
$$;

revoke all on function public.kaboom_teacher_set_pilot_free(uuid, boolean, boolean, integer) from public, anon;
grant execute on function public.kaboom_teacher_set_pilot_free(uuid, boolean, boolean, integer) to authenticated;
