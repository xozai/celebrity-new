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

-- The token of the slip currently being shown in the caller's room (what a client got back from its last draw).
create function pg_temp.tok() returns uuid language sql security definer as $$
  select s.draw_token from public.slips s
   where s.is_current and s.room_id = (select room_id from public.players where user_id = auth.uid())
$$;
grant execute on function pg_temp.tok() to public;

create function pg_temp.u_(n int) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
$$;
grant execute on function pg_temp.u_(int) to public;

create temp table ctx (k text primary key, v text);
grant all on ctx to public;

select plan(82);

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
select throws_ok($$ select public.got_it(pg_temp.tok()) $$, 'P0001', 'turn_not_started', 'got_it before start_turn rejected');
select throws_ok($$ select public.skip_slip(pg_temp.tok()) $$, 'P0001', 'turn_not_started', 'skip_slip before start_turn rejected');
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
select throws_ok($$ select public.got_it(pg_temp.tok()) $$, 'P0001', 'not_your_turn', 'only the clue-giver can call got_it');
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
insert into ctx values ('s2', public.got_it(pg_temp.tok())::text);
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
select throws_ok($$ select public.skip_slip(pg_temp.tok()) $$, 'P0001', 'skip_not_allowed', 'skip rejected when skip_mode is off');

select pg_temp.act_admin();
update public.rooms set skip_mode = 'one_per_turn';
select pg_temp.act_as('00000000-0000-0000-0000-000000000002');
select throws_ok($$ select public.skip_slip(pg_temp.tok()) $$, 'P0001', 'not_your_turn', 'only the clue-giver can skip');
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
insert into ctx values ('s3', public.skip_slip(pg_temp.tok())::text);
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
select throws_ok($$ select public.skip_slip(pg_temp.tok()) $$, 'P0001', 'skip_not_allowed', 'second skip rejected under one_per_turn');

select pg_temp.act_admin();
update public.rooms set skip_mode = 'unlimited';
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select lives_ok($$ select public.skip_slip(pg_temp.tok()) $$, 'skips are unlimited when skip_mode is unlimited');
select lives_ok($$ select public.skip_slip(pg_temp.tok()) $$, 'and again');
select pg_temp.act_admin();
select is(
  (select count(*)::int from public.slips where is_current), 1, 'there is always exactly one current slip during a turn');
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');

-- Time limits ---------------------------------------------------------------------------------------------------------
select throws_ok($$ select public.end_turn() $$, 'P0001', 'deadline_not_reached', 'end_turn before the deadline rejected');

select pg_temp.act_admin();
update public.rooms set turn_ends_at = now() - interval '1 second';
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.got_it(pg_temp.tok()) $$, 'P0001', 'turn_over', 'got_it after the deadline rejected');
select throws_ok($$ select public.skip_slip(pg_temp.tok()) $$, 'P0001', 'turn_over', 'skip_slip after the deadline rejected');

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
select ok((select skipped >= 1 from public.turns), 'the history counts what was skipped');

-- No skipped slip name may reach another player: those slips are still in the pile (review finding 4).
select pg_temp.act_as('00000000-0000-0000-0000-000000000003');
select is((select pg_typeof(skipped)::text from public.turns limit 1), 'integer', 'an opponent reading the turns table sees a count');
select is(
  jsonb_typeof(public.get_snapshot((select id from public.rooms)) -> 'turns' -> 0 -> 'skipped'), 'number',
  'an opponent''s snapshot carries a count too');
select is(
  (select count(*)::int from jsonb_array_elements(public.get_snapshot((select id from public.rooms)) -> 'turns') t,
                            jsonb_array_elements_text(t -> 'guessed') g
    where g in (select v::jsonb ->> 'name' from ctx where k in ('s2', 's3'))),
  0, 'and the history names only what was guessed, never the skipped slips');
select pg_temp.act_admin();
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

-- Per-draw tokens (review round 2, finding 5) --------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
insert into ctx values ('n1', public.start_turn()::text);
select ok((select (v::jsonb ->> 'token') ~ '^[0-9a-f-]{36}$' from ctx where k = 'n1'), 'start_turn returns a token with the slip');
select is(public.current_slip() ->> 'token', (select v::jsonb ->> 'token' from ctx where k = 'n1'), 'current_slip returns the token of the current draw');
insert into ctx values ('n2', public.got_it((select (v::jsonb ->> 'token')::uuid from ctx where k = 'n1'))::text);
select isnt((select v::jsonb ->> 'token' from ctx where k = 'n2'), (select v::jsonb ->> 'token' from ctx where k = 'n1'), 'every draw gets a fresh token');
select pg_temp.act_admin();
select row_eq($$ select turn_got, pile_count from public.rooms $$, row(1, 10), 'got_it with the current token scores the slip');
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select is(
  public.got_it((select (v::jsonb ->> 'token')::uuid from ctx where k = 'n1')) ->> 'token',
  (select v::jsonb ->> 'token' from ctx where k = 'n2'),
  'a repeated got_it returns the current slip with its current token');
select pg_temp.act_admin();
select row_eq($$ select turn_got, pile_count from public.rooms $$, row(1, 10), 'and scores nothing a second time');
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select is(
  public.got_it(gen_random_uuid()) ->> 'id', (select v::jsonb ->> 'id' from ctx where k = 'n2'),
  'got_it with an unknown token returns the current slip');
