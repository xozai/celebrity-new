-- Realtime: no Postgres Changes at all. Triggers send invalidation messages over private Broadcast on
-- the topic room:<room_id>; only current members of that room can receive on it; nobody can send.
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

-- What a client does when it joins a private channel: Realtime sets the topic, then runs the policy.
create function pg_temp.join_topic(p_topic text) returns void language sql as $$
  select set_config('realtime.topic', p_topic, true)
$$;
grant execute on function pg_temp.join_topic(text) to public;

create function pg_temp.room_id() returns uuid language sql security definer as $$
  select room_id from public.players where user_id = pg_temp.u(1)
$$;
grant execute on function pg_temp.room_id() to public;

create function pg_temp.msgs(p_event text) returns int language sql security definer as $$
  select count(*)::int from realtime.messages
   where topic = 'room:' || pg_temp.room_id() and event = p_event
$$;
grant execute on function pg_temp.msgs(text) to public;

select plan(26);

-- No Postgres Changes ---------------------------------------------------------------------------------------------
select is(
  (select count(*)::int from pg_publication_tables
    where pubname = 'supabase_realtime'
      and tablename in ('rooms', 'players', 'turns', 'slips', 'room_creations', 'celebrities')),
  0, 'no game table is in the supabase_realtime publication');

-- A room: Ann (host), Bob, Cy ----------------------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.u(1));
select public.create_room('Ann');
select pg_temp.act_admin();
create temp table ctx (k text primary key, v text);
grant all on ctx to public;
insert into ctx values ('code', (select code from public.rooms where id = pg_temp.room_id()));
insert into ctx values ('room', pg_temp.room_id()::text);
select pg_temp.act_as(pg_temp.u(2));
select public.join_room((select v from ctx where k = 'code'), 'Bob');
select pg_temp.act_as(pg_temp.u(3));
select public.join_room((select v from ctx where k = 'code'), 'Cy');

-- Events -------------------------------------------------------------------------------------------------------------------
select pg_temp.act_admin();
select cmp_ok(pg_temp.msgs('players_changed'), '>=', 3, 'players joining send players_changed on the room topic');
select is(
  (select array_agg(distinct k order by k) from realtime.messages m, jsonb_object_keys(m.payload) k
    where m.topic = 'room:' || pg_temp.room_id() and m.event = 'players_changed' and k <> 'id'),
  array['room_id'], 'and the payload carries only the room id (Realtime adds its own message id)');
select is(
  (select (m.payload ->> 'room_id')::uuid from realtime.messages m
    where m.topic = 'room:' || pg_temp.room_id() and m.event = 'players_changed' limit 1),
  pg_temp.room_id(), 'the room id in the payload is the room''s');
select is(
  (select count(*)::int from realtime.messages
    where topic = 'room:' || pg_temp.room_id() and private is not true), 0, 'every message is private');
select is(
  (select count(*)::int from realtime.messages where extension <> 'broadcast'), 0, 'and uses the broadcast extension');

select pg_temp.act_as(pg_temp.u(1));
select public.update_settings('{"slips_per_player": 4}'::jsonb);
select pg_temp.act_admin();
select cmp_ok(pg_temp.msgs('room_changed'), '>=', 1, 'a room update sends room_changed');

insert into public.turns (room_id, round, team, player_id, player_name) values (pg_temp.room_id(), 1, 0, pg_temp.u(1), 'Ann');
select cmp_ok(pg_temp.msgs('turns_changed'), '>=', 1, 'a new turn sends turns_changed');

-- A heartbeat is presence, not a change worth waking everyone for.
create temp table before_hb as select count(*)::int as n from realtime.messages where topic = 'room:' || pg_temp.room_id();
select pg_temp.act_as(pg_temp.u(2));
select public.heartbeat(pg_temp.room_id());
select pg_temp.act_admin();
select is(
  (select count(*)::int from realtime.messages where topic = 'room:' || pg_temp.room_id()),
  (select n from before_hb), 'a heartbeat sends nothing');

