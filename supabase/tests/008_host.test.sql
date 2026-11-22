-- Task 1.8: transfer_host, kick_player, claim_host, assign_spectator, delete_my_data.
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

-- A bearer token as the API would present it, without making sure the account still exists.
create function pg_temp.act_token(u uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
grant execute on function pg_temp.act_token(uuid) to public;

create function pg_temp.act_admin() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end $$;
grant execute on function pg_temp.act_admin() to public;

-- Four players P1..P4 on users base+1..base+4 (P1, P2 team 0; P3, P4 team 1), one slip each, P1 hosts.
-- n_submit players submit, in seat order. With n_submit = 0 the room is left in the lobby.
create function pg_temp.new_game(base int, n_submit int) returns void language plpgsql as $$
declare
  v_code text;
begin
  perform pg_temp.act_as(pg_temp.u(base + 1));
  v_code := public.create_room('P1') -> 'room' ->> 'code';
  for i in 2..4 loop
    perform pg_temp.act_as(pg_temp.u(base + i));
    perform public.join_room(v_code, 'P' || i);
  end loop;
  if n_submit = 0 then
    return;
  end if;
  perform pg_temp.act_as(pg_temp.u(base + 1));
  perform public.set_teams(jsonb_build_object(
    pg_temp.u(base + 1)::text, 0, pg_temp.u(base + 2)::text, 0,
    pg_temp.u(base + 3)::text, 1, pg_temp.u(base + 4)::text, 1));
  perform public.update_settings('{"slips_per_player": 1}'::jsonb);
  perform public.start_game();
  for i in 1..n_submit loop
    perform pg_temp.act_as(pg_temp.u(base + i));
    perform public.submit_slips(array['S' || i]);
  end loop;
end $$;
grant execute on function pg_temp.new_game(int, int) to public;

-- Six players P1..P6 on users base+1..base+6: P1-P3 team 0, P4-P6 team 1. One slip each, P1 hosts, round 1 running.
create function pg_temp.new_game6(base int) returns void language plpgsql as $$
declare
  v_code text;
begin
  perform pg_temp.act_as(pg_temp.u(base + 1));
  v_code := public.create_room('P1') -> 'room' ->> 'code';
  for i in 2..6 loop
    perform pg_temp.act_as(pg_temp.u(base + i));
    perform public.join_room(v_code, 'P' || i);
  end loop;
  perform pg_temp.act_as(pg_temp.u(base + 1));
  perform public.set_teams(jsonb_build_object(
    pg_temp.u(base + 1)::text, 0, pg_temp.u(base + 2)::text, 0, pg_temp.u(base + 3)::text, 0,
    pg_temp.u(base + 4)::text, 1, pg_temp.u(base + 5)::text, 1, pg_temp.u(base + 6)::text, 1));
  perform public.update_settings('{"slips_per_player": 1}'::jsonb);
  perform public.start_game();
  for i in 1..6 loop
    perform pg_temp.act_as(pg_temp.u(base + i));
    perform public.submit_slips(array['S' || i]);
  end loop;
end $$;
grant execute on function pg_temp.new_game6(int) to public;

create function pg_temp.room_of(p_user uuid) returns uuid language sql security definer as $$
  select room_id from public.players where user_id = p_user
$$;
grant execute on function pg_temp.room_of(uuid) to public;

create function pg_temp.code_of(p_user uuid) returns text language sql security definer as $$
  select r.code from public.rooms r join public.players p on p.room_id = r.id where p.user_id = p_user
$$;
grant execute on function pg_temp.code_of(uuid) to public;

-- Start the turn, score n slips, and optionally let the clock run out and end it.
create function pg_temp.play_turn(p_user uuid, n int, expire boolean) returns void language plpgsql as $$
begin
  perform pg_temp.act_as(p_user);
  perform pg_temp.keep(public.start_turn());
  for i in 1..n loop
    perform pg_temp.keep(public.got_it(pg_temp.tok()));
  end loop;
  if expire then
    perform pg_temp.act_admin();
    update public.rooms set turn_ends_at = now() - interval '1 second' where id = pg_temp.room_of(p_user);
    perform pg_temp.act_as(p_user);
    perform public.end_turn();
  end if;
end $$;
grant execute on function pg_temp.play_turn(uuid, int, boolean) to public;

create temp table ctx (k text primary key, v text);
grant all on ctx to public;

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

select plan(70);

-- A. Lobby room, users 1-4 ---------------------------------------------------------------------------------
select pg_temp.new_game(0, 0);

select pg_temp.act_as(pg_temp.u(2));
select throws_ok(format($$ select public.transfer_host(%L) $$, pg_temp.u(3)), 'P0001', 'not_host', 'transfer_host rejects a non-host');
select throws_ok(format($$ select public.kick_player(%L) $$, pg_temp.u(3)), 'P0001', 'not_host', 'kick_player rejects a non-host');

select pg_temp.act_as(pg_temp.u(1));
select throws_ok(format($$ select public.transfer_host(%L) $$, pg_temp.u(1)), 'P0001', 'cannot_target_self', 'cannot transfer the host role to yourself');
select throws_ok(format($$ select public.transfer_host(%L) $$, pg_temp.u(99)), 'P0001', 'player_not_found', 'transfer_host to a stranger rejected');
select throws_ok(format($$ select public.kick_player(%L) $$, pg_temp.u(1)), 'P0001', 'cannot_target_self', 'cannot kick yourself');
select throws_ok(format($$ select public.kick_player(%L) $$, pg_temp.u(99)), 'P0001', 'player_not_found', 'kick_player on a stranger rejected');

select public.transfer_host(pg_temp.u(2));
select pg_temp.act_admin();
select is((select host_id from public.rooms where id = pg_temp.room_of(pg_temp.u(1))), pg_temp.u(2), 'transfer_host hands over the room');
select pg_temp.act_as(pg_temp.u(1));
select throws_ok(format($$ select public.kick_player(%L) $$, pg_temp.u(3)), 'P0001', 'not_host', 'the old host lost their powers');

select pg_temp.act_as(pg_temp.u(2));
select public.kick_player(pg_temp.u(4));
select pg_temp.act_admin();
select is((select count(*)::int from public.players where user_id = pg_temp.u(4)), 0, 'kick_player removes the player');
select pg_temp.act_as(pg_temp.u(4));
select throws_ok(format($$ select public.get_snapshot(%L) $$, pg_temp.room_of(pg_temp.u(1))), 'P0001', 'not_member', 'a kicked player is no longer a member');

-- B. Kicking during submission, users 21-24 ----------------------------------------------------------------------
select pg_temp.new_game(20, 2);
select pg_temp.act_as(pg_temp.u(21));
select public.kick_player(pg_temp.u(22));
select pg_temp.act_admin();
select is(
  (select array_agg(name) from public.slips), array['S1'], 'kicking during submitting removes that player''s slips');
select is((select phase from public.rooms where id = pg_temp.room_of(pg_temp.u(21))), 'submitting', 'the room keeps waiting for the others');

-- Once everyone left standing has submitted, the game starts.
select pg_temp.new_game(60, 3);
select pg_temp.act_as(pg_temp.u(61));
select public.kick_player(pg_temp.u(64));
select pg_temp.act_admin();
select row_eq(
  $$ select phase, round, pile_count from public.rooms where id = pg_temp.room_of(pg_temp.u(61)) $$,
  row('playing'::text, 1::smallint, 3), 'kicking the last player who had not submitted starts round 1');

-- C. Kicking in play, users 31-34 ---------------------------------------------------------------------------------------
select pg_temp.new_game(30, 4);
select pg_temp.play_turn(pg_temp.u(31), 0, true);
select pg_temp.act_admin();
select is((select turn_player_id from public.rooms where id = pg_temp.room_of(pg_temp.u(31))), pg_temp.u(33), 'setup: Cy is up');
select pg_temp.play_turn(pg_temp.u(33), 1, false);
select pg_temp.act_as(pg_temp.u(31));
select public.kick_player(pg_temp.u(33));
select pg_temp.act_admin();
select row_eq(
  $$ select count(*)::int, max(player_name), max(cardinality(guessed)) from public.turns where player_id = pg_temp.u(33) $$,
  row(1, 'P3'::text, 1), 'kicking the clue-giver closes their turn and keeps what they scored');
select row_eq(
  $$ select current_team, turn_player_id, turn_ends_at, pile_count, turn_got from public.rooms where id = pg_temp.room_of(pg_temp.u(31)) $$,
  row(0::smallint, pg_temp.u(32), null::timestamptz, 3, 0),
  'and the turn passes to the other team''s next player; the pile is intact');
select row_eq(
  $$ select count(*)::int, count(*) filter (where author_id is null)::int, count(*) filter (where is_current)::int
       from public.slips where room_id = pg_temp.room_of(pg_temp.u(31)) $$,
  row(4, 1, 0), 'the kicked player''s slips stay in the game, anonymised, and nothing is left current');

select is(
  (select count(*)::int from public.slips where draw_token is not null and room_id = pg_temp.room_of(pg_temp.u(31))), 0,
  'removing the clue-giver mid-turn leaves no draw token behind');

-- Kicking the player who is up but has not started re-picks the turn.
select pg_temp.act_as(pg_temp.u(31));
select public.kick_player(pg_temp.u(32));
select pg_temp.act_admin();
select is(
  (select turn_player_id from public.rooms where id = pg_temp.room_of(pg_temp.u(31))), null,
  'with one player left on each team nobody can guess, so nobody is up');

-- The host leaving mid-turn: the turn is closed and the host role moves on.
select pg_temp.new_game(40, 4);
select pg_temp.act_as(pg_temp.u(41));
select pg_temp.keep(public.start_turn());
select pg_temp.keep(public.got_it(pg_temp.tok()));
select public.leave_room();
select pg_temp.act_admin();
select row_eq(
  $$ select host_id, current_team, turn_player_id, turn_ends_at from public.rooms where id = pg_temp.room_of(pg_temp.u(42)) $$,
  row(pg_temp.u(42), 1::smallint, pg_temp.u(43), null::timestamptz),
  'when the host leaves mid-turn the turn ends, the next seat hosts and the other team is up');
select is(
  (select cardinality(guessed) from public.turns where player_id = pg_temp.u(41)), 1, 'and their scored slip is in the history');

-- D. claim_host ---------------------------------------------------------------------------------------------------------
select pg_temp.new_game(70, 0);
select pg_temp.act_as(pg_temp.u(72));
select throws_ok($$ select public.claim_host() $$, 'P0001', 'host_still_active', 'claim_host rejected while the host is fresh');
select pg_temp.act_admin();
update public.players set last_seen_at = now() - interval '40 seconds' where user_id = pg_temp.u(71);
select pg_temp.act_as(pg_temp.u(72));
select throws_ok($$ select public.claim_host() $$, 'P0001', 'host_still_active', 'still rejected at 40 seconds');
select pg_temp.act_admin();
update public.players set last_seen_at = now() - interval '60 seconds' where user_id = pg_temp.u(71);
select pg_temp.act_as(pg_temp.u(99));
select throws_ok($$ select public.claim_host() $$, 'P0001', 'not_member', 'a stranger cannot claim the host role');
select pg_temp.act_as(pg_temp.u(71));
select throws_ok($$ select public.claim_host() $$, 'P0001', 'already_host', 'the host cannot claim their own role');
select pg_temp.act_as(pg_temp.u(72));
select public.claim_host();
select pg_temp.act_admin();
select is((select host_id from public.rooms where id = pg_temp.room_of(pg_temp.u(72))), pg_temp.u(72), 'claim_host is accepted once the host is stale');

-- E. assign_spectator, users 51-54 plus late joiner 55 ----------------------------------------------------------------------
select pg_temp.new_game(50, 4);
select pg_temp.act_as(pg_temp.u(55));
select public.join_room(pg_temp.code_of(pg_temp.u(51)), 'Late');
select pg_temp.act_admin();
select is((select role from public.players where user_id = pg_temp.u(55)), 'spectator', 'setup: the late joiner is a spectator');

select pg_temp.act_as(pg_temp.u(52));
select throws_ok(format($$ select public.assign_spectator(%L, 1) $$, pg_temp.u(55)), 'P0001', 'not_host', 'assign_spectator rejects a non-host');
select pg_temp.act_as(pg_temp.u(51));
select throws_ok(format($$ select public.assign_spectator(%L, 2) $$, pg_temp.u(55)), 'P0001', 'invalid_team', 'assign_spectator rejects a bad team');
select throws_ok(format($$ select public.assign_spectator(%L, 1) $$, pg_temp.u(52)), 'P0001', 'not_spectator', 'assign_spectator rejects someone who is already a player');
select throws_ok(format($$ select public.assign_spectator(%L, 1) $$, pg_temp.u(99)), 'P0001', 'player_not_found', 'assign_spectator rejects a stranger');

select pg_temp.keep(public.start_turn());
select throws_ok(format($$ select public.assign_spectator(%L, 1) $$, pg_temp.u(55)), 'P0001', 'turn_active', 'assign_spectator rejected while a turn is running');

select pg_temp.act_admin();
update public.rooms set turn_ends_at = now() - interval '1 second' where id = pg_temp.room_of(pg_temp.u(51));
select pg_temp.act_as(pg_temp.u(51));
select public.end_turn();
select public.assign_spectator(pg_temp.u(55), 1);
select pg_temp.act_admin();
select row_eq(
  $$ select role, team from public.players where user_id = pg_temp.u(55) $$,
  row('player'::text, 1::smallint), 'between turns the spectator joins the chosen team');
select is(
  (select turn_player_id from public.rooms where id = pg_temp.room_of(pg_temp.u(51))), pg_temp.u(53),
  'and the player who is up is unchanged');

-- F. delete_my_data -------------------------------------------------------------------------------------------------------------

select pg_temp.new_game(80, 2);
select pg_temp.act_as(pg_temp.u(82));
select public.delete_my_data();
select pg_temp.act_admin();
select is((select count(*)::int from public.players where user_id = pg_temp.u(82)), 0, 'delete_my_data removes the player');
select is((select count(*)::int from public.slips where room_id = pg_temp.room_of(pg_temp.u(81))), 1, 'and their slips while the room is still collecting them');
select is((select count(*)::int from auth.users where id = pg_temp.u(82)), 0, 'and the anonymous account');

-- The host deleting their data mid-game: slips stay (anonymous), the host role moves on.
select pg_temp.new_game(90, 4);
select pg_temp.act_as(pg_temp.u(91));
select public.delete_my_data();
select pg_temp.act_admin();
select row_eq(
  $$ select host_id from public.rooms where id = pg_temp.room_of(pg_temp.u(92)) $$,
  row(pg_temp.u(92)), 'the host role moves on to the next seat');
select is(
  (select count(*)::int from public.slips where room_id = pg_temp.room_of(pg_temp.u(92)) and author_id = pg_temp.u(91)), 0,
  'no slip is attributed to the deleted user');
select is((select count(*)::int from public.slips where room_id = pg_temp.room_of(pg_temp.u(92))), 4, 'but the pile is intact');

select pg_temp.act_as(pg_temp.u(91));
select lives_ok($$ select public.delete_my_data() $$, 'delete_my_data is safe to repeat');

-- H. Deleting a player keeps the scores but not the name (review finding 9) -------------------------------------------------
select pg_temp.new_game(120, 4);
select pg_temp.play_turn(pg_temp.u(121), 1, true);
select pg_temp.act_as(pg_temp.u(123));
select pg_temp.keep(public.start_turn());
select pg_temp.keep(public.got_it(pg_temp.tok()));
select public.delete_my_data();   -- during their own running turn
select pg_temp.act_admin();
select row_eq(
  $$ select count(*) filter (where player_id is null and player_name = 'Former player')::int,
            count(*) filter (where player_name = 'P1')::int,
            count(*) filter (where player_id = pg_temp.u(123) or player_name = 'P3')::int
       from public.turns where room_id = pg_temp.room_of(pg_temp.u(122)) $$,
  row(1, 1, 0), 'a turn closed by deleting the player is anonymised; other history is untouched');
select is(
  (select max(cardinality(guessed)) from public.turns where player_id is null and room_id = pg_temp.room_of(pg_temp.u(122))), 1, 'and keeps what they scored');
select pg_temp.act_as(pg_temp.u(121));
select public.delete_my_data();
select pg_temp.act_admin();
select row_eq(
  $$ select count(*) filter (where player_id is null and player_name = 'Former player')::int, count(*)::int
       from public.turns where room_id = pg_temp.room_of(pg_temp.u(122)) $$,
  row(2, 2), 'after a completed turn''s player deletes too, no turn names anyone');
select is(
  (select scores -> 0 from public.rooms where id = pg_temp.room_of(pg_temp.u(122))), '[1,1]'::jsonb, 'scores are unchanged');
select is(
  (select count(*)::int from public.room_creations where user_id = pg_temp.u(121)), 0, 'delete_my_data clears the room-creation log for that user');

-- I. Rotation survives people leaving (review finding 8) -------------------------------------------------------------------
-- Mid-round: Ann (first of three) has played and leaves; the next turn for that team is Bob, not Cy.
select pg_temp.new_game6(130);
select pg_temp.play_turn(pg_temp.u(131), 0, true);
select pg_temp.act_as(pg_temp.u(131));
select public.transfer_host(pg_temp.u(134));
select pg_temp.act_as(pg_temp.u(134));
select public.kick_player(pg_temp.u(131));
select pg_temp.play_turn(pg_temp.u(134), 0, true);
select pg_temp.act_admin();
select row_eq(
  $$ select current_team, turn_player_id from public.rooms where id = pg_temp.room_of(pg_temp.u(132)) $$,
  row(0::smallint, pg_temp.u(132)),
  'after the first of three leaves, the next clue-giver on that team is the second, not the third');

-- Across a round boundary: the same, with the removal between rounds.
select pg_temp.new_game6(140);
select pg_temp.play_turn(pg_temp.u(141), 6, false);
select pg_temp.act_admin();
select is((select phase from public.rooms where id = pg_temp.room_of(pg_temp.u(142))), 'round_end', 'setup: round 1 is over');
select pg_temp.act_as(pg_temp.u(141));
select public.transfer_host(pg_temp.u(144));
select pg_temp.act_as(pg_temp.u(144));
select public.kick_player(pg_temp.u(141));
select public.start_next_round();
select pg_temp.play_turn(pg_temp.u(144), 0, true);
select pg_temp.act_admin();
select row_eq(
  $$ select round, current_team, turn_player_id from public.rooms where id = pg_temp.room_of(pg_temp.u(142)) $$,
  row(2::smallint, 0::smallint, pg_temp.u(142)),
  'a removal between rounds does not skip anyone either');

-- A team with nobody left passes its turn to the other team.
select pg_temp.new_game(150, 4);
select pg_temp.play_turn(pg_temp.u(151), 0, true);
select pg_temp.act_as(pg_temp.u(151));
select public.kick_player(pg_temp.u(153));
select public.kick_player(pg_temp.u(154));
select pg_temp.act_admin();
select row_eq(
  $$ select current_team, turn_player_id from public.rooms where id = pg_temp.room_of(pg_temp.u(151)) $$,
  row(0::smallint, pg_temp.u(152)),
  'when the team that is up has nobody left, the other team takes the turn');

-- When neither team can play, nobody is up, and assign_spectator gets the game going again.
select pg_temp.act_as(pg_temp.u(151));
select public.kick_player(pg_temp.u(152));
select pg_temp.act_admin();
select is(
  (select turn_player_id from public.rooms where id = pg_temp.room_of(pg_temp.u(151))), null,
  'with neither team able to field a clue-giver and a guesser, turn_player_id is null');
select pg_temp.act_as(pg_temp.u(155));
select public.join_room(pg_temp.code_of(pg_temp.u(151)), 'S5');
select pg_temp.act_as(pg_temp.u(151));
select public.assign_spectator(pg_temp.u(155), 0);
select pg_temp.act_admin();
select row_eq(
  $$ select current_team, turn_player_id from public.rooms where id = pg_temp.room_of(pg_temp.u(151)) $$,
  row(0::smallint, pg_temp.u(151)),
  'assign_spectator recovers the game once a team can field a clue-giver and a guesser');

-- J. Promotion after the cursor has wrapped (review round 2, finding 6) --------------------------------------------------
select pg_temp.new_game(160, 4);
select pg_temp.play_turn(pg_temp.u(161), 0, true);
select pg_temp.play_turn(pg_temp.u(163), 0, true);
select pg_temp.play_turn(pg_temp.u(162), 0, true);
select pg_temp.play_turn(pg_temp.u(164), 0, true);
select pg_temp.act_admin();
select row_eq(
  $$ select current_team, turn_player_id, turn_idx[1] from public.rooms where id = pg_temp.room_of(pg_temp.u(161)) $$,
  row(0::smallint, pg_temp.u(161), 2), 'setup: the cursor has wrapped (stored 2 on a team of two) and Ann is up');
select pg_temp.act_as(pg_temp.u(165));
select public.join_room(pg_temp.code_of(pg_temp.u(161)), 'Late');
select pg_temp.act_as(pg_temp.u(161));
select public.assign_spectator(pg_temp.u(165), 0);
select pg_temp.act_admin();
select is(
  (select turn_player_id from public.rooms where id = pg_temp.room_of(pg_temp.u(161))), pg_temp.u(161),
  'appending a third player after a wrapped cursor does not make the newcomer next');

-- K. The host's age is judged at decision time, and heartbeats write real time (review round 2, finding 11) --------------
select pg_temp.new_game(170, 0);
select pg_temp.act_admin();
update public.players set last_seen_at = clock_timestamp() - interval '44.7 seconds' where user_id = pg_temp.u(171);
select pg_temp.act_as(pg_temp.u(172));
select throws_ok($$ select public.claim_host() $$, 'P0001', 'host_still_active', 'a host seen 44.7 seconds ago is still active');
select pg_sleep(0.5);
select lives_ok($$ select public.claim_host() $$, 'half a second later, in the same transaction, the host has crossed 45 seconds');
select pg_temp.act_admin();
select is((select host_id from public.rooms where id = pg_temp.room_of(pg_temp.u(172))), pg_temp.u(172), 'and the claim took effect');
select pg_sleep(0.3);
select pg_temp.act_as(pg_temp.u(173));
select public.heartbeat(pg_temp.room_of(pg_temp.u(173)));
select pg_temp.act_admin();
select ok(
  (select last_seen_at >= now() + interval '0.25 seconds' from public.players where user_id = pg_temp.u(173)),
  'a heartbeat records the wall-clock time, not the start of its transaction');

-- G. Account identity (review finding 3) ---------------------------------------------------------------------------------------
-- An anonymous account is deleted with its data, and the old token stops working.
select pg_temp.new_game(100, 0);
select pg_temp.act_as(pg_temp.u(102));
select public.delete_my_data();
select pg_temp.act_admin();
select is((select count(*)::int from auth.users where id = pg_temp.u(102)), 0, 'an anonymous account is deleted');
select pg_temp.act_token(pg_temp.u(102));
select throws_ok($$ select public.create_room('Ghost') $$, 'P0001', 'not_authenticated', 'the old token cannot create a room');
select throws_ok(format($$ select public.heartbeat(%L) $$, pg_temp.room_of(pg_temp.u(101))), 'P0001', 'not_authenticated', 'the old token cannot heartbeat');
select throws_ok($$ select * from public.suggest_celebrities('tom') $$, 'P0001', 'not_authenticated', 'the old token cannot ask for suggestions');

-- A permanent (non-anonymous) account loses its game data but keeps its login.
select pg_temp.act_admin();
insert into auth.users (id, aud, role, is_anonymous) values (pg_temp.u(111), 'authenticated', 'authenticated', false);
select pg_temp.new_game(110, 0);
select pg_temp.act_as(pg_temp.u(111));
select public.delete_my_data();
select pg_temp.act_admin();
select is((select count(*)::int from public.players where user_id = pg_temp.u(111)), 0, 'a permanent account''s game data is deleted');
select is((select count(*)::int from auth.users where id = pg_temp.u(111)), 1, 'but its account row is kept');
select is((select count(*)::int from public.room_creations where user_id = pg_temp.u(111)), 1, 'and so is its room-creation log, which cleanup_rooms prunes after the hour');
select pg_temp.act_token(pg_temp.u(111));
select lives_ok($$ select public.create_room('Back') $$, 'and it can keep playing');

-- An account removed behind the game's back is refused too.
select pg_temp.act_admin();
delete from auth.users where id = pg_temp.u(103);
select pg_temp.act_token(pg_temp.u(103));
select throws_ok(format($$ select public.get_snapshot(%L) $$, pg_temp.room_of(pg_temp.u(101))), 'P0001', 'not_authenticated', 'a token for a removed account cannot read a snapshot');
select throws_ok($$ select public.leave_room() $$, 'P0001', 'not_authenticated', 'nor leave a room');

-- Everything above is for signed-in users only ------------------------------------------------------------------------------------
select pg_temp.act_admin();
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('transfer_host', 'kick_player', 'claim_host', 'assign_spectator', 'delete_my_data')
      and has_function_privilege('anon', p.oid, 'execute')),
  0, 'anon cannot execute the host-management functions');
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like '\_%'
      and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))),
  0, 'internal helper functions are not callable by clients');

select * from finish();

rollback;
