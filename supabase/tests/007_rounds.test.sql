-- Task 1.7: round end, game end, start_next_round, reset_room.
begin;

create extension if not exists pgtap with schema extensions;

create function pg_temp.u(n int) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
$$;
grant execute on function pg_temp.u(int) to public;

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

-- Four players P1..P4 on users base+1..base+4; P1, P2 on team 0 and P3, P4 on team 1.
-- One slip each, so a round has 4 slips. P1 hosts. Leaves the game in round 1, P1 up.
create function pg_temp.new_game(base int) returns void language plpgsql as $$
declare
  v_code text;
begin
  perform pg_temp.act_as(pg_temp.u(base + 1));
  v_code := public.create_room('P1') -> 'room' ->> 'code';
  for i in 2..4 loop
    perform pg_temp.act_as(pg_temp.u(base + i));
    perform public.join_room(v_code, 'P' || i);
  end loop;
  perform pg_temp.act_as(pg_temp.u(base + 1));
  perform public.set_teams(jsonb_build_object(
    pg_temp.u(base + 1)::text, 0, pg_temp.u(base + 2)::text, 0,
    pg_temp.u(base + 3)::text, 1, pg_temp.u(base + 4)::text, 1));
  perform public.update_settings('{"slips_per_player": 1}'::jsonb);
  perform public.start_game();
  for i in 1..4 loop
    perform pg_temp.act_as(pg_temp.u(base + i));
    perform public.submit_slips(array['S' || i]);
  end loop;
end $$;
grant execute on function pg_temp.new_game(int) to public;

-- The player starts their turn and scores n slips; with expire, the clock then runs out and they end it.
create function pg_temp.play_turn(p_user uuid, n int, expire boolean) returns void language plpgsql as $$
begin
  perform pg_temp.act_as(p_user);
  perform pg_temp.keep(public.start_turn());
  for i in 1..n loop
    perform pg_temp.keep(public.got_it(pg_temp.tok()));
  end loop;
  if expire then
    perform pg_temp.act_admin();
    update public.rooms set turn_ends_at = now() - interval '1 second'
     where id = (select room_id from public.players where user_id = p_user);
    perform pg_temp.act_as(p_user);
    perform public.end_turn();
  end if;
end $$;
grant execute on function pg_temp.play_turn(uuid, int, boolean) to public;

create function pg_temp.room_of(p_user uuid) returns uuid language sql security definer as $$
  select room_id from public.players where user_id = p_user
$$;
grant execute on function pg_temp.room_of(uuid) to public;

-- Token bookkeeping the way a client does it: remember the token from every RPC response, and send
-- the remembered one with the next action. (Nothing here reads the slips table.)
create function pg_temp.keep(j jsonb) returns jsonb language plpgsql as $$
begin
  insert into ctx (k, v) values ('tok', j ->> 'token') on conflict (k) do update set v = excluded.v;
  return j;
end $$;
grant execute on function pg_temp.keep(jsonb) to public;

create function pg_temp.tok() returns uuid language plpgsql as $$
declare
  v_tok uuid;
begin
  select c.v::uuid into v_tok from ctx c where c.k = 'tok';
  return v_tok;
end $$;
grant execute on function pg_temp.tok() to public;

create temp table ctx (k text primary key, v text);
grant all on ctx to public;

select plan(40);

-- Game 1: users 1-4 ------------------------------------------------------------------------------------
select pg_temp.new_game(0);
select pg_temp.act_as(pg_temp.u(1));
select throws_ok($$ select public.start_next_round() $$, 'P0001', 'wrong_phase', 'start_next_round during play is rejected');
select throws_ok($$ select public.reset_room() $$, 'P0001', 'wrong_phase', 'reset_room during play is rejected');

-- Emptying the pile ends round 1 ------------------------------------------------------------------------------
select pg_temp.play_turn(pg_temp.u(1), 3, false);
select pg_temp.act_admin();
select is((select pile_count from public.rooms where id = (select room_id from public.players where user_id = pg_temp.u(1))), 1, 'setup: one slip left');
select pg_temp.act_as(pg_temp.u(1));
select is(pg_temp.keep(public.got_it(pg_temp.tok())), null, 'got_it returns null when the pile is empty');
select pg_temp.act_admin();
select row_eq(
  $$ select phase, round, pile_count, turn_player_id, turn_ends_at, turn_got
       from public.rooms where id = (select room_id from public.players where user_id = pg_temp.u(1)) $$,
  row('round_end'::text, 1::smallint, 0, null::uuid, null::timestamptz, 0),
  'emptying the pile moves the room to round_end');
