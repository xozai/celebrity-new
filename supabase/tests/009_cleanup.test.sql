-- Task 1.9: cleanup_rooms() and its pg_cron schedule.
begin;

create extension if not exists pgtap with schema extensions;

create function pg_temp.act_as(u uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  insert into auth.users (id, aud, role, is_anonymous)
  values (u, 'authenticated', 'authenticated', true) on conflict (id) do nothing;
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
grant execute on function pg_temp.act_as(uuid) to public;

create function pg_temp.act_admin() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end $$;
grant execute on function pg_temp.act_admin() to public;

select plan(14);

-- Eight rooms, each with a player, a slip and a turn so the cascade can be checked. ---------------------
insert into public.rooms (code, phase, last_activity_at, finished_at) values
  ('AAAA', 'finished',  now(),                          now() - interval '2 hours'),    -- finished long ago, busy since: deleted
  ('BBBB', 'finished',  now() - interval '2 hours',     now() - interval '10 minutes'), -- finished recently: kept
  ('CCCC', 'lobby',     now() - interval '25 hours',    null),                          -- idle a day: deleted
  ('DDDD', 'lobby',     now() - interval '23 hours',    null),                          -- idle under a day: kept
  ('EEEE', 'playing',   now() - interval '25 hours',    null),                          -- abandoned mid-game: deleted
  ('FFFF', 'playing',   now(),                          null),                          -- active: kept
  ('GGGG', 'round_end', now() - interval '2 hours',     null),                          -- not finished, under a day: kept
  ('HHHH', 'finished',  now() - interval '2 hours',     null);                          -- no finish time: falls back to activity, deleted

insert into public.players (room_id, user_id, name, seat)
select id, ('00000000-0000-0000-0000-' || lpad(row_number() over (order by code)::text, 12, '0'))::uuid, 'P', 1
  from public.rooms;
insert into public.slips (room_id, name) select id, 'X' from public.rooms;
insert into public.turns (room_id, round, team, player_id, player_name)
select id, 1, 0, '00000000-0000-0000-0000-000000000001', 'P' from public.rooms;

-- The room-creation log: one old entry and one recent one.
insert into public.room_creations (user_id, created_at) values
  ('00000000-0000-0000-0000-0000000000a1', now() - interval '2 hours'),
  ('00000000-0000-0000-0000-0000000000a2', now() - interval '30 minutes');

select is(public.cleanup_rooms(), 4, 'cleanup_rooms returns how many rooms it deleted');
select is(
  (select array_agg(code order by code) from public.rooms),
  array['BBBB', 'DDDD', 'FFFF', 'GGGG'],
  'finished rooms over an hour past their finish time and rooms idle over 24 hours are gone; the rest stay');
select is((select count(*)::int from public.players), 4, 'players of deleted rooms are gone');
select is((select count(*)::int from public.slips), 4, 'slips of deleted rooms are gone');
select is((select count(*)::int from public.turns), 4, 'turns of deleted rooms are gone');
select is(
  (select array_agg(user_id::text) from public.room_creations), array['00000000-0000-0000-0000-0000000000a2'],
  'creation-log entries older than an hour are pruned');
select is(public.cleanup_rooms(), 0, 'a second run finds nothing to delete');

-- Boundaries ------------------------------------------------------------------------------------------------------
update public.rooms set finished_at = now() - interval '61 minutes' where code = 'BBBB';
update public.rooms set last_activity_at = now() - interval '24 hours 1 minute' where code = 'DDDD';
select is(public.cleanup_rooms(), 2, 'just over an hour (finished) and just over 24 hours (idle) are both deleted');
select is((select array_agg(code order by code) from public.rooms), array['FFFF', 'GGGG'], 'the active rooms remain');

-- Access -------------------------------------------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.cleanup_rooms() $$, '42501', null, 'signed-in clients cannot run the cleanup');
select pg_temp.act_admin();
select ok(has_function_privilege('service_role', 'public.cleanup_rooms()', 'execute'), 'service_role can run the cleanup');

-- Schedule -------------------------------------------------------------------------------------------------------------
select is((select count(*)::int from cron.job where jobname = 'cleanup-rooms'), 1, 'a pg_cron job named cleanup-rooms exists');
select is((select command from cron.job where jobname = 'cleanup-rooms'), 'select public.cleanup_rooms()', 'and it runs cleanup_rooms()');
select is((select schedule from cron.job where jobname = 'cleanup-rooms'), '*/10 * * * *', 'every ten minutes');

select * from finish();

rollback;
