-- Realtime: no Postgres Changes. Triggers send invalidation messages over private Broadcast on the
-- topic room:<room_id>. Payloads hold a room id and nothing else. Only current members of a room can
-- receive on its topic; nobody can send; a failing send can never break a game write.
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

-- What a client does when it joins a private channel: Realtime sets the topic, then the policy runs.
create function pg_temp.join_topic(p_topic text) returns void language sql as $$
  select set_config('realtime.topic', p_topic, true)
$$;
grant execute on function pg_temp.join_topic(text) to public;

create function pg_temp.room_of(p_user uuid) returns uuid language sql security definer as $$
  select room_id from public.players where user_id = p_user
$$;
grant execute on function pg_temp.room_of(uuid) to public;

-- How many messages a room's topic has, optionally for one event.
create function pg_temp.msgs(p_room uuid, p_event text default null) returns int language sql security definer as $$
  select count(*)::int from realtime.messages
   where topic = 'room:' || p_room and (p_event is null or event = p_event)
$$;
grant execute on function pg_temp.msgs(uuid, text) to public;

-- Client-side bookkeeping: every slip token the RPCs hand out, so leaks can be searched for.
create temp table ctx (k text primary key, v text);
grant all on ctx to public;
create temp table toks (t uuid);
grant all on toks to public;
create function pg_temp.note(j jsonb) returns jsonb language plpgsql as $$
begin
  if j ->> 'token' is not null then
    insert into toks values ((j ->> 'token')::uuid);
  end if;
  insert into ctx (k, v) values ('tok', j ->> 'token') on conflict (k) do update set v = excluded.v;
  return j;
end $$;
grant execute on function pg_temp.note(jsonb) to public;

select plan(48);

-- No Postgres Changes -------------------------------------------------------------------------------------------------
select is(
  (select count(*)::int from pg_publication_tables
    where pubname = 'supabase_realtime'
      and tablename in ('rooms', 'players', 'turns', 'slips', 'room_creations', 'celebrities')),
  0, 'no game table is in the supabase_realtime publication');

-- Room A: Ann (host), Bob | Cy, Di ----------------------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.u(1));
select public.create_room('Ann');
select pg_temp.act_admin();
insert into ctx values ('A', pg_temp.room_of(pg_temp.u(1))::text);
insert into ctx values ('codeA', (select code from public.rooms where id = pg_temp.room_of(pg_temp.u(1))));
select pg_temp.act_as(pg_temp.u(2));
select public.join_room((select v from ctx where k = 'codeA'), 'Bob');
select pg_temp.act_as(pg_temp.u(3));
select public.join_room((select v from ctx where k = 'codeA'), 'Cy');
select pg_temp.act_as(pg_temp.u(4));
select public.join_room((select v from ctx where k = 'codeA'), 'Di');

select pg_temp.act_admin();
select cmp_ok(pg_temp.msgs((select v::uuid from ctx where k = 'A'), 'players_changed'), '>=', 4, 'players joining send players_changed on the room topic');
select is(
  (select array_agg(distinct k order by k) from realtime.messages m, jsonb_object_keys(m.payload) k
    where m.topic = 'room:' || (select v from ctx where k = 'A') and k <> 'id'),
  array['room_id'], 'payloads carry only the room id (Realtime adds its own message id)');
select is(
  (select count(*)::int from realtime.messages
    where topic = 'room:' || (select v from ctx where k = 'A') and (payload ->> 'room_id')::uuid <> (select v::uuid from ctx where k = 'A')),
  0, 'and it is the room''s own id');
select is((select count(*)::int from realtime.messages where private is not true), 0, 'every message is private');
select is((select count(*)::int from realtime.messages where extension <> 'broadcast'), 0, 'and uses the broadcast extension');

-- One action, one message (the settings update must not be explained by earlier joins) -----------------------------------------
insert into ctx values ('before_all', pg_temp.msgs((select v::uuid from ctx where k = 'A'))::text);
insert into ctx values ('before_room', pg_temp.msgs((select v::uuid from ctx where k = 'A'), 'room_changed')::text);
select pg_temp.act_as(pg_temp.u(1));
select public.update_settings('{"slips_per_player": 1}'::jsonb);
select pg_temp.act_admin();
select is(
  pg_temp.msgs((select v::uuid from ctx where k = 'A'), 'room_changed') - (select v::int from ctx where k = 'before_room'),
  1, 'a settings update sends exactly one room_changed');