select is((select scores -> 0 from public.rooms where id = (select room_id from public.players where user_id = pg_temp.u(1))), '[4,0]'::jsonb, 'round 1 score is recorded');
select row_eq(
  $$ select count(*)::int, max(cardinality(guessed)) from public.turns $$,
  row(1, 4), 'the turn that emptied the pile is in the history with all four names');
select is((select count(*)::int from public.slips where is_current or draw_token is not null), 0, 'no slip is left current and no draw token is left behind');

select pg_temp.act_as(pg_temp.u(1));
select throws_ok($$ select pg_temp.keep(public.start_turn()) $$, 'P0001', 'wrong_phase', 'no turns between rounds');
select lives_ok($$ select public.end_turn() $$, 'end_turn between rounds is a no-op');

-- start_next_round -----------------------------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.u(2));
select throws_ok($$ select public.start_next_round() $$, 'P0001', 'not_host', 'only the host starts the next round');
select pg_temp.act_as(pg_temp.u(1));
select public.start_next_round();
select pg_temp.act_admin();
select is((select count(*)::int from public.slips where draw_token is not null), 0, 'starting a round clears every draw token');
select row_eq(
  $$ select phase, round, pile_count, current_team, turn_player_id
       from public.rooms where id = (select room_id from public.players where user_id = pg_temp.u(1)) $$,
  row('playing'::text, 2::smallint, 4, 1::smallint, pg_temp.u(3)),
  'round 2: pile refilled with every slip, the other team starts, rotation continues');
select is((select count(*)::int from public.slips where in_pile and not is_current and pile_order is not null), 4, 'all four slips are back in the pile');

-- Round 2: Cy scores two and runs out of time; Bob finishes the pile. -------------------------------------------------
select pg_temp.play_turn(pg_temp.u(3), 2, true);
select pg_temp.act_admin();
select is((select turn_player_id from public.rooms where id = (select room_id from public.players where user_id = pg_temp.u(1))), pg_temp.u(2), 'after Cy the other team''s next player, Bob, is up');
select pg_temp.play_turn(pg_temp.u(2), 2, false);
select pg_temp.act_admin();
select row_eq(
  $$ select phase, round, scores -> 1 from public.rooms where id = (select room_id from public.players where user_id = pg_temp.u(1)) $$,
  row('round_end'::text, 2::smallint, '[2,2]'::jsonb), 'round 2 ends 2-2');

select pg_temp.act_as(pg_temp.u(1));
select public.start_next_round();
select pg_temp.act_admin();
select row_eq(
  $$ select phase, round, current_team, turn_player_id
       from public.rooms where id = (select room_id from public.players where user_id = pg_temp.u(1)) $$,
  row('playing'::text, 3::smallint, 0::smallint, pg_temp.u(1)),
  'round 3: team 0 starts again and the rotation has come back to Ann');

-- Round 3: Ann scores one and runs out of time; Di finishes. ------------------------------------------------------------
select pg_temp.play_turn(pg_temp.u(1), 1, true);
select pg_temp.act_admin();
select is((select turn_player_id from public.rooms where id = (select room_id from public.players where user_id = pg_temp.u(1))), pg_temp.u(4), 'after Ann comes Di');
select pg_temp.play_turn(pg_temp.u(4), 3, false);
select pg_temp.act_admin();
select row_eq(
  $$ select phase, round, pile_count, turn_player_id from public.rooms where id = (select room_id from public.players where user_id = pg_temp.u(1)) $$,
  row('finished'::text, 3::smallint, 0, null::uuid), 'emptying the pile in round 3 finishes the game');
select is((select count(*)::int from public.slips where draw_token is not null), 0, 'finishing the game leaves no draw token behind');
select is(
  (select scores from public.rooms where id = (select room_id from public.players where user_id = pg_temp.u(1))),
  '[[4,0],[2,2],[1,3]]'::jsonb, 'scores by round');
select is(
  (select array_agg((r ->> 0)::int + (r ->> 1)::int) from public.rooms, jsonb_array_elements(scores) r
    where id = (select room_id from public.players where user_id = pg_temp.u(1))),
  array[4, 4, 4], 'the score of every round adds up to the number of slips');
select row_eq(
  $$ select sum((r ->> 0)::int)::int, sum((r ->> 1)::int)::int
       from public.rooms, jsonb_array_elements(scores) r
      where id = (select room_id from public.players where user_id = pg_temp.u(1)) $$,
  row(7, 5), 'team 0 wins 7-5');
select is((select count(*)::int from public.turns), 5, 'five turns are in the history');
select is((select array_agg(round order by id) from public.turns), array[1, 2, 2, 3, 3]::smallint[], 'turns are tagged with their round');

