-- Task 1.6: start_turn, got_it, skip_slip, current_slip, end_turn.
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

select plan(59);

-- Room: Ann, Bob (team 0) | Cy, Di (team 1), three slips each, round 1 under way. -------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
insert into ctx values ('code', public.create_room('Ann') -> 'room' ->> 'code');
select pg_temp.act_as('00000000-0000-0000-0000-000000000002');
select public.join_room((select v from ctx where k = 'code'), 'Bob');
select pg_temp.act_as('00000000-0000-0000-0000-000000000003');
select public.join_room((select v from ctx where k = 'code'), 'Cy');
select pg_temp.act_as('00000000-0000-0000-0000-000000000004');
select public.join_room((select v from ctx where k = 'code'), 'Di');
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select public.set_teams(
  '{"00000000-0000-0000-0000-000000000001": 0, "00000000-0000-0000-0000-000000000002": 0,
    "00000000-0000-0000-0000-000000000003": 1, "00000000-0000-0000-0000-000000000004": 1}'::jsonb);
select public.start_game();
select public.submit_slips(array['A1', 'A2', 'A3']);
select pg_temp.act_as('00000000-0000-0000-0000-000000000002');
select public.submit_slips(array['B1', 'B2', 'B3']);
select pg_temp.act_as('00000000-0000-0000-0000-000000000003');
select public.submit_slips(array['C1', 'C2', 'C3']);
select pg_temp.act_as('00000000-0000-0000-0000-000000000004');
select public.submit_slips(array['D1', 'D2', 'D3']);

select pg_temp.act_admin();
select row_eq(
  $$ select phase, current_team, turn_player_id, pile_count from public.rooms $$,
  row('playing'::text, 0::smallint, '00000000-0000-0000-0000-000000000001'::uuid, 12),
  'setup: round 1, Ann is up, 12 slips in the pile');

-- Before the turn starts ------------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.got_it() $$, 'P0001', 'turn_not_started', 'got_it before start_turn rejected');
select throws_ok($$ select public.skip_slip() $$, 'P0001', 'turn_not_started', 'skip_slip before start_turn rejected');
select is(public.current_slip(), null, 'current_slip is null before the turn starts');

-- start_turn --------------------------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000002');
select throws_ok($$ select public.start_turn() $$, 'P0001', 'not_your_turn', 'a teammate who is not up cannot start the turn');
select pg_temp.act_as('00000000-0000-0000-0000-000000000003');
select throws_ok($$ select public.start_turn() $$, 'P0001', 'not_your_turn', 'the other team cannot start the turn');
select pg_temp.act_as('00000000-0000-0000-0000-000000000099');
select throws_ok($$ select public.start_turn() $$, 'P0001', 'not_member', 'a non-member cannot start the turn');

select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
insert into ctx values ('s1', public.start_turn()::text);
select pg_temp.act_admin();
select is(
  (select v::jsonb ->> 'id' from ctx where k = 's1'),
  (select id::text from public.slips where is_current),
  'start_turn returns the slip now marked current');
select ok((select v::jsonb ->> 'name' from ctx where k = 's1') ~ '^[A-D][1-3]$', 'the slip carries its name');
select ok(
  (select turn_ends_at between clock_timestamp() + interval '59 seconds' and clock_timestamp() + interval '60 seconds'
     from public.rooms),
  'turn_ends_at is turn_seconds from the moment the turn starts');
select row_eq(
  $$ select turn_got, turn_skips, pile_count from public.rooms $$,
  row(0, 0, 12), 'a fresh turn has no got-its or skips');

select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.start_turn() $$, 'P0001', 'turn_already_started', 'starting a running turn rejected');

-- current_slip ---------------------------------------------------------------------------------------------
select is((public.current_slip() ->> 'id'), (select v::jsonb ->> 'id' from ctx where k = 's1'), 'the clue-giver gets the same slip back after a reconnect');
select pg_temp.act_as('00000000-0000-0000-0000-000000000002');
select is(public.current_slip(), null, 'a teammate calling current_slip gets nothing');
select pg_temp.act_as('00000000-0000-0000-0000-000000000003');
select is(public.current_slip(), null, 'an opponent calling current_slip gets nothing');

-- got_it ------------------------------------------------------------------------------------------------------
select throws_ok($$ select public.got_it() $$, 'P0001', 'not_your_turn', 'only the clue-giver can call got_it');
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
insert into ctx values ('s2', public.got_it()::text);
select pg_temp.act_admin();
select isnt(
  (select v::jsonb ->> 'id' from ctx where k = 's2'),
  (select v::jsonb ->> 'id' from ctx where k = 's1'),
  'got_it returns a different slip');