-- Being removed: the removed user's id goes to that room's topic, and only there ------------------------------------------------
select pg_temp.act_as(pg_temp.u(1));
select public.kick_player(pg_temp.u(3));
select pg_temp.act_admin();
select is(
  (select m.payload - 'id' from realtime.messages m
    where m.topic = 'room:' || pg_temp.room_id() and m.event = 'player_removed'),
  jsonb_build_object('room_id', pg_temp.room_id(), 'user_id', pg_temp.u(3)),
  'kicking a player sends player_removed with the room id and the removed user id');
select is(
  (select count(*)::int from realtime.messages
    where payload ->> 'user_id' is not null and topic <> 'room:' || pg_temp.room_id()), 0, 'and never to any other topic');

-- Nothing but ids and event names leaves the database ----------------------------------------------------------------------------
select is(
  (select array_agg(distinct k order by k) from realtime.messages m, jsonb_object_keys(m.payload) k where k <> 'id'),
  array['room_id', 'user_id'], 'payloads only ever hold room_id and user_id (plus Realtime''s message id)');
select is(
  (select count(*)::int from realtime.messages where payload::text ~* '(ann|bob|cy|team|slip)'), 0, 'no names or game data in any payload');
select is(
  (select array_agg(distinct event order by event) from realtime.messages),
  array['player_removed', 'players_changed', 'room_changed', 'turns_changed'], 'event names so far');

-- Who can receive -------------------------------------------------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.u(1));
select pg_temp.join_topic('room:' || pg_temp.room_id());
select cmp_ok((select count(*)::int from realtime.messages), '>', 0, 'a member can receive on their room''s topic');

select pg_temp.act_as(pg_temp.u(9));
select pg_temp.join_topic('room:' || pg_temp.room_id());
select is((select count(*)::int from realtime.messages), 0, 'an outsider cannot receive on it');

select pg_temp.act_as(pg_temp.u(3));
select pg_temp.join_topic('room:' || pg_temp.room_id());
select is((select count(*)::int from realtime.messages), 0, 'a player who was kicked cannot join it again');

select pg_temp.act_as(pg_temp.u(1));
select pg_temp.join_topic('room:00000000-0000-0000-0000-00000000dead');
select is((select count(*)::int from realtime.messages), 0, 'a member cannot receive on another room''s topic');
select pg_temp.join_topic('room:not-a-uuid');
select is((select count(*)::int from realtime.messages), 0, 'a malformed topic is refused without an error');
select pg_temp.join_topic('something-else');
select is((select count(*)::int from realtime.messages), 0, 'and so is a topic that is not a room');

-- A member whose account was deleted loses access too.
select pg_temp.act_admin();
update auth.users set deleted_at = now() where id = pg_temp.u(2);
select pg_temp.act_as(pg_temp.u(2));
select pg_temp.join_topic('room:' || pg_temp.room_id());
select is((select count(*)::int from realtime.messages), 0, 'a member with a soft-deleted account cannot receive');

-- Nobody can send ----------------------------------------------------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.u(1));
select throws_ok(
  format($$ insert into realtime.messages (topic, extension, payload, event, private)
            values (%L, 'broadcast', '{}'::jsonb, 'room_changed', true) $$, 'room:' || pg_temp.room_id()),
  '42501', null, 'a member cannot send on their own room''s topic');
select lives_ok(
  $$ select realtime.send('{}'::jsonb, 'room_changed', 'room:whatever', true) $$,
  'realtime.send from a client role does not raise (it only warns)');
select pg_temp.act_admin();
select is((select count(*)::int from realtime.messages where topic = 'room:whatever'), 0, 'but it inserts nothing, so a client cannot send that way either');

-- When the last member leaves the room is deleted, and its topic hears about it ----------------------------------------------------------
select pg_temp.act_admin();
update auth.users set deleted_at = null where id = pg_temp.u(2);
select pg_temp.act_as(pg_temp.u(2));
select public.leave_room();
select pg_temp.act_as(pg_temp.u(1));
select public.leave_room();
select pg_temp.act_admin();
select is(
  (select count(*)::int from realtime.messages
    where topic = 'room:' || (select v from ctx where k = 'room') and event = 'room_deleted'),
  1, 'deleting the room sends room_deleted on its topic');
select is(
  (select count(*)::int from realtime.messages
    where topic = 'room:' || (select v from ctx where k = 'room') and event = 'player_removed'),
  3, 'and every player who left or was removed got a player_removed');

select * from finish();

rollback;