-- The finish time is fixed when the game ends; later activity in the room does not move it (review finding 12).
insert into ctx values ('fin', (select finished_at::text from public.rooms where id = pg_temp.room_of(pg_temp.u(1))));
insert into ctx values ('code', (select code from public.rooms where id = pg_temp.room_of(pg_temp.u(1))));
select isnt((select v from ctx where k = 'fin'), null, 'finishing the game stamps finished_at');
select pg_temp.act_admin();
update public.rooms set finished_at = now() - interval '30 minutes' where id = pg_temp.room_of(pg_temp.u(1));
update ctx set v = (select finished_at::text from public.rooms where id = pg_temp.room_of(pg_temp.u(1))) where k = 'fin';
select pg_temp.act_as(pg_temp.u(5));
select public.join_room((select v from ctx where k = 'code'), 'Late');
select public.leave_room();
select pg_temp.act_admin();
select is(
  (select finished_at::text from public.rooms where id = pg_temp.room_of(pg_temp.u(1))), (select v from ctx where k = 'fin'),
  'joining and leaving after the game does not change finished_at');

select pg_temp.act_as(pg_temp.u(1));
select throws_ok($$ select public.start_next_round() $$, 'P0001', 'wrong_phase', 'no round 4');

-- reset_room ------------------------------------------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.u(2));
select throws_ok($$ select public.reset_room() $$, 'P0001', 'not_host', 'only the host resets the room');
select pg_temp.act_as(pg_temp.u(1));
select public.reset_room();
select pg_temp.act_admin();
select row_eq(
  $$ select phase, round, pile_count, scores, turn_idx, current_team, turn_player_id, turn_ends_at, turn_got, turn_skips
       from public.rooms where id = (select room_id from public.players where user_id = pg_temp.u(1)) $$,
  row('lobby'::text, 0::smallint, 0, '[[0,0],[0,0],[0,0]]'::jsonb, array[0, 0], null::smallint, null::uuid, null::timestamptz, 0, 0),
  'reset_room returns the room to a clean lobby');
select is(
  (select count(*)::int from public.slips) + (select count(*)::int from public.turns), 0, 'reset_room clears slips and history');
select is((select finished_at from public.rooms where id = pg_temp.room_of(pg_temp.u(1))), null, 'reset_room clears finished_at');
select row_eq(
  $$ select count(*)::int, count(*) filter (where team = 0)::int, count(*) filter (where team = 1)::int,
            count(*) filter (where role = 'player')::int, count(*) filter (where submitted)::int
       from public.players where room_id = (select room_id from public.players where user_id = pg_temp.u(1)) $$,
  row(4, 2, 2, 4, 0), 'reset_room keeps the players and their teams, and clears submitted');
select is(
  (select slips_per_player from public.rooms where id = (select room_id from public.players where user_id = pg_temp.u(1))), 1, 'reset_room keeps the settings');

-- A rematch works straight away.
select pg_temp.act_as(pg_temp.u(1));
select lives_ok($$ select public.start_game() $$, 'the host can start a rematch');
select pg_temp.act_admin();
select is((select phase from public.rooms where id = (select room_id from public.players where user_id = pg_temp.u(1))), 'submitting', 'and the rematch is in the submission phase');

-- Game 2: a tie. Users 11-14. -----------------------------------------------------------------------------------------------
select pg_temp.new_game(10);
select pg_temp.play_turn(pg_temp.u(11), 4, false);
select pg_temp.act_as(pg_temp.u(11));
select public.start_next_round();
select pg_temp.play_turn(pg_temp.u(13), 4, false);
select pg_temp.act_as(pg_temp.u(11));
select public.start_next_round();
select pg_temp.act_admin();
select is((select turn_player_id from public.rooms where id = (select room_id from public.players where user_id = pg_temp.u(11))), pg_temp.u(12), 'round 3 opens with Bob: the rotation moved on');
select pg_temp.play_turn(pg_temp.u(12), 2, true);
select pg_sleep(0.3);
select pg_temp.play_turn(pg_temp.u(14), 2, false);
select pg_temp.act_admin();
select ok(
  (select finished_at >= now() + interval '0.25 seconds' from public.rooms where id = pg_temp.room_of(pg_temp.u(11))),
  'finished_at is the moment the last slip was scored, not the start of the transaction');
select row_eq(
  $$ select phase, scores from public.rooms where id = (select room_id from public.players where user_id = pg_temp.u(11)) $$,
  row('finished'::text, '[[4,0],[0,4],[2,2]]'::jsonb), 'game 2 finishes');
select row_eq(
  $$ select sum((r ->> 0)::int)::int, sum((r ->> 1)::int)::int
       from public.rooms, jsonb_array_elements(scores) r
      where id = (select room_id from public.players where user_id = pg_temp.u(11)) $$,
  row(6, 6), 'the totals tie 6-6');

select * from finish();

rollback;