select row_eq(
  $$ select turn_got, pile_count, scores -> 0 from public.rooms $$,
  row(1, 11, '[1,0]'::jsonb),
  'got_it counts the slip and scores it for the clue-giver''s team in this round');
select ok(
  (select not in_pile and not is_current from public.slips where id = (select (v::jsonb ->> 'id')::uuid from ctx where k = 's1')),
  'the guessed slip leaves the pile');
select is(
  (select id::text from public.slips where is_current), (select v::jsonb ->> 'id' from ctx where k = 's2'),
  'the returned slip is the new current slip');

-- skip_slip -----------------------------------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.skip_slip() $$, 'P0001', 'skip_not_allowed', 'skip rejected when skip_mode is off');

select pg_temp.act_admin();
update public.rooms set skip_mode = 'one_per_turn';
select pg_temp.act_as('00000000-0000-0000-0000-000000000002');
select throws_ok($$ select public.skip_slip() $$, 'P0001', 'not_your_turn', 'only the clue-giver can skip');
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
insert into ctx values ('s3', public.skip_slip()::text);
select pg_temp.act_admin();
select isnt(
  (select v::jsonb ->> 'id' from ctx where k = 's3'), (select v::jsonb ->> 'id' from ctx where k = 's2'),
  'skip_slip returns a different slip');
select ok(
  (select in_pile from public.slips where id = (select (v::jsonb ->> 'id')::uuid from ctx where k = 's2')),
  'a skipped slip stays in the pile');
select row_eq(
  $$ select pile_count, turn_skips, turn_got from public.rooms $$,
  row(11, 1, 1), 'a skip does not change the pile or the score');
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.skip_slip() $$, 'P0001', 'skip_not_allowed', 'second skip rejected under one_per_turn');

select pg_temp.act_admin();
update public.rooms set skip_mode = 'unlimited';
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select lives_ok($$ select public.skip_slip() $$, 'skips are unlimited when skip_mode is unlimited');
select lives_ok($$ select public.skip_slip() $$, 'and again');
select pg_temp.act_admin();
select is(
  (select count(*)::int from public.slips where is_current), 1, 'there is always exactly one current slip during a turn');
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');

-- Time limits ---------------------------------------------------------------------------------------------------------
select throws_ok($$ select public.end_turn() $$, 'P0001', 'deadline_not_reached', 'end_turn before the deadline rejected');

select pg_temp.act_admin();
update public.rooms set turn_ends_at = now() - interval '1 second';
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.got_it() $$, 'P0001', 'turn_over', 'got_it after the deadline rejected');
select throws_ok($$ select public.skip_slip() $$, 'P0001', 'turn_over', 'skip_slip after the deadline rejected');

-- end_turn ---------------------------------------------------------------------------------------------------------------
select pg_temp.act_admin();
select is((select pile_count from public.rooms), 11, 'setup: eleven slips left before the turn is closed');
select pg_temp.act_as('00000000-0000-0000-0000-000000000003');
select public.end_turn();
select pg_temp.act_admin();
select row_eq(
  $$ select round, team, player_id, player_name, cardinality(guessed), ended_at is not null from public.turns $$,
  row(1::smallint, 0::smallint, '00000000-0000-0000-0000-000000000001'::uuid, 'Ann'::text, 1, true),
  'end_turn writes the history row for Ann''s turn');
select is((select guessed from public.turns), array[(select name from public.slips where id = (select (v::jsonb ->> 'id')::uuid from ctx where k = 's1'))], 'the history lists what was guessed');
select ok((select cardinality(skipped) >= 1 from public.turns), 'the history lists what was skipped');
select ok(
  (select in_pile and not is_current from public.slips where id = (select (v::jsonb ->> 'id')::uuid from ctx where k = 's3') ),
  'the unfinished slip is back in the pile');
select is((select count(*)::int from public.slips where is_current or guessed_at is not null or skipped_in_turn), 0, 'per-turn markers are cleared');
select row_eq(
  $$ select current_team, turn_player_id, turn_idx, turn_ends_at, turn_got, turn_skips, pile_count, scores -> 0 from public.rooms $$,
  row(1::smallint, '00000000-0000-0000-0000-000000000003'::uuid, array[1, 0], null::timestamptz, 0, 0, 11, '[1,0]'::jsonb),
  'the turn passes to the other team''s first player and the score stays');

