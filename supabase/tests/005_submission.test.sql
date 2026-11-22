-- Task 1.5: submit_slips, retract_slips, close_submissions.
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

select plan(33);

-- Room 1: Ann (host), Bob | Cy, Di, plus Ed who ends up a spectator. Two slips each. ------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
insert into ctx values ('code1', public.create_room('Ann') -> 'room' ->> 'code');
select pg_temp.act_as('00000000-0000-0000-0000-000000000002');
select public.join_room((select v from ctx where k = 'code1'), 'Bob');
select pg_temp.act_as('00000000-0000-0000-0000-000000000003');
select public.join_room((select v from ctx where k = 'code1'), 'Cy');
select pg_temp.act_as('00000000-0000-0000-0000-000000000004');
select public.join_room((select v from ctx where k = 'code1'), 'Di');
select pg_temp.act_as('00000000-0000-0000-0000-000000000005');
select public.join_room((select v from ctx where k = 'code1'), 'Ed');

select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select public.set_teams(
  '{"00000000-0000-0000-0000-000000000001": 0, "00000000-0000-0000-0000-000000000002": 0,
    "00000000-0000-0000-0000-000000000003": 1, "00000000-0000-0000-0000-000000000004": 1}'::jsonb);
select public.update_settings('{"slips_per_player": 2}'::jsonb);

-- Submitting before the game starts is rejected.
select pg_temp.act_as('00000000-0000-0000-0000-000000000002');
select throws_ok($$ select public.submit_slips(array['A', 'B']) $$, 'P0001', 'wrong_phase', 'submit_slips in the lobby rejected');
select throws_ok($$ select public.close_submissions() $$, 'P0001', 'wrong_phase', 'close_submissions in the lobby rejected');

select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select public.start_game();

-- submit_slips ------------------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.submit_slips(array['Only one']) $$, 'P0001', 'wrong_slip_count', 'too few slips rejected');
select throws_ok($$ select public.submit_slips(array['A', 'B', 'C']) $$, 'P0001', 'wrong_slip_count', 'too many slips rejected');
select throws_ok($$ select public.submit_slips(array['A', '  ']) $$, 'P0001', 'invalid_slip', 'blank slip rejected');
select throws_ok($$ select public.submit_slips(array['A', repeat('x', 61)]) $$, 'P0001', 'invalid_slip', 'slip over 60 chars rejected');
select throws_ok($$ select public.submit_slips(null) $$, 'P0001', 'wrong_slip_count', 'null array rejected');

select pg_temp.act_as('00000000-0000-0000-0000-000000000005');
select throws_ok($$ select public.submit_slips(array['A', 'B']) $$, 'P0001', 'not_a_player', 'spectator cannot submit');

select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select public.submit_slips(array['Madonna', ' Madonna ']);
select pg_temp.act_admin();
select is(
  (select array_agg(name order by name) from public.slips where author_id = '00000000-0000-0000-0000-000000000001'),
  array['Madonna', 'Madonna'], 'two identical names are kept as two slips, trimmed');
select ok(
  (select submitted from public.players where user_id = '00000000-0000-0000-0000-000000000001'),
  'submitting marks the player as submitted');
select is(
  (select count(*)::int from public.slips where in_pile), 0, 'slips are not in the pile until round 1 starts');

select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.submit_slips(array['A', 'B']) $$, 'P0001', 'already_submitted', 'submitting twice rejected');

-- retract_slips -------------------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000002');
select public.submit_slips(array['Bowie', 'Prince']);
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select public.retract_slips();
select pg_temp.act_admin();
select is(
  (select array_agg(name order by name) from public.slips), array['Bowie', 'Prince'],
  'retract removes only that player''s slips');
select ok(
  not (select submitted from public.players where user_id = '00000000-0000-0000-0000-000000000001'),
  'retract clears the submitted flag');
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select lives_ok($$ select public.retract_slips() $$, 'retracting with nothing submitted is a no-op');
select public.submit_slips(array['Cher', 'Elvis']);

-- The last submission starts round 1 --------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000003');
select public.submit_slips(array['Oprah', 'Ringo']);
select pg_temp.act_admin();
select is((select phase from public.rooms where code = (select v from ctx where k = 'code1')), 'submitting', 'still submitting while one player has not submitted');
select pg_temp.act_as('00000000-0000-0000-0000-000000000004');
select public.submit_slips(array['Yoko', 'Zendaya']);
select pg_temp.act_admin();
select row_eq(
  $$ select phase, round, pile_count, current_team, turn_player_id, turn_ends_at
       from public.rooms where code = (select v from ctx where k = 'code1') $$,
  row('playing'::text, 1::smallint, 8, 0::smallint, '00000000-0000-0000-0000-000000000001'::uuid, null::timestamptz),
  'the last submission starts round 1 with every slip in the pile; team 0 and its first seat are up');
select is((select count(*)::int from public.slips where in_pile and not is_current and pile_order is not null), 8, 'every slip is in the pile with a shuffle order');

