-- Task 1.4: set_teams, set_team_name, update_settings, start_game.
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

create temp table ctx (k text primary key, v text);
grant all on ctx to public;

select plan(34);

-- Room with five people: Ann (host), Bob, Cy, Di, Ed ---------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
insert into ctx values ('code', public.create_room('Ann') -> 'room' ->> 'code');
select pg_temp.act_as('00000000-0000-0000-0000-000000000002');
select public.join_room((select v from ctx where k = 'code'), 'Bob');
select pg_temp.act_as('00000000-0000-0000-0000-000000000003');
select public.join_room((select v from ctx where k = 'code'), 'Cy');
select pg_temp.act_as('00000000-0000-0000-0000-000000000004');
select public.join_room((select v from ctx where k = 'code'), 'Di');
select pg_temp.act_as('00000000-0000-0000-0000-000000000005');
select public.join_room((select v from ctx where k = 'code'), 'Ed');

-- set_teams ----------------------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000002');
select throws_ok(
  $$ select public.set_teams('{"00000000-0000-0000-0000-000000000002": 0}'::jsonb) $$,
  'P0001', 'not_host', 'set_teams rejects a non-host');

select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select throws_ok(
  $$ select public.set_teams('{"00000000-0000-0000-0000-000000000002": 2}'::jsonb) $$,
  'P0001', 'invalid_team', 'team 2 rejected');
select throws_ok(
  $$ select public.set_teams('{"00000000-0000-0000-0000-000000000002": "red"}'::jsonb) $$,
  'P0001', 'invalid_team', 'non-numeric team rejected');
select throws_ok(
  $$ select public.set_teams('{"00000000-0000-0000-0000-0000000000ff": 0}'::jsonb) $$,
  'P0001', 'player_not_found', 'unknown player rejected');

select public.set_teams(
  '{"00000000-0000-0000-0000-000000000001": 0,
    "00000000-0000-0000-0000-000000000002": 0,
    "00000000-0000-0000-0000-000000000003": 1}'::jsonb);
select pg_temp.act_admin();
select is(
  (select array_agg(coalesce(team::text, '-') order by seat) from public.players),
  array['0', '0', '1', '-', '-'],
  'set_teams assigns the listed players and leaves the others alone');

select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select public.set_teams('{"00000000-0000-0000-0000-000000000003": null}'::jsonb);
select pg_temp.act_admin();
select is(
  (select team from public.players where user_id = '00000000-0000-0000-0000-000000000003'),
  null, 'null unassigns a player');

-- set_team_name ---------------------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000002');
select throws_ok($$ select public.set_team_name(0, 'Reds') $$, 'P0001', 'not_host', 'set_team_name rejects a non-host');

select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.set_team_name(2, 'Reds') $$, 'P0001', 'invalid_team', 'team index out of range rejected');
select throws_ok($$ select public.set_team_name(0, '   ') $$, 'P0001', 'invalid_name', 'blank team name rejected');
select public.set_team_name(0, '  ' || repeat('x', 30) || '  ');
select public.set_team_name(1, 'Blues');
select pg_temp.act_admin();
select is(
  (select team_names from public.rooms),
  array[repeat('x', 20), 'Blues'],
  'team names are trimmed and cut to 20 characters');

-- update_settings --------------------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000002');
select throws_ok($$ select public.update_settings('{"slips_per_player": 5}'::jsonb) $$, 'P0001', 'not_host', 'update_settings rejects a non-host');

select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.update_settings('{"slips_per_player": 0}'::jsonb) $$, 'P0001', 'invalid_setting', 'slips_per_player 0 rejected');
select throws_ok($$ select public.update_settings('{"slips_per_player": 11}'::jsonb) $$, 'P0001', 'invalid_setting', 'slips_per_player 11 rejected');
select throws_ok($$ select public.update_settings('{"slips_per_player": 2.5}'::jsonb) $$, 'P0001', 'invalid_setting', 'fractional slips_per_player rejected');
select throws_ok($$ select public.update_settings('{"turn_seconds": 45}'::jsonb) $$, 'P0001', 'invalid_setting', 'turn_seconds 45 rejected');
select throws_ok($$ select public.update_settings('{"submission_seconds": 29}'::jsonb) $$, 'P0001', 'invalid_setting', 'submission_seconds 29 rejected');
select throws_ok($$ select public.update_settings('{"submission_seconds": 601}'::jsonb) $$, 'P0001', 'invalid_setting', 'submission_seconds 601 rejected');
select throws_ok($$ select public.update_settings('{"skip_mode": "sometimes"}'::jsonb) $$, 'P0001', 'invalid_setting', 'unknown skip_mode rejected');
select throws_ok($$ select public.update_settings('{"colour": "red"}'::jsonb) $$, 'P0001', 'invalid_setting', 'unknown setting rejected');
select throws_ok($$ select public.update_settings('{"turn_seconds": "60"}'::jsonb) $$, 'P0001', 'invalid_setting', 'wrong JSON type rejected');

select public.update_settings('{"slips_per_player": 5, "skip_mode": "one_per_turn"}'::jsonb);
select public.update_settings('{"submission_seconds": 90, "turn_seconds": 30}'::jsonb);
select pg_temp.act_admin();
select row_eq(
  $$ select slips_per_player, turn_seconds, submission_seconds, skip_mode from public.rooms $$,
  row(5, 30, 90, 'one_per_turn'::text),
  'valid settings apply, and a partial update keeps the others');

-- start_game ----------------------------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000002');
select throws_ok($$ select public.start_game() $$, 'P0001', 'not_host', 'start_game rejects a non-host');

-- Team 1 is empty after Cy was unassigned.
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.start_game() $$, 'P0001', 'not_enough_players', 'start needs two players on each team (team 1 empty)');

select public.set_teams(
  '{"00000000-0000-0000-0000-000000000003": 1, "00000000-0000-0000-0000-000000000004": 1}'::jsonb);
select public.set_teams('{"00000000-0000-0000-0000-000000000002": null}'::jsonb);
select throws_ok($$ select public.start_game() $$, 'P0001', 'not_enough_players', 'start needs two players on each team (team 0 has one)');

select public.set_teams('{"00000000-0000-0000-0000-000000000002": 0}'::jsonb);
select public.start_game();
select pg_temp.act_admin();
select is((select phase from public.rooms), 'submitting', 'start_game moves the room to submitting');
select is(
  (select submission_deadline from public.rooms),
  (select now() + submission_seconds * interval '1 second' from public.rooms),
  'start_game sets the submission deadline from the setting');
select is(
  (select role from public.players where user_id = '00000000-0000-0000-0000-000000000005'),
  'spectator', 'a player left without a team becomes a spectator');
select is(
  (select count(*)::int from public.players where role = 'player'), 4, 'the four assigned players stay players');
select is(
  (select count(*)::int from public.players where submitted), 0, 'nobody has submitted yet');
select is((select round::int from public.rooms), 0, 'the round counter is still 0 while submitting');

select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.start_game() $$, 'P0001', 'wrong_phase', 'start_game outside the lobby rejected');
select throws_ok($$ select public.set_teams('{"00000000-0000-0000-0000-000000000002": 1}'::jsonb) $$, 'P0001', 'wrong_phase', 'set_teams outside the lobby rejected');
select throws_ok($$ select public.set_team_name(0, 'Late') $$, 'P0001', 'wrong_phase', 'set_team_name outside the lobby rejected');
select throws_ok($$ select public.update_settings('{"turn_seconds": 60}'::jsonb) $$, 'P0001', 'wrong_phase', 'update_settings outside the lobby rejected');

select * from finish();

rollback;
