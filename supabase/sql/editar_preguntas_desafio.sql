-- Función de Supabase para guardar el rango y la cantidad por partida.
-- Requiere las tablas existentes de actividades, desafíos y docentes de KABOOM.

CREATE OR REPLACE FUNCTION public.kaboom_teacher_update_challenge_questions(p_challenge_id uuid, p_range_from integer, p_range_to integer, p_question_count integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_challenge public.kaboom_challenges%rowtype; v_total integer; v_span integer;
begin
 if auth.uid() is null or not exists(select 1 from public.kaboom_teachers t where t.user_id=auth.uid()) then raise exception 'Acceso docente requerido'; end if;
 select * into v_challenge from public.kaboom_challenges where id=p_challenge_id for update;
 if not found then raise exception 'Desafío no encontrado'; end if;
 select jsonb_array_length(a.items) into v_total from public.kaboom_activities a where a.id=v_challenge.activity_id;
 if v_total is null then raise exception 'Actividad vinculada no encontrada'; end if;
 if p_range_from is null or p_range_to is null or p_range_from<1 or p_range_to<p_range_from or p_range_to>v_total then raise exception 'Rango inválido: la actividad contiene % preguntas',v_total; end if;
 v_span:=p_range_to-p_range_from+1;
 if p_question_count is not null and (p_question_count not in (10,20,30,40,50) or p_question_count>v_span) then raise exception 'Selecciona Todas o 10, 20, 30, 40, 50 preguntas, sin superar el rango'; end if;
 update public.kaboom_challenges set range_from=p_range_from,range_to=p_range_to,question_count=p_question_count where id=p_challenge_id;
 return jsonb_build_object('updated',true,'range_from',p_range_from,'range_to',p_range_to,'question_count',p_question_count,'available',v_total);
end $function$;

REVOKE ALL ON FUNCTION public.kaboom_teacher_update_challenge_questions(uuid, integer, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.kaboom_teacher_update_challenge_questions(uuid, integer, integer, integer) TO anon, authenticated, service_role;