select is(
  public.skip_slip((select (v::jsonb ->> 'token')::uuid from ctx where k = 'n1')) ->> 'id', (select v::jsonb ->> 'id' from ctx where k = 'n2'),
  'skip_slip with a stale token returns the current slip');
select pg_temp.act_admin();
select row_eq($$ select turn_skips, pile_count from public.rooms $$, row(0, 10), 'and skips nothing');
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.got_it(null::uuid) $$, 'P0001', 'invalid_token', 'got_it requires a token');
select throws_ok($$ select public.skip_slip(null::uuid) $$, 'P0001', 'invalid_token', 'skip_slip requires a token');

-- A retry of an accepted skip must not trip the one-skip limit.
select pg_temp.act_admin();
update public.rooms set skip_mode = 'one_per_turn';
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
insert into ctx values ('n3', public.skip_slip((select (v::jsonb ->> 'token')::uuid from ctx where k = 'n2'))::text);
select is(
  public.skip_slip((select (v::jsonb ->> 'token')::uuid from ctx where k = 'n2')) ->> 'token',
  (select v::jsonb ->> 'token' from ctx where k = 'n3'),
  'retrying an accepted skip returns the current slip instead of skip_not_allowed');
select pg_temp.act_admin();
select row_eq($$ select turn_got, turn_skips, pile_count from public.rooms $$, row(1, 1, 10), 'and counts the skip once');
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select throws_ok(
  format($$ select public.skip_slip(%L) $$, (select v::jsonb ->> 'token' from ctx where k = 'n3')),
  'P0001', 'skip_not_allowed', 'a skip with the current token is still limited');
select is(
  public.got_it((select (v::jsonb ->> 'token')::uuid from ctx where k = 'n2')) ->> 'token', (select v::jsonb ->> 'token' from ctx where k = 'n3'),
  'a score for the slip that was just skipped leaves its replacement alone');
select pg_temp.act_admin();
select row_eq($$ select turn_got, turn_skips, pile_count from public.rooms $$, row(1, 1, 10), 'nothing changed after the stale score');

-- Skipping the only slip left redraws that same slip, with a new token, so the old token cannot act on it.
update public.slips set in_pile = false
 where room_id = (select room_id from public.players where user_id = pg_temp.u_(1)) and not is_current;
update public.rooms set pile_count = 1, skip_mode = 'unlimited';
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
insert into ctx values ('n4', public.skip_slip((select (v::jsonb ->> 'token')::uuid from ctx where k = 'n3'))::text);
select is((select v::jsonb ->> 'id' from ctx where k = 'n4'), (select v::jsonb ->> 'id' from ctx where k = 'n3'), 'skipping the sole remaining slip draws the same slip');
select isnt((select v::jsonb ->> 'token' from ctx where k = 'n4'), (select v::jsonb ->> 'token' from ctx where k = 'n3'), 'with a fresh token');
select is(
  public.skip_slip((select (v::jsonb ->> 'token')::uuid from ctx where k = 'n3')) ->> 'token', (select v::jsonb ->> 'token' from ctx where k = 'n4'),
  'a retry with the old token changes nothing');
select is(
  public.got_it((select (v::jsonb ->> 'token')::uuid from ctx where k = 'n3')) ->> 'token', (select v::jsonb ->> 'token' from ctx where k = 'n4'),
  'and neither does a stale score for the same slip');
select pg_temp.act_admin();
select row_eq($$ select turn_got, turn_skips, pile_count from public.rooms $$, row(1, 2, 1), 'one skip counted, nothing scored');

-- The token is never readable by a client ---------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select is(strpos(public.get_snapshot((select id from public.rooms)) ::text, (select v::jsonb ->> 'token' from ctx where k = 'n4')), 0, 'the token is not in the snapshot');
select throws_ok('select draw_token from public.slips', '42501', null, 'and slips stay unreadable');
select pg_temp.act_admin();
select hasnt_column('public', 'rooms', 'draw_token', 'rooms has no token column');
select hasnt_column('public', 'turns', 'draw_token', 'turns has no token column');
select hasnt_column('public', 'players', 'draw_token', 'players has no token column');
select row_eq(
  $$ select count(*)::int, bool_and(pronargs = 1 and pronargdefaults = 0)
       from pg_proc where proname in ('got_it', 'skip_slip') and pronamespace = 'public'::regnamespace $$,
  row(2, true), 'got_it and skip_slip each exist once, with one required argument and no default');
select ok(
  (select bool_and(has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute'))
     from pg_proc p where p.proname in ('got_it', 'skip_slip') and p.pronamespace = 'public'::regnamespace),
  'and are callable by signed-in users only');

-- The deadline is judged when the request runs, not when its transaction began (review finding 5) --------------
update public.rooms set turn_ends_at = clock_timestamp() + interval '0.3 seconds';
select pg_sleep(0.6);
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.got_it(pg_temp.tok()) $$, 'P0001', 'turn_over', 'got_it that runs after expiry is rejected even in an older transaction');
select throws_ok($$ select public.skip_slip(pg_temp.tok()) $$, 'P0001', 'turn_over', 'and so is skip_slip');
select is(public.current_slip(), null, 'current_slip returns nothing after expiry');
select lives_ok($$ select public.end_turn() $$, 'end_turn is accepted once the real clock has passed the deadline');
select pg_temp.act_admin();
select ok((select ended_at >= now() + interval '0.5 seconds' from public.turns order by id desc limit 1), 'the history row records when the turn actually ended');

select * from finish();

rollback;
