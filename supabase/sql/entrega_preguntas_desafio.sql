CREATE OR REPLACE FUNCTION public.kaboom_question_delivery(p_session_id uuid, p_session_token text, p_start_nonce uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_session public.kaboom_game_sessions%ROWTYPE;
  v_item jsonb;
  v_items jsonb;
  v_direction text;
  v_question text;
  v_correct text;
  v_options jsonb;
  v_total integer;
  v_index integer;
  v_seconds numeric;
  v_nonce uuid;
  v_deadline timestamptz;
  v_now timestamptz;
BEGIN
  -- Bloquear la sesión para evitar solicitudes simultáneas.
  SELECT *
  INTO v_session
  FROM public.kaboom_game_sessions
  WHERE id = p_session_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Partida no encontrada';
  END IF;

  -- Validar el token privado.
  IF v_session.session_token_hash IS NULL
     OR p_session_token IS NULL
     OR encode(
       extensions.digest(p_session_token, 'sha256'),
       'hex'
     ) IS DISTINCT FROM v_session.session_token_hash
  THEN
    RAISE EXCEPTION 'Token inválido';
  END IF;

  -- Caducar sesiones con más de 10 minutos de inactividad.
  IF v_session.status = 'active'
     AND GREATEST(
       v_session.started_at,
       v_session.question_started_at,
       v_session.last_answer_at
     ) <= clock_timestamp() - INTERVAL '10 minutes'
  THEN
    UPDATE public.kaboom_game_sessions
    SET status = 'abandoned'
    WHERE id = p_session_id;

    RETURN jsonb_build_object(
      'expired', true,
      'finished', false,
      'message', 'Partida caducada por inactividad'
    );
  END IF;

  IF p_start_nonce IS NOT NULL THEN
    IF v_session.status <> 'active' OR v_session.question_nonce IS DISTINCT FROM p_start_nonce THEN
      RAISE EXCEPTION 'Pregunta no activa';
    END IF;
    v_now := clock_timestamp();
    v_deadline := v_session.question_deadline;
    IF v_deadline IS NULL THEN
      v_deadline := v_now + v_session.current_time_limit * interval '1 second';
      UPDATE public.kaboom_game_sessions
      SET question_started_at = v_now, question_deadline = v_deadline
      WHERE id = p_session_id;
    END IF;
    RETURN jsonb_build_object('deadline', v_deadline, 'server_time', clock_timestamp());
  END IF;

  -- Resolver una pregunta vencida antes de devolverla.
  -- Se reutiliza submit_answer para mantener
  -- una sola lógica de puntuación y vidas.
  IF v_session.status = 'active'
     AND v_session.question_nonce IS NOT NULL
     AND v_session.question_deadline IS NOT NULL
     AND clock_timestamp() >= v_session.question_deadline + interval '750 milliseconds'
  THEN
    PERFORM public.kaboom_submit_answer(
      p_session_id,
      p_session_token,
      v_session.question_nonce,
      NULL
    );

    -- Recuperar el estado actualizado.
    SELECT *
    INTO v_session
    FROM public.kaboom_game_sessions
    WHERE id = p_session_id;
  END IF;

  IF v_session.status = 'finished' THEN
    RETURN jsonb_build_object(
      'finished', true,
      'question_total',
        jsonb_array_length(v_session.question_order),
      'score', v_session.score,
      'lives', v_session.lives,
      'correct_count', v_session.correct
    );
  END IF;

  IF v_session.status <> 'active' THEN
    RAISE EXCEPTION 'Partida no activa';
  END IF;

  v_total := jsonb_array_length(
    v_session.question_order
  );

  IF v_session.current_index >= v_total THEN
    RETURN jsonb_build_object(
      'finished', true,
      'question_total', v_total
    );
  END IF;

  -- Obtener la actividad y la dirección del desafío.
  SELECT
    a.items,
    c.direction,
    (
      a.difficulty_config->'seconds'
      ->>v_session.difficulty
    )::numeric
  INTO
    v_items,
    v_direction,
    v_seconds
  FROM public.kaboom_activities a
  JOIN public.kaboom_challenges c
    ON c.activity_id = a.id
  WHERE a.id = v_session.activity_id
    AND c.id = v_session.challenge_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Actividad no encontrada';
  END IF;

  v_index := (
    v_session.question_order
    ->>v_session.current_index
  )::integer;

  v_item := v_items->v_index;

  IF v_item IS NULL THEN
    RAISE EXCEPTION 'Pregunta no encontrada';
  END IF;

  IF v_direction = 'reverse' THEN
    v_question := v_item->>'a';
    v_correct := v_item->>'q';
  ELSE
    v_question := v_item->>'q';
    v_correct := v_item->>'a';
  END IF;

  IF nullif(btrim(v_question), '') IS NULL
     OR nullif(btrim(v_correct), '') IS NULL
  THEN
    RAISE EXCEPTION 'Pregunta incompleta';
  END IF;

  v_now := clock_timestamp();

  -- Crear alternativas y temporizador solamente
  -- cuando se inicia una pregunta nueva.
  IF v_session.question_nonce IS NULL THEN

    -- Seleccionar hasta tres respuestas incorrectas,
    -- distintas de la respuesta correcta.
    -- Después mezclar las cuatro alternativas.
    IF v_direction = 'normal' AND jsonb_typeof(v_item->'wrong') = 'array' THEN
      WITH candidates AS (
        SELECT option #>> '{}' AS answer, 0 AS priority
        FROM jsonb_array_elements(v_item->'wrong') AS option
        WHERE jsonb_typeof(option) = 'string'
        UNION ALL
        SELECT item->>'a', 1
        FROM jsonb_array_elements(v_items) AS item
      ),
      distinct_answers AS (
        SELECT DISTINCT ON (lower(btrim(answer))) answer, priority
        FROM candidates
        WHERE nullif(btrim(answer), '') IS NOT NULL
          AND lower(btrim(answer)) <> lower(btrim(v_correct))
        ORDER BY lower(btrim(answer)), priority, answer
      ),
      distractors AS (
        SELECT answer FROM distinct_answers ORDER BY priority, random() LIMIT 3
      ),
      options AS (
        SELECT v_correct AS answer UNION ALL SELECT answer FROM distractors
      )
      SELECT jsonb_agg(answer ORDER BY random()) INTO v_options FROM options;
    ELSE
      v_options := public.kaboom_generate_options(v_items, v_correct, v_direction);
    END IF;

    -- Comprobar que exista la respuesta correcta.
    IF NOT v_options @> jsonb_build_array(v_correct)
    THEN
      RAISE EXCEPTION 'Error al generar alternativas';
    END IF;

    -- Utilizar el tiempo configurado en la actividad.
    IF v_seconds IS NULL
       OR v_seconds < 1
       OR v_seconds > 40
    THEN
      RAISE EXCEPTION 'Tiempo de pregunta inválido';
    END IF;

    v_nonce := gen_random_uuid();
    -- La preparación conserva la pregunta sin iniciar su plazo.
    v_deadline := NULL;

    UPDATE public.kaboom_game_sessions
    SET
      current_options = v_options,
      current_time_limit = v_seconds,
      question_nonce = v_nonce,
      question_started_at = v_now,
      question_deadline = v_deadline
    WHERE id = p_session_id;

  ELSE
    -- Si se recarga la página, conservar las opciones
    -- y el tiempo originales.
    v_options := v_session.current_options;
    v_nonce := v_session.question_nonce;
    v_deadline := v_session.question_deadline;
    v_seconds := v_session.current_time_limit;

    IF v_options IS NULL
       OR v_seconds IS NULL
    THEN
      RAISE EXCEPTION 'Estado de pregunta incompleto';
    END IF;
  END IF;

  -- No devolver la respuesta correcta.
  RETURN jsonb_build_object(
    'finished', false,
    'question_number', v_session.current_index + 1,
    'question_total', v_total,
    'question', v_question,
    'question_placement', coalesce(v_item->>'questionPlacement','auto'),
    'options', v_options,
    'question_nonce', v_nonce,
    'deadline', v_deadline,
    'answer_grace_ms', 750,
    'seconds_per_question', v_seconds,
    'server_time', clock_timestamp(),
    'lives', v_session.lives,
    'score', v_session.score,
    'correct_count', v_session.correct
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.kaboom_question_delivery(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.kaboom_question_delivery(uuid, text, uuid) TO anon, authenticated;
