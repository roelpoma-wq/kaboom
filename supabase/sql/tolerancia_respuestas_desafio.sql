ALTER TABLE public.kaboom_game_sessions
  ADD COLUMN last_answer_time_expired boolean;

CREATE OR REPLACE FUNCTION public.kaboom_submit_answer(p_session_id uuid, p_session_token text, p_question_nonce uuid, p_answer text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  s public.kaboom_game_sessions%ROWTYPE;
  v_item jsonb;
  v_direction text;
  v_correct_answer text;
  v_correct boolean;
  v_time_expired boolean;
  v_now timestamptz;
  v_remaining numeric;
  v_ratio numeric;
  v_base integer;
  v_points integer := 0;
  v_streak integer;
  v_lives integer;
  v_correct_count integer;
  v_score integer;
  v_next_index integer;
  v_total integer;
  v_finished boolean;
BEGIN
  -- Bloquear la sesión durante el procesamiento.
  SELECT *
  INTO s
  FROM public.kaboom_game_sessions
  WHERE id = p_session_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Partida no encontrada';
  END IF;

  -- Verificar el token privado.
  IF s.session_token_hash IS NULL
     OR p_session_token IS NULL
     OR encode(
       extensions.digest(
         p_session_token, 'sha256'
       ),
       'hex'
     ) IS DISTINCT FROM s.session_token_hash
  THEN
    RAISE EXCEPTION 'Token inválido';
  END IF;

  -- Una solicitud repetida no vuelve a sumar.
  IF p_question_nonce IS NOT NULL
     AND p_question_nonce = s.last_processed_nonce
  THEN
    RETURN jsonb_build_object(
      'duplicate', true,
      'correct', s.last_answer_correct,
      'time_expired', s.last_answer_time_expired,
      'points', s.last_awarded_points,
      'score', s.score,
      'lives', s.lives,
      'correct_count', s.correct,
      'finished', s.status = 'finished'
    );
  END IF;

  IF s.status <> 'active' THEN
    RAISE EXCEPTION 'Partida no activa';
  END IF;

  IF GREATEST(
    s.started_at,
    s.question_started_at,
    s.last_answer_at
  ) <= clock_timestamp() - INTERVAL '10 minutes' THEN
    UPDATE public.kaboom_game_sessions
    SET status = 'abandoned'
    WHERE id = p_session_id;

    RETURN jsonb_build_object(
      'expired', true,
      'finished', false,
      'message', 'Partida caducada por inactividad'
    );
  END IF;

  IF GREATEST(
    s.started_at,
    s.question_started_at,
    s.last_answer_at
  ) <= clock_timestamp() - INTERVAL '10 minutes' THEN
    UPDATE public.kaboom_game_sessions
    SET status = 'abandoned'
    WHERE id = p_session_id;

    RETURN jsonb_build_object(
      'expired', true,
      'finished', false,
      'message', 'Partida caducada por inactividad'
    );
  END IF;

  IF p_question_nonce IS NULL
     OR s.question_nonce IS NULL
     OR p_question_nonce <> s.question_nonce
  THEN
    RAISE EXCEPTION 'Pregunta inválida o desactualizada';
  END IF;

  IF s.question_deadline IS NULL
     OR s.current_time_limit IS NULL
     OR s.current_time_limit <= 0
  THEN
    RAISE EXCEPTION 'Temporizador no iniciado';
  END IF;

  v_total := jsonb_array_length(s.question_order);

  IF s.current_index >= v_total THEN
    RAISE EXCEPTION 'No quedan preguntas';
  END IF;

  -- Consultar la respuesta correcta en el servidor.
  SELECT
    a.items -> (
      (s.question_order ->> s.current_index)::integer
    ),
    c.direction
  INTO v_item, v_direction
  FROM public.kaboom_activities a
  JOIN public.kaboom_challenges c
    ON c.id = s.challenge_id
   AND c.activity_id = a.id
  WHERE a.id = s.activity_id;

  IF v_item IS NULL THEN
    RAISE EXCEPTION 'Pregunta no encontrada';
  END IF;

  v_correct_answer := CASE
    WHEN v_direction = 'reverse'
      THEN v_item->>'q'
    ELSE v_item->>'a'
  END;

  v_now := clock_timestamp();

  v_remaining := GREATEST(
    0,
    EXTRACT(
      EPOCH FROM (s.question_deadline - v_now)
    )::numeric
  );

  -- La tolerancia de envío no da bonificación por rapidez.
  v_time_expired := p_answer IS NULL
    OR v_now >= s.question_deadline + interval '750 milliseconds';
  v_correct :=
    NOT v_time_expired
    AND p_answer IS NOT NULL
    AND p_answer = v_correct_answer
    AND coalesce(
      s.current_options @> jsonb_build_array(p_answer),
      false
    );

  v_base := CASE s.difficulty
    WHEN 0 THEN 5
    WHEN 1 THEN 7
    WHEN 2 THEN 9
    ELSE 10
  END;

  IF v_correct THEN
    v_streak := s.streak + 1;

    v_ratio := LEAST(
      1,
      v_remaining / s.current_time_limit
    );

    v_points :=
      v_base
      + round(v_base * v_ratio)::integer
      + LEAST(3, ((v_streak - 1) / 3)::integer);

    v_lives := s.lives;

    -- Vida extra por cada cinco aciertos consecutivos.
    IF v_streak % 5 = 0 THEN
      v_lives := v_lives + 1;
    END IF;

    v_correct_count := s.correct + 1;
  ELSE
    v_streak := 0;
    v_lives := GREATEST(0, s.lives - 1);
    v_correct_count := s.correct;
  END IF;

  v_score := s.score + v_points;
  v_next_index := s.current_index + 1;

  v_finished :=
    v_lives <= 0
    OR v_next_index >= v_total;

  -- Actualizar el progreso de forma atómica.
  UPDATE public.kaboom_game_sessions
  SET
    current_index = v_next_index,
    correct = v_correct_count,
    score = v_score,
    lives = v_lives,
    streak = v_streak,
    last_processed_nonce = p_question_nonce,
    last_answer_correct = v_correct,
    last_answer_time_expired = v_time_expired,
    last_awarded_points = v_points,
    last_answer_at = v_now,
    question_nonce = NULL,
    question_started_at = NULL,
    question_deadline = NULL,
    current_options = NULL,
    current_time_limit = NULL,
    status = CASE
      WHEN v_finished THEN 'finished'
      ELSE 'active'
    END,
    finished_at = CASE
      WHEN v_finished THEN v_now
      ELSE NULL
    END
  WHERE id = p_session_id;

  IF v_finished THEN
    PERFORM public.kaboom_save_finished_game(p_session_id);
  END IF;

  RETURN jsonb_build_object(
    'duplicate', false,
    'correct', v_correct,
    'points', v_points,
    'score', v_score,
    'lives', v_lives,
    'streak', v_streak,
    'correct_count', v_correct_count,
    'answered', v_next_index,
    'question_total', v_total,
    'finished', v_finished,
    'time_expired', v_time_expired
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.kaboom_get_question(p_session_id uuid, p_session_token text)
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
    v_options := public.kaboom_generate_options(v_items, v_correct, v_direction);

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
    v_deadline :=
      v_now + (v_seconds * interval '1 second');

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
       OR v_deadline IS NULL
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