select pg_temp.act_as('00000000-0000-0000-0000-000000000004');
select lives_ok($$ select public.end_turn() $$, 'a second end_turn is a no-op');
select pg_temp.act_admin();
select is((select count(*)::int from public.turns), 1, 'and writes no second history row');

-- The rotation: Cy, then Bob, then Di, then Ann again. ----------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000003');
select public.start_turn();
select pg_temp.act_admin();
update public.rooms set turn_ends_at = now() - interval '1 second';
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select public.end_turn();
select pg_temp.act_admin();
select is((select turn_player_id::text from public.rooms), '00000000-0000-0000-0000-000000000002', 'after Cy comes Bob');
select pg_temp.act_as('00000000-0000-0000-0000-000000000002');
select public.start_turn();
select pg_temp.act_admin();
update public.rooms set turn_ends_at = now() - interval '1 second';
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select public.end_turn();
select pg_temp.act_admin();
select is((select turn_player_id::text from public.rooms), '00000000-0000-0000-0000-000000000004', 'after Bob comes Di');
select pg_temp.act_as('00000000-0000-0000-0000-000000000004');
select public.start_turn();
select pg_temp.act_admin();
update public.rooms set turn_ends_at = now() - interval '1 second';
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select public.end_turn();
select pg_temp.act_admin();
select is((select turn_player_id::text from public.rooms), '00000000-0000-0000-0000-000000000001', 'after Di the rotation wraps to Ann');
select is((select turn_idx from public.rooms), array[2, 2], 'each team has taken two turns');

select pg_temp.act_as('00000000-0000-0000-0000-000000000099');
select throws_ok($$ select public.end_turn() $$, 'P0001', 'not_member', 'a non-member cannot end a turn');

-- Actions bound to a slip (review finding 6) ------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
insert into ctx values ('n1', public.start_turn()::text);
insert into ctx values ('n2', public.got_it((select (v::jsonb ->> 'id')::uuid from ctx where k = 'n1'))::text);
select pg_temp.act_admin();
select row_eq($$ select turn_got, pile_count from public.rooms $$, row(1, 10), 'got_it with the displayed slip id scores it');
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select is(
  public.got_it((select (v::jsonb ->> 'id')::uuid from ctx where k = 'n1')) ->> 'id',
  (select v::jsonb ->> 'id' from ctx where k = 'n2'),
  'a repeated got_it for the same slip returns the current slip');
select pg_temp.act_admin();
select row_eq($$ select turn_got, pile_count from public.rooms $$, row(1, 10), 'and scores nothing a second time');
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select is(
  public.got_it(gen_random_uuid()) ->> 'id', (select v::jsonb ->> 'id' from ctx where k = 'n2'),
  'got_it with an unknown slip id returns the current slip');
select is(
  public.skip_slip((select (v::jsonb ->> 'id')::uuid from ctx where k = 'n1')) ->> 'id', (select v::jsonb ->> 'id' from ctx where k = 'n2'),
  'skip_slip for a slip that is no longer current returns the current slip');
select pg_temp.act_admin();
select row_eq($$ select turn_skips, pile_count from public.rooms $$, row(0, 10), 'and skips nothing');
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
insert into ctx values ('n3', public.skip_slip((select (v::jsonb ->> 'id')::uuid from ctx where k = 'n2'))::text);
select is(
  public.got_it((select (v::jsonb ->> 'id')::uuid from ctx where k = 'n2')) ->> 'id', (select v::jsonb ->> 'id' from ctx where k = 'n3'),
  'a score for the slip that was just skipped leaves its replacement alone');
select pg_temp.act_admin();
select row_eq($$ select turn_got, turn_skips, pile_count from public.rooms $$, row(1, 1, 10), 'nothing changed after the stale score');

-- The deadline is judged when the request runs, not when its transaction began (review finding 5) --------------
update public.rooms set turn_ends_at = clock_timestamp() + interval '0.3 seconds';
select pg_sleep(0.6);
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.got_it() $$, 'P0001', 'turn_over', 'got_it that runs after expiry is rejected even in an older transaction');
select throws_ok($$ select public.skip_slip() $$, 'P0001', 'turn_over', 'and so is skip_slip');
select is(public.current_slip(), null, 'current_slip returns nothing after expiry');
select lives_ok($$ select public.end_turn() $$, 'end_turn is accepted once the real clock has passed the deadline');
select pg_temp.act_admin();
select ok((select ended_at >= now() + interval '0.5 seconds' from public.turns order by id desc limit 1), 'the history row records when the turn actually ended');

select * from finish();

rollback;
