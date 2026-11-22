-- Task 1.3: create_room, join_room, leave_room, get_snapshot, heartbeat.
begin;

create extension if not exists pgtap with schema extensions;

create function pg_temp.act_as(u uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
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

create function pg_temp.act_anon() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'anon', true);
end $$;
grant execute on function pg_temp.act_anon() to public;

create temp table ctx (k text primary key, v text);
grant all on ctx to public;

select plan(36);

-- create_room ---------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
insert into ctx values ('snap_a', public.create_room('Ann')::text);
insert into ctx values ('code_a', (select v::jsonb -> 'room' ->> 'code' from ctx where k = 'snap_a'));

select matches(
  (select v from ctx where k = 'code_a'),
  '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{4}$',
  'room code is 4 characters from the allowed alphabet'
);
select is((select v::jsonb -> 'room' ->> 'phase' from ctx where k = 'snap_a'), 'lobby', 'new room starts in the lobby');
select is((select v::jsonb -> 'room' ->> 'host_id' from ctx where k = 'snap_a'), '00000000-0000-0000-0000-000000000001', 'creator is the host');
select is((select jsonb_array_length(v::jsonb -> 'players') from ctx where k = 'snap_a'), 1, 'creator is the only player');
select is((select v::jsonb -> 'players' -> 0 ->> 'name' from ctx where k = 'snap_a'), 'Ann', 'creator has the given name');
select is((select (v::jsonb -> 'players' -> 0 ->> 'seat')::int from ctx where k = 'snap_a'), 1, 'creator has seat 1');
select is((select v::jsonb -> 'players' -> 0 ->> 'role' from ctx where k = 'snap_a'), 'player', 'creator is a player');

select throws_ok($$ select public.create_room('') $$, 'P0001', 'invalid_name', 'empty name rejected');
select throws_ok($$ select public.create_room('   ') $$, 'P0001', 'invalid_name', 'blank name rejected');
select throws_ok($$ select public.create_room('A name that is far too long') $$, 'P0001', 'invalid_name', 'name over 20 chars rejected');
select is((select count(*)::int from public.rooms), 1, 'rejected calls created no room');

-- join_room -----------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000002');
select throws_ok($$ select public.join_room('ZZZZ', 'Bob') $$, 'P0001', 'room_not_found', 'unknown code rejected');
select throws_ok(
  format($$ select public.join_room(%L, '') $$, (select v from ctx where k = 'code_a')),
  'P0001', 'invalid_name', 'join with an empty name rejected');

insert into ctx values ('snap_b', public.join_room(lower((select v from ctx where k = 'code_a')), '  Bob ')::text);
select is((select jsonb_array_length(v::jsonb -> 'players') from ctx where k = 'snap_b'), 2, 'code is case-insensitive and join adds a player');
select is(
  (select p ->> 'name' from ctx, jsonb_array_elements(v::jsonb -> 'players') p where k = 'snap_b' and (p ->> 'seat') = '2'),
  'Bob', 'name is trimmed and the second player gets seat 2');
select is(
  (select p ->> 'role' from ctx, jsonb_array_elements(v::jsonb -> 'players') p where k = 'snap_b' and (p ->> 'seat') = '2'),
  'player', 'joining a lobby makes a player');

select pg_temp.act_as('00000000-0000-0000-0000-000000000003');
select throws_ok(
  format($$ select public.join_room(%L, 'bob') $$, (select v from ctx where k = 'code_a')),
  'P0001', 'name_taken', 'duplicate name rejected for a different user, ignoring case');

-- The same user rejoining keeps their seat and name.
select pg_temp.act_as('00000000-0000-0000-0000-000000000002');
insert into ctx values ('snap_b2', public.join_room((select v from ctx where k = 'code_a'), 'Robert')::text);
select is((select jsonb_array_length(v::jsonb -> 'players') from ctx where k = 'snap_b2'), 2, 'rejoining does not add a second seat');
select is(
  (select p ->> 'name' from ctx, jsonb_array_elements(v::jsonb -> 'players') p where k = 'snap_b2' and (p ->> 'seat') = '2'),
  'Bob', 'rejoining returns the existing seat unchanged');

-- A late joiner is a spectator.
select pg_temp.act_admin();
update public.rooms set phase = 'playing' where code = (select v from ctx where k = 'code_a');
select pg_temp.act_as('00000000-0000-0000-0000-000000000003');
insert into ctx values ('snap_c', public.join_room((select v from ctx where k = 'code_a'), 'Cy')::text);
select is(
  (select p ->> 'role' from ctx, jsonb_array_elements(v::jsonb -> 'players') p where k = 'snap_c' and (p ->> 'seat') = '3'),
  'spectator', 'joining after the lobby makes a spectator');