select is(
  pg_temp.msgs((select v::uuid from ctx where k = 'A')) - (select v::int from ctx where k = 'before_all'),
  1, 'and nothing else');

-- A heartbeat is presence, not a change worth waking everyone for.
insert into ctx values ('before_hb', pg_temp.msgs((select v::uuid from ctx where k = 'A'))::text);
select pg_temp.act_as(pg_temp.u(2));
select public.heartbeat((select v::uuid from ctx where k = 'A'));
select pg_temp.act_admin();
select is(pg_temp.msgs((select v::uuid from ctx where k = 'A')), (select v::int from ctx where k = 'before_hb'), 'a heartbeat sends nothing');

-- A real game: no slip name and no token ever appears in a payload --------------------------------------------------------------
select pg_temp.act_as(pg_temp.u(1));
select public.set_teams(jsonb_build_object(
  pg_temp.u(1)::text, 0, pg_temp.u(2)::text, 0, pg_temp.u(3)::text, 1, pg_temp.u(4)::text, 1));
select public.start_game();
select public.submit_slips(array['ZXQ Alpha-slip']);
select pg_temp.act_as(pg_temp.u(2));
select public.submit_slips(array['ZXQ Bravo-slip']);
select pg_temp.act_as(pg_temp.u(3));
select public.submit_slips(array['ZXQ Charlie-slip']);
select pg_temp.act_as(pg_temp.u(4));
select public.submit_slips(array['ZXQ Delta-slip']);
select pg_temp.act_as(pg_temp.u(1));
select pg_temp.note(public.start_turn());
select pg_temp.note(public.got_it((select v::uuid from ctx where k = 'tok')));
select pg_temp.note(public.got_it((select v::uuid from ctx where k = 'tok')));
select pg_temp.act_admin();
update public.rooms set turn_ends_at = now() - interval '1 second' where id = (select v::uuid from ctx where k = 'A');
select pg_temp.act_as(pg_temp.u(1));
select public.end_turn();
select pg_temp.act_admin();
select cmp_ok((select count(*)::int from toks), '>=', 3, 'setup: the clue-giver was handed several tokens');
select cmp_ok(pg_temp.msgs((select v::uuid from ctx where k = 'A'), 'turns_changed'), '>=', 1, 'the finished turn sent turns_changed');
select is(
  (select count(*)::int from realtime.messages where payload::text like '%ZXQ%'), 0, 'no slip name appears in any payload');
select is(
  (select count(*)::int from realtime.messages m, toks where m.payload::text like '%' || toks.t::text || '%'), 0, 'no draw token appears in any payload');
select is(
  (select count(*)::int from realtime.messages m where m.payload::text ~* '(ann|bob|cy|di|team|slip|token)'), 0, 'no names or game data appear in any payload');

-- Being removed: a players_changed with only the room id; no user id anywhere ------------------------------------------------------
insert into ctx values ('before_kick', pg_temp.msgs((select v::uuid from ctx where k = 'A'), 'players_changed')::text);
select pg_temp.act_as(pg_temp.u(1));
select public.kick_player(pg_temp.u(4));
select pg_temp.act_admin();
select cmp_ok(
  pg_temp.msgs((select v::uuid from ctx where k = 'A'), 'players_changed'), '>', (select v::int from ctx where k = 'before_kick'),
  'kicking a player sends players_changed');
select is((select count(*)::int from realtime.messages where event = 'player_removed'), 0, 'there is no player_removed event');
select is((select count(*)::int from realtime.messages where payload ? 'user_id'), 0, 'and no payload ever carries a user id');

-- Row-level binding: under one room's topic, only that room's broadcast rows are visible ------------------------------------------------
select pg_temp.act_as(pg_temp.u(5));
select public.create_room('Eve');
select pg_temp.act_admin();
insert into ctx values ('B', pg_temp.room_of(pg_temp.u(5))::text);
insert into ctx values ('codeB', (select code from public.rooms where id = pg_temp.room_of(pg_temp.u(5))));
select pg_temp.act_as(pg_temp.u(6));
select public.join_room((select v from ctx where k = 'codeB'), 'Fay');
select pg_temp.act_admin();
-- a non-broadcast row under room A's topic
insert into realtime.messages (topic, extension, payload, event, private)
values ('room:' || (select v from ctx where k = 'A'), 'presence', '{}'::jsonb, 'x', true);
select cmp_ok(pg_temp.msgs((select v::uuid from ctx where k = 'B')), '>', 0, 'setup: room B has its own messages');

