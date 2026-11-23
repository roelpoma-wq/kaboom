CREATE TABLE IF NOT EXISTS public.kaboom_removed_free_marks (id text PRIMARY KEY);
ALTER TABLE public.kaboom_removed_free_marks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.kaboom_removed_free_marks FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.kaboom_removed_free_marks TO anon, authenticated;
CREATE POLICY read_removed_free_marks ON public.kaboom_removed_free_marks FOR SELECT TO anon, authenticated USING (true);

CREATE OR REPLACE FUNCTION public.kaboom_skip_removed_free_mark()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.id, 7310));
  IF EXISTS (SELECT 1 FROM public.kaboom_removed_free_marks WHERE id = NEW.id) THEN RETURN NULL; END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.kaboom_skip_removed_free_mark() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER kaboom_skip_removed_free_mark BEFORE INSERT ON public.kaboom_free_results
FOR EACH ROW EXECUTE FUNCTION public.kaboom_skip_removed_free_mark();

CREATE OR REPLACE FUNCTION public.kaboom_teacher_delete_mark(p_mode text, p_id text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (SELECT 1 FROM public.kaboom_teachers WHERE user_id = auth.uid()) THEN
    RAISE EXCEPTION 'Acceso docente requerido' USING ERRCODE = '42501';
  END IF;
  IF p_id IS NULL OR char_length(p_id) NOT BETWEEN 1 AND 512 THEN RAISE EXCEPTION 'Marca inválida'; END IF;
  IF p_mode = 'challenge' THEN
    DELETE FROM public.kaboom_attempts WHERE id = p_id::uuid AND mode = 'challenge';
  ELSIF p_mode = 'free' THEN
    PERFORM pg_advisory_xact_lock(hashtextextended(p_id, 7310));
    INSERT INTO public.kaboom_removed_free_marks (id) VALUES (p_id) ON CONFLICT DO NOTHING;
    DELETE FROM public.kaboom_free_results WHERE id = p_id;
  ELSE
    RAISE EXCEPTION 'Modo inválido';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.kaboom_teacher_delete_mark(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.kaboom_teacher_delete_mark(text, text) TO authenticated;
