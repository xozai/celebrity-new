-- Realtime publication: clients subscribe to rooms, players and turns; slips must never be published.
begin;

create extension if not exists pgtap with schema extensions;

select plan(5);

select is(
  (select array_agg(tablename::text order by tablename) from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public'),
  array['players', 'rooms', 'turns'],
  'supabase_realtime publishes exactly rooms, players and turns from public');
select is(
  (select count(*)::int from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'slips'),
  0, 'slips are not published');
select is(
  (select count(*)::int from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'celebrities'),
  0, 'celebrities are not published');
select is(
  (select count(*)::int from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'room_creations'),
  0, 'the room-creation log is not published');
-- Realtime applies the table's select policies, so the members-only rules from 0002 carry over.
select ok(
  (select bool_and(c.relrowsecurity) from pg_class c
    where c.oid in ('public.rooms'::regclass, 'public.players'::regclass, 'public.turns'::regclass)),
  'every published table has row-level security on');

select * from finish();

rollback;