select pg_temp.act_as(pg_temp.u(1));
select pg_temp.join_topic('room:' || (select v from ctx where k = 'A'));
select cmp_ok((select count(*)::int from realtime.messages), '>', 0, 'a member can receive on their room''s topic');
select is(
  (select count(*)::int from realtime.messages where topic <> 'room:' || (select v from ctx where k = 'A')), 0,
  'and sees none of another room''s messages');
select is((select count(*)::int from realtime.messages where extension <> 'broadcast'), 0, 'and no non-broadcast rows');

select pg_temp.act_as(pg_temp.u(5));
select pg_temp.join_topic('room:' || (select v from ctx where k = 'B'));
select cmp_ok((select count(*)::int from realtime.messages), '>', 0, 'room B''s member receives on room B''s topic');
select is((select count(*)::int from realtime.messages where topic <> 'room:' || (select v from ctx where k = 'B')), 0, 'and sees none of room A''s');
select pg_temp.join_topic('room:' || (select v from ctx where k = 'A'));
select is((select count(*)::int from realtime.messages), 0, 'room B''s member cannot receive on room A''s topic');

-- Other spellings of room A's topic get nothing, even for a member of A.
select pg_temp.act_as(pg_temp.u(1));
select pg_temp.join_topic('ROOM:' || (select v from ctx where k = 'A'));
select is((select count(*)::int from realtime.messages), 0, 'an upper-case prefix gets nothing');
select pg_temp.join_topic('room:' || upper((select v from ctx where k = 'A')));
select is((select count(*)::int from realtime.messages), 0, 'an upper-case id gets nothing');
select pg_temp.join_topic('room:' || (select v from ctx where k = 'A') || ' ');
select is((select count(*)::int from realtime.messages), 0, 'a trailing space gets nothing');
select pg_temp.join_topic(' room:' || (select v from ctx where k = 'A'));
select is((select count(*)::int from realtime.messages), 0, 'a leading space gets nothing');
select pg_temp.join_topic('room:not-a-uuid');
select is((select count(*)::int from realtime.messages), 0, 'a malformed topic is refused without an error');
select pg_temp.join_topic('something-else');
select is((select count(*)::int from realtime.messages), 0, 'and so is a topic that is not a room');

-- Members who should no longer receive ---------------------------------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.u(4));
select pg_temp.join_topic('room:' || (select v from ctx where k = 'A'));
select is((select count(*)::int from realtime.messages), 0, 'a player who was kicked cannot join the topic again');
select pg_temp.act_as(pg_temp.u(9));
select pg_temp.join_topic('room:' || (select v from ctx where k = 'A'));
select is((select count(*)::int from realtime.messages), 0, 'an outsider cannot receive');
select pg_temp.act_admin();
update auth.users set deleted_at = now() where id = pg_temp.u(2);
select pg_temp.act_as(pg_temp.u(2));
select pg_temp.join_topic('room:' || (select v from ctx where k = 'A'));
select is((select count(*)::int from realtime.messages), 0, 'a member with a soft-deleted account cannot receive');

-- Nobody can send -------------------------------------------------------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.u(1));
select throws_ok(
  format($$ insert into realtime.messages (topic, extension, payload, event, private)
            values (%L, 'broadcast', '{}'::jsonb, 'room_changed', true) $$, 'room:' || (select v from ctx where k = 'A')),
  '42501', null, 'a member cannot send on their own room''s topic');
select lives_ok(
  $$ select realtime.send('{}'::jsonb, 'room_changed', 'room:whatever', true) $$,
  'realtime.send from a client role does not raise (it only warns)');
select pg_temp.act_admin();
select is((select count(*)::int from realtime.messages where topic = 'room:whatever'), 0, 'but it inserts nothing');

-- A failing Broadcast can never break a game write (review round 3, finding 2) ----------------------------------------------------------
insert into ctx values ('before_B', pg_temp.msgs((select v::uuid from ctx where k = 'B'))::text);
create or replace function public._realtime_send_target() returns text language sql immutable as $$
  select 'realtime.no_such_function'::text
