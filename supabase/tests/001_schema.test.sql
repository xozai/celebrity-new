-- Task 1.1: tables, checks and unique indexes exist and behave.
begin;

create extension if not exists pgtap with schema extensions;

select plan(31);

-- Tables ------------------------------------------------------------------
select has_table('public', 'rooms', 'rooms exists');
select has_table('public', 'players', 'players exists');
select has_table('public', 'slips', 'slips exists');
select has_table('public', 'turns', 'turns exists');

select col_is_pk('public', 'rooms', 'id', 'rooms pk');
select col_is_pk('public', 'players', array['room_id', 'user_id'], 'players pk is (room_id, user_id)');
select col_is_pk('public', 'slips', 'id', 'slips pk');
select col_is_pk('public', 'turns', 'id', 'turns pk');
select col_is_unique('public', 'rooms', 'code', 'room code is unique');

-- Defaults ----------------------------------------------------------------
insert into public.rooms (code) values ('ABCD');

select row_eq(
  $$ select phase, round, slips_per_player, turn_seconds, submission_seconds, skip_mode, pile_count
       from public.rooms where code = 'ABCD' $$,
  row('lobby'::text, 0::smallint, 3, 60, 120, 'off'::text, 0),
  'room defaults match the plan'
);
select is(
  (select team_names from public.rooms where code = 'ABCD'),
  array['Team 1', 'Team 2'],
  'default team names'
);
select is(
  (select scores from public.rooms where code = 'ABCD'),
  '[[0,0],[0,0],[0,0]]'::jsonb,
  'scores start as three zeroed rounds'
);

-- Checks on rooms -----------------------------------------------------------
select throws_ok($$ insert into public.rooms (code) values ('abcd') $$, '23514', null, 'lowercase code rejected');
select throws_ok($$ insert into public.rooms (code) values ('ABC0') $$, '23514', null, 'code with 0 rejected');
select throws_ok($$ insert into public.rooms (code) values ('ABCDE') $$, '23514', null, '5-char code rejected');
select throws_ok($$ insert into public.rooms (code) values ('ABCD') $$, '23505', null, 'duplicate code rejected');
select throws_ok($$ insert into public.rooms (code, phase) values ('EFGH', 'bogus') $$, '23514', null, 'unknown phase rejected');
select throws_ok($$ insert into public.rooms (code, round) values ('EFGH', 4) $$, '23514', null, 'round above 3 rejected');
select throws_ok($$ insert into public.rooms (code, slips_per_player) values ('EFGH', 11) $$, '23514', null, 'slips_per_player above 10 rejected');
select throws_ok($$ insert into public.rooms (code, turn_seconds) values ('EFGH', 45) $$, '23514', null, 'turn_seconds must be 30, 60 or 90');
select throws_ok($$ insert into public.rooms (code, submission_seconds) values ('EFGH', 10) $$, '23514', null, 'submission_seconds below 30 rejected');
select throws_ok($$ insert into public.rooms (code, skip_mode) values ('EFGH', 'sometimes') $$, '23514', null, 'unknown skip_mode rejected');
select throws_ok($$ insert into public.rooms (code, team_names) values ('EFGH', array['Only one']) $$, '23514', null, 'team_names needs exactly two entries');

-- players ---------------------------------------------------------------------
insert into public.players (room_id, user_id, name, seat)
select id, '00000000-0000-0000-0000-000000000001', 'Ann', 1 from public.rooms where code = 'ABCD';

select throws_ok(
  $$ insert into public.players (room_id, user_id, name, seat)
     select id, '00000000-0000-0000-0000-000000000002', 'ann', 2 from public.rooms where code = 'ABCD' $$,
  '23505', null, 'names are unique per room, ignoring case'
);
select throws_ok(
  $$ insert into public.players (room_id, user_id, name, seat)
     select id, '00000000-0000-0000-0000-000000000002', 'Bob', 1 from public.rooms where code = 'ABCD' $$,
  '23505', null, 'seats are unique per room'
);
select throws_ok(
  $$ insert into public.players (room_id, user_id, name, seat, team)
     select id, '00000000-0000-0000-0000-000000000002', 'Bob', 2, 2 from public.rooms where code = 'ABCD' $$,
  '23514', null, 'team must be 0 or 1'
);
select throws_ok(
  $$ insert into public.players (room_id, user_id, name, seat, role)
     select id, '00000000-0000-0000-0000-000000000002', 'Bob', 2, 'coach' from public.rooms where code = 'ABCD' $$,
  '23514', null, 'role must be player or spectator'
);

insert into public.rooms (code) values ('JKLM');
select throws_ok(
  $$ insert into public.players (room_id, user_id, name, seat)
     select id, '00000000-0000-0000-0000-000000000001', 'Ann', 1 from public.rooms where code = 'JKLM' $$,
  '23505', null, 'a user can be in only one room'
);

-- slips ---------------------------------------------------------------------
select throws_ok(
  $$ insert into public.slips (room_id, name) select id, '' from public.rooms where code = 'ABCD' $$,
  '23514', null, 'empty slip name rejected'
);
-- Two slips with the same name by the same author are two rows.
insert into public.slips (room_id, author_id, name)
select id, '00000000-0000-0000-0000-000000000001'::uuid, 'Madonna' from public.rooms where code = 'ABCD'
union all
select id, '00000000-0000-0000-0000-000000000001'::uuid, 'Madonna' from public.rooms where code = 'ABCD';
select is(
  (select count(*)::int from public.slips),
  2,
  'duplicate slip names are separate rows'
);

-- turns + cascade -----------------------------------------------------------
insert into public.turns (room_id, round, team, player_id, player_name)
select id, 1, 0, '00000000-0000-0000-0000-000000000001', 'Ann' from public.rooms where code = 'ABCD';

delete from public.rooms where code = 'ABCD';
select is(
  (select count(*)::int from public.players) + (select count(*)::int from public.slips) + (select count(*)::int from public.turns),
  0,
  'deleting a room cascades to players, slips and turns'
);

select * from finish();

rollback;
