SELECT schemaname, tablename
FROM pg_tables
WHERE tablename = 'schema_migrations';

-- Drop it (adjust schema if not "public")
DROP TABLE IF EXISTS public.schema_migrations;

TRUNCATE TABLE public.schema_migrations;
-- If the table stored a single row and it's now empty, you can seed it as "no migrations, clean":
INSERT INTO public.schema_migrations(version, dirty) VALUES (0, false);
