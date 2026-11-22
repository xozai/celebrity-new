-- Task 1.2: row-level security. Members read their room; nobody writes directly; nobody reads slips.
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

create function pg_temp.act_anon() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'anon', true);
end $$;
grant execute on function pg_temp.act_anon() to public;

select plan(23);

-- Fixtures, written as the table owner ---------------------------------------------
insert into public.rooms (id, code, host_id) values
  ('a0000000-0000-0000-0000-00000000000a', 'AAAA', '00000000-0000-0000-0000-000000000001'),
  ('b0000000-0000-0000-0000-00000000000b', 'BBBB', '00000000-0000-0000-0000-000000000003');
insert into public.players (room_id, user_id, name, seat) values
  ('a0000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000001', 'Ann', 1),
  ('a0000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000002', 'Bob', 2),
  ('b0000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000000003', 'Cy', 1);
insert into public.slips (room_id, author_id, name) values
  ('a0000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000001', 'Madonna');
insert into public.turns (room_id, round, team, player_id, player_name) values
  ('a0000000-0000-0000-0000-00000000000a', 1, 0, '00000000-0000-0000-0000-000000000001', 'Ann');

-- A member reads their room ------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.rooms), 1, 'member sees exactly their room');
select is((select code from public.rooms), 'AAAA', 'member sees the right room');
select is((select count(*)::int from public.players), 2, 'member sees every player in their room');
select is((select count(*)::int from public.turns), 1, 'member sees their room''s turn history');
select throws_ok('select * from public.slips', '42501', null, 'member cannot select from slips');

-- Another member sees only their own room ------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000003');
select is((select code from public.rooms), 'BBBB', 'other member sees only their room');
select is((select count(*)::int from public.players), 1, 'other member sees only their own players');
select is((select count(*)::int from public.turns), 0, 'other member sees no turns from another room');

-- A non-member reads nothing ---------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000004');
select is((select count(*)::int from public.rooms), 0, 'non-member sees no rooms');
select is((select count(*)::int from public.players), 0, 'non-member sees no players');
select is((select count(*)::int from public.turns), 0, 'non-member sees no turns');

-- Signed-out callers have no access at all -----------------------------------------------------
select throws_ok('select * from public.room_creations', '42501', null, 'members cannot read the room-creation log');
select pg_temp.act_anon();
select throws_ok('select * from public.rooms', '42501', null, 'anon cannot select rooms');

-- No direct writes, even for a member of the room ------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select throws_ok(
  $$ insert into public.rooms (code) values ('CCCC') $$, '42501', null, 'insert on rooms denied');
select throws_ok(
  $$ update public.rooms set round = 1 $$, '42501', null, 'update on rooms denied');
select throws_ok(
  $$ delete from public.rooms $$, '42501', null, 'delete on rooms denied');
select throws_ok(
  $$ insert into public.players (room_id, user_id, name, seat)
     values ('a0000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000009', 'Eve', 9) $$,
  '42501', null, 'insert on players denied');
select throws_ok(
  $$ update public.players set name = 'X' $$, '42501', null, 'update on players denied');
select throws_ok(
  $$ delete from public.players $$, '42501', null, 'delete on players denied');
select throws_ok(
  $$ insert into public.slips (room_id, name) values ('a0000000-0000-0000-0000-00000000000a', 'X') $$,
  '42501', null, 'insert on slips denied');
select throws_ok(
  $$ update public.slips set name = 'X' $$, '42501', null, 'update on slips denied');
select throws_ok(
  $$ delete from public.slips $$, '42501', null, 'delete on slips denied');
select throws_ok(
  $$ insert into public.turns (room_id, round, team, player_id, player_name)
     values ('a0000000-0000-0000-0000-00000000000a', 1, 0, '00000000-0000-0000-0000-000000000001', 'Ann') $$,
  '42501', null, 'insert on turns denied');

select * from finish();

rollback;
