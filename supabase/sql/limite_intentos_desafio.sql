ALTER TABLE public.kaboom_challenges
  ADD COLUMN max_attempts integer NOT NULL DEFAULT 3 CHECK (max_attempts >= 1);

CREATE FUNCTION public.kaboom_teacher_challenges_with_limits()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO ''
AS $$
  SELECT coalesce(jsonb_agg(to_jsonb(details) || jsonb_build_object('max_attempts', challenge.max_attempts)
      ORDER BY details.created_at DESC), '[]'::jsonb)
  FROM public.kaboom_teacher_challenges() details
  JOIN public.kaboom_challenges challenge ON challenge.id = details.id;
$$;

CREATE FUNCTION public.kaboom_teacher_save_challenge(
  p_challenge_id uuid, p_title text, p_status text, p_pin_action text,
  p_new_pin text, p_max_attempts integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  result jsonb;
BEGIN
  result := public.kaboom_teacher_update_challenge(
    p_challenge_id, p_title, p_status, p_pin_action, p_new_pin
  );
  IF p_max_attempts IS NULL OR p_max_attempts < 1 THEN
    RAISE EXCEPTION 'El número de intentos debe ser un entero mayor o igual a 1';
  END IF;
  UPDATE public.kaboom_challenges SET max_attempts = p_max_attempts WHERE id = p_challenge_id;
  RETURN result;
END;
$$;

REVOKE ALL ON FUNCTION public.kaboom_teacher_challenges_with_limits() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.kaboom_teacher_save_challenge(uuid, text, text, text, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.kaboom_teacher_challenges_with_limits() TO authenticated;
GRANT EXECUTE ON FUNCTION public.kaboom_teacher_save_challenge(uuid, text, text, text, text, integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.kaboom_start_game(p_challenge_id uuid, p_player_name text, p_pin text, p_difficulty integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_challenge record;
  v_activity_id uuid;
  v_name text;
  v_normalized text;
  v_attempts integer;
  v_count integer;
  v_order jsonb;
  v_session_id uuid;
  v_token text;
  v_lives integer;
  v_seconds numeric;
BEGIN
  v_name := regexp_replace(
    btrim(coalesce(p_player_name, '')),
    '\s+', ' ', 'g'
  );

  v_normalized :=
    public.kaboom_normalize_name(v_name);

  IF char_length(v_name) NOT BETWEEN 2 AND 40
     OR v_normalized !~ '^[a-z ]+$'
  THEN
    RAISE EXCEPTION 'Nombre inválido';
  END IF;

  IF p_difficulty IS NULL
     OR p_difficulty NOT BETWEEN 0 AND 3
  THEN
    RAISE EXCEPTION 'Dificultad inválida';
  END IF;

  -- NUEVO: identificar la actividad del desafío.
  SELECT c.activity_id
  INTO v_activity_id
  FROM public.kaboom_challenges c
  WHERE c.id = p_challenge_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Desafío no disponible';
  END IF;

  -- NUEVO: mismo bloqueo utilizado por el trigger
  -- que protege las preguntas.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'kaboom:activity:' || v_activity_id::text,
      0
    )
  );

  SELECT
    c.id,
    c.activity_id,
    c.question_count,
    c.range_from,
    c.range_to,
    c.direction,
    c.max_attempts,
    c.pin_hash,
    a.difficulty_config
  INTO v_challenge
  FROM public.kaboom_challenges c
  JOIN public.kaboom_activities a
    ON a.id = c.activity_id
  WHERE c.id = p_challenge_id
    AND c.status = 'published'
    AND a.published = true
    AND a.visibility IN ('challenge', 'both')
    AND (c.opens_at IS NULL OR c.opens_at <= now())
    AND (c.closes_at IS NULL OR c.closes_at > now());

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Desafío no disponible';
  END IF;

  -- PIN opcional.
  IF v_challenge.pin_hash IS NOT NULL THEN
    IF coalesce(p_pin, '') !~ '^[0-9]{4,8}$'
       OR extensions.crypt(
         p_pin, v_challenge.pin_hash
       ) IS DISTINCT FROM v_challenge.pin_hash
    THEN
      RAISE EXCEPTION 'PIN incorrecto';
    END IF;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements_text(
      v_challenge.difficulty_config->'allowed'
    ) AS d(value)
    WHERE d.value::integer = p_difficulty
  ) THEN
    RAISE EXCEPTION 'Dificultad no permitida';
  END IF;

  -- Bloqueo existente: evita superar el límite de intentos.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      p_challenge_id::text || ':' || v_normalized,
      0
    )
  );

  SELECT count(*)
  INTO v_attempts
  FROM public.kaboom_game_sessions
  WHERE challenge_id = p_challenge_id
    AND normalized_name = v_normalized;

  IF v_attempts >= v_challenge.max_attempts THEN
    RAISE EXCEPTION
      'Ya utilizaste todos tus intentos';
  END IF;

  v_count := LEAST(
    coalesce(
      v_challenge.question_count,
      v_challenge.range_to - v_challenge.range_from + 1
    ),
    v_challenge.range_to - v_challenge.range_from + 1
  );

  IF v_count < 1 THEN
    RAISE EXCEPTION 'Cantidad de preguntas inválida';
  END IF;

  SELECT coalesce(
    jsonb_agg(question_index ORDER BY random_order),
    '[]'::jsonb
  )
  INTO v_order
  FROM (
    SELECT
      question_index,
      random() AS random_order
    FROM pg_catalog.generate_series(
      v_challenge.range_from - 1,
      v_challenge.range_to - 1
    ) AS question_index
    ORDER BY random()
    LIMIT v_count
  ) selected_questions;

  v_lives := CASE p_difficulty
    WHEN 0 THEN 4
    WHEN 1 THEN 3
    WHEN 2 THEN 2
    ELSE 1
  END;

  v_seconds := (
    v_challenge.difficulty_config
      ->'seconds'->>p_difficulty
  )::numeric;

  v_token := encode(
    extensions.gen_random_bytes(32),
    'hex'
  );

  INSERT INTO public.kaboom_game_sessions (
    mode,
    activity_id,
    challenge_id,
    player_name,
    player_key,
    normalized_name,
    difficulty,
    question_order,
    lives,
    session_token_hash
  )
  VALUES (
    'challenge',
    v_challenge.activity_id,
    p_challenge_id,
    v_name,
    v_normalized,
    v_normalized,
    p_difficulty,
    v_order,
    v_lives,
    encode(
      extensions.digest(v_token, 'sha256'),
      'hex'
    )
  )
  RETURNING id INTO v_session_id;

  RETURN jsonb_build_object(
    'session_id', v_session_id,
    'session_token', v_token,
    'player_name', v_name,
    'attempt_number', v_attempts + 1,
    'remaining_attempts', v_challenge.max_attempts - v_attempts - 1,
    'question_count', v_count,
    'difficulty', p_difficulty,
    'seconds_per_question', v_seconds,
    'lives', v_lives,
    'status', 'active'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.kaboom_remaining_attempts(p_challenge_id uuid, p_player_name text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_name text; v_count integer; v_max integer;
BEGIN
 v_name:=public.kaboom_normalize_name(regexp_replace(btrim(coalesce(p_player_name,'')),'\s+',' ','g'));
 IF char_length(v_name)<2 OR char_length(v_name)>40 OR v_name !~ '^[a-z ]+$' THEN RETURN NULL; END IF;
 SELECT c.max_attempts INTO v_max FROM public.kaboom_challenges c WHERE c.id=p_challenge_id AND c.status='published' AND (c.opens_at IS NULL OR c.opens_at<=now()) AND (c.closes_at IS NULL OR c.closes_at>now());
 IF NOT FOUND THEN RETURN NULL; END IF;
 SELECT count(*) INTO v_count FROM public.kaboom_game_sessions WHERE challenge_id=p_challenge_id AND normalized_name=v_name;
 RETURN greatest(0,v_max-v_count);
END $function$;
