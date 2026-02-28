-- Ensure newly created views and tables are visible to PostgREST immediately.
notify pgrst, 'reload schema';