$$;
select pg_temp.act_as(pg_temp.u(5));
select lives_ok($$ select public.update_settings('{"slips_per_player": 2}'::jsonb) $$, 'a settings update succeeds while the send fails');
select pg_temp.act_as(pg_temp.u(7));
select lives_ok(format($$ select public.join_room(%L, 'Gus') $$, (select v from ctx where k = 'codeB')), 'and so does joining a room');
select pg_temp.act_admin();
select is((select slips_per_player from public.rooms where id = (select v::uuid from ctx where k = 'B')), 2, 'the settings change was kept');
select is((select count(*)::int from public.players where user_id = pg_temp.u(7)), 1, 'and so was the new player');
select is(pg_temp.msgs((select v::uuid from ctx where k = 'B')), (select v::int from ctx where k = 'before_B'), 'while no message was sent');
create or replace function public._realtime_send_target() returns text language sql immutable as $$
  select 'realtime.send'::text
$$;
select pg_temp.act_as(pg_temp.u(5));
select public.update_settings('{"slips_per_player": 3}'::jsonb);
select pg_temp.act_admin();
select cmp_ok(pg_temp.msgs((select v::uuid from ctx where k = 'B')), '>', (select v::int from ctx where k = 'before_B'), 'with the send restored, messages flow again');

-- Deleting a populated room: one room_deleted, nothing per seat (review round 3, finding 4) ---------------------------------------------
select pg_temp.act_as(pg_temp.u(8));
select public.create_room('Hal');
select pg_temp.act_admin();
insert into ctx values ('C', pg_temp.room_of(pg_temp.u(8))::text);
insert into ctx values ('codeC', (select code from public.rooms where id = pg_temp.room_of(pg_temp.u(8))));
select pg_temp.act_as(pg_temp.u(10));
select public.join_room((select v from ctx where k = 'codeC'), 'Ivy');
select pg_temp.act_as(pg_temp.u(11));
select public.join_room((select v from ctx where k = 'codeC'), 'Jo');
select pg_temp.act_admin();
update public.rooms set last_activity_at = now() - interval '25 hours' where id = (select v::uuid from ctx where k = 'C');
insert into ctx values ('before_C', pg_temp.msgs((select v::uuid from ctx where k = 'C'))::text);
insert into ctx values ('before_C_pc', pg_temp.msgs((select v::uuid from ctx where k = 'C'), 'players_changed')::text);
select is(public.cleanup_rooms(), 1, 'setup: cleanup removes the expired populated room');
select is(pg_temp.msgs((select v::uuid from ctx where k = 'C'), 'room_deleted'), 1, 'cleanup sends exactly one room_deleted');
select is(pg_temp.msgs((select v::uuid from ctx where k = 'C'), 'players_changed'), (select v::int from ctx where k = 'before_C_pc'), 'and no message per seat');
select is(pg_temp.msgs((select v::uuid from ctx where k = 'C')) - (select v::int from ctx where k = 'before_C'), 1, 'so the whole deletion is one message');

-- The last member leaving: also one room_deleted, and no players_changed for that last seat.
select pg_temp.act_as(pg_temp.u(12));
select public.create_room('Kay');
select pg_temp.act_admin();
insert into ctx values ('D', pg_temp.room_of(pg_temp.u(12))::text);
select pg_temp.act_as(pg_temp.u(12));
select public.leave_room();
select pg_temp.act_admin();
select row_eq(
  $$ select pg_temp.msgs((select v::uuid from ctx where k = 'D'), 'room_deleted'),
            pg_temp.msgs((select v::uuid from ctx where k = 'D'), 'players_changed'),
            pg_temp.msgs((select v::uuid from ctx where k = 'D')) $$,
  row(1, 1, 2), 'the last member leaving sends one room_deleted, after the one players_changed from creating the room');

-- The vocabulary ----------------------------------------------------------------------------------------------------------------------------
select is(
  (select array_agg(distinct event order by event) from realtime.messages where event <> 'x'),
  array['players_changed', 'room_changed', 'room_deleted', 'turns_changed'],
  'the only events are players_changed, room_changed, room_deleted and turns_changed');

select * from finish();

rollback;