select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.submit_slips(array['A', 'B']) $$, 'P0001', 'wrong_phase', 'submit_slips after the game starts rejected');
select throws_ok($$ select public.retract_slips() $$, 'P0001', 'wrong_phase', 'retract_slips after the game starts rejected');

-- Room 2: close_submissions --------------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000011');
insert into ctx values ('code2', public.create_room('Hal') -> 'room' ->> 'code');
select pg_temp.act_as('00000000-0000-0000-0000-000000000012');
select public.join_room((select v from ctx where k = 'code2'), 'Ivy');
select pg_temp.act_as('00000000-0000-0000-0000-000000000013');
select public.join_room((select v from ctx where k = 'code2'), 'Jo');
select pg_temp.act_as('00000000-0000-0000-0000-000000000014');
select public.join_room((select v from ctx where k = 'code2'), 'Kim');
select pg_temp.act_as('00000000-0000-0000-0000-000000000011');
select public.set_teams(
  '{"00000000-0000-0000-0000-000000000011": 0, "00000000-0000-0000-0000-000000000012": 0,
    "00000000-0000-0000-0000-000000000013": 1, "00000000-0000-0000-0000-000000000014": 1}'::jsonb);
select public.start_game();

select pg_temp.act_as('00000000-0000-0000-0000-000000000012');
select throws_ok($$ select public.close_submissions() $$, 'P0001', 'deadline_not_reached', 'close before the deadline rejected');

select pg_temp.act_admin();
update public.rooms set submission_deadline = now() - interval '1 second' where code = (select v from ctx where k = 'code2');
select pg_temp.act_as('00000000-0000-0000-0000-000000000012');
select throws_ok($$ select public.submit_slips(array['Late', 'Later', 'Latest']) $$, 'P0001', 'submissions_closed', 'submitting after the deadline rejected');

-- An expired window with no slips at all would strand the room, so closing it sends everyone back to the lobby.
select public.close_submissions();
select pg_temp.act_admin();
select row_eq(
  $$ select phase, submission_deadline, round from public.rooms where code = (select v from ctx where k = 'code2') $$,
  row('lobby'::text, null::timestamptz, 0::smallint), 'closing an expired window with zero slips returns the room to the lobby');
select is(
  (select count(*)::int from public.players where submitted and room_id = (select id from public.rooms where code = (select v from ctx where k = 'code2'))),
  0, 'and no one is marked as submitted');
select pg_temp.act_as('00000000-0000-0000-0000-000000000012');
select throws_ok($$ select public.close_submissions() $$, 'P0001', 'wrong_phase', 'close_submissions in the lobby is still rejected');

-- The host starts again with a fresh window.
select pg_temp.act_as('00000000-0000-0000-0000-000000000011');
select public.start_game();

select pg_temp.act_as('00000000-0000-0000-0000-000000000099');
select throws_ok($$ select public.close_submissions() $$, 'P0001', 'not_member', 'non-member cannot close submissions');

select pg_temp.act_as('00000000-0000-0000-0000-000000000011');
select public.submit_slips(array['Dolly', 'Tina', 'Cher']);
select pg_temp.act_admin();
update public.rooms set submission_deadline = now() - interval '1 second' where code = (select v from ctx where k = 'code2');
select pg_temp.act_as('00000000-0000-0000-0000-000000000011');
select throws_ok($$ select public.retract_slips() $$, 'P0001', 'submissions_closed', 'retracting after the deadline rejected');
select pg_temp.act_as('00000000-0000-0000-0000-000000000014');
select public.close_submissions();
select pg_temp.act_admin();
select row_eq(
  $$ select phase, round, pile_count, current_team, turn_player_id
       from public.rooms where code = (select v from ctx where k = 'code2') $$,
  row('playing'::text, 1::smallint, 3, 0::smallint, '00000000-0000-0000-0000-000000000011'::uuid),
  'closing after the deadline starts round 1 with only the slips received');
select is(
  (select count(*)::int from public.players where room_id = (select id from public.rooms where code = (select v from ctx where k = 'code2')) and role = 'player'),
  4, 'players who never submitted still play');
select pg_temp.act_as('00000000-0000-0000-0000-000000000014');
select lives_ok($$ select public.close_submissions() $$, 'closing twice is harmless');
select pg_temp.act_admin();
select row_eq(
  $$ select phase, round, pile_count from public.rooms where code = (select v from ctx where k = 'code2') $$,
  row('playing'::text, 1::smallint, 3), 'and changes nothing');

-- Anonymous callers are locked out of everything above -------------------------------------------------------
select pg_temp.act_admin();
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('submit_slips', 'retract_slips', 'close_submissions')
      and has_function_privilege('anon', p.oid, 'execute')),
  0, 'anon cannot execute the submission functions');
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('submit_slips', 'retract_slips', 'close_submissions')
      and has_function_privilege('authenticated', p.oid, 'execute')),
  3, 'authenticated can execute the submission functions');

select * from finish();

rollback;
