-- Turn on row level security for every table in the public schema.
--
-- Supabase exposes the public schema through its REST API (PostgREST), where
-- the "anon" and "authenticated" roles can read and write any table that
-- doesn't have RLS on. This app never uses that API: the server connects
-- straight to Postgres as the table owner, and owners skip RLS. So with RLS
-- on and no policies, the REST API sees nothing, and the server works as before.
--
-- Loops over all tables so schema_migrations and any table added before this
-- runs are covered too. A table added by a later migration needs its own
-- ENABLE ROW LEVEL SECURITY line.
DO $$
DECLARE t record;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t.tablename);
  END LOOP;
END $$;