-- get_snapshot -------------------------------------------------------------------------------
select pg_temp.act_admin();
insert into public.slips (room_id, author_id, name)
select id, '00000000-0000-0000-0000-000000000001', 'Secret Celebrity' from public.rooms where code = (select v from ctx where k = 'code_a');
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select is(
  (select array_agg(k order by k) from jsonb_object_keys(public.get_snapshot((select id from public.rooms))) k),
  array['players', 'room', 'server_now', 'turns'],
  'snapshot has exactly room, players, turns and server_now');
select is(
  strpos(public.get_snapshot((select id from public.rooms))::text, 'Secret Celebrity'),
  0, 'slips are never included in the snapshot');
select is(
  jsonb_typeof(public.get_snapshot((select id from public.rooms)) -> 'turns'), 'array', 'turns is an array even when empty');
select ok(
  (public.get_snapshot((select id from public.rooms)) -> 'room') ? 'pile_count',
  'room uses the snake_case column names');

select pg_temp.act_as('00000000-0000-0000-0000-000000000004');
select throws_ok(
  format($$ select public.get_snapshot(%L) $$, (select id from public.rooms)),
  'P0001', 'not_member', 'non-member cannot get a snapshot');

-- heartbeat ------------------------------------------------------------------------------------
select pg_temp.act_admin();
update public.players set last_seen_at = now() - interval '1 hour' where user_id = '00000000-0000-0000-0000-000000000002';
select pg_temp.act_as('00000000-0000-0000-0000-000000000002');
select isnt(public.heartbeat((select id from public.rooms)), null, 'heartbeat returns the server time');
select pg_temp.act_admin();
select ok(
  (select last_seen_at from public.players where user_id = '00000000-0000-0000-0000-000000000002') > now() - interval '1 minute',
  'heartbeat refreshes last_seen_at');
select pg_temp.act_as('00000000-0000-0000-0000-000000000004');
select throws_ok(
  format($$ select public.heartbeat(%L) $$, (select id from public.rooms)),
  'P0001', 'not_member', 'non-member cannot heartbeat');

-- leave_room ---------------------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000002');
select public.leave_room();
select pg_temp.act_admin();
select is(
  (select count(*)::int from public.players where user_id = '00000000-0000-0000-0000-000000000002'),
  0, 'leaving removes the player');
select pg_temp.act_as('00000000-0000-0000-0000-000000000002');
select throws_ok($$ select public.leave_room() $$, 'P0001', 'not_member', 'leaving without a room is rejected');

-- The host leaving hands the room to the lowest remaining seat.
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select public.leave_room();
select pg_temp.act_admin();
select is(
  (select host_id::text from public.rooms where code = (select v from ctx where k = 'code_a')),
  '00000000-0000-0000-0000-000000000003', 'host leaving promotes the next seat');
select pg_temp.act_as('00000000-0000-0000-0000-000000000003');
select public.leave_room();
select pg_temp.act_admin();
select is(
  (select host_id from public.rooms where code = (select v from ctx where k = 'code_a')),
  null, 'an empty room has no host');

-- Joining a second room leaves the first one.
select pg_temp.act_as('00000000-0000-0000-0000-000000000005');
insert into ctx values ('snap_d', public.create_room('Dee')::text);
select pg_temp.act_as('00000000-0000-0000-0000-000000000006');
select public.join_room((select v::jsonb -> 'room' ->> 'code' from ctx where k = 'snap_d'), 'Eli');
select pg_temp.act_as('00000000-0000-0000-0000-000000000005');
select public.leave_room();
select pg_temp.act_as('00000000-0000-0000-0000-000000000006');
insert into ctx values ('snap_e', public.create_room('Eli')::text);
select pg_temp.act_admin();
select is(
  (select count(*)::int from public.players where user_id = '00000000-0000-0000-0000-000000000006'),
  1, 'creating a room moves the user out of the old one');

-- Rate limit --------------------------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000009');
select public.create_room('Zed') from generate_series(1, 5);
select throws_ok($$ select public.create_room('Zed') $$, 'P0001', 'rate_limited', 'sixth room in an hour rejected');
select pg_temp.act_admin();
update public.rooms set created_at = now() - interval '2 hours' where created_by = '00000000-0000-0000-0000-000000000009';
select pg_temp.act_as('00000000-0000-0000-0000-000000000009');
select lives_ok($$ select public.create_room('Zed') $$, 'old rooms no longer count against the limit');

-- Signed-out callers -----------------------------------------------------------------------------------------
select pg_temp.act_anon();
select throws_ok($$ select public.create_room('Nope') $$, '42501', null, 'anon cannot call create_room');

select * from finish();

rollback;
