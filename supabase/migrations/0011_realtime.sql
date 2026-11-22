-- Realtime without Postgres Changes. Nothing from the game tables is published through the
-- supabase_realtime publication (that would send raw rows, and DELETE events are not filtered by
-- row-level security). Instead, triggers send small invalidation messages over private Broadcast,
-- on one topic per room, and the app refetches get_snapshot when one arrives.
--
--   topic     room:<room_id>   (lower-case uuid; private channel)
--   events    room_changed     a rooms row was updated
--             room_deleted     the room was deleted (last member left, or cleanup): exactly one message
--             players_changed  a player joined, left or was removed, or their name, team, role, seat
--                              or submitted flag changed
--             turns_changed    a turn row was written or changed
--   payload   {"room_id": "<uuid>"}   Realtime adds its own message "id"; nothing else, ever.
--                                     No user ids, names, scores, slips or tokens.
--
-- Heartbeats (players.last_seen_at) send nothing. One action can send several messages, so clients
-- should coalesce them and refetch once.
--
-- A removed client learns it was removed because its next get_snapshot raises not_member. Residual
-- risk: a removed client that stays connected can still see THAT something changed in the room, and
-- when, until its socket reauthorises. It receives no data, and no ids.
--
-- Sending can never break a game write: every send goes through _send_room_event, which resolves the
-- Realtime function dynamically and turns any failure into a WARNING.
--
-- Receiving is allowed only to current members of the room (policy below). Nobody can send: there is
-- no INSERT policy on realtime.messages.

-- Make sure none of the game tables are published, whatever an earlier setup did.
do $$
declare
  t text;
begin
  foreach t in array array['rooms', 'players', 'turns', 'slips', 'room_creations', 'celebrities'] loop
    if exists (select 1 from pg_publication_tables
                where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime drop table public.%I', t);
    end if;
  end loop;
end $$;

-- The function used to send. A function of its own so a test (or an operator) can point it
-- somewhere that does not exist and see that game writes carry on.
create function public._realtime_send_target()
returns text
language sql
immutable
as $$
  select 'realtime.send'::text;
$$;

-- Never raises. The call is built at run time, so this migration applies even where realtime.send
-- is missing, and a missing schema or function is caught like any other failure.
create function public._send_room_event(p_room_id uuid, p_event text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  execute format('select %s($1, $2, $3, true)', public._realtime_send_target())
    using jsonb_build_object('room_id', p_room_id), p_event, 'room:' || p_room_id::text;
exception when others then
  raise warning 'room broadcast % for room % failed: % (SQLSTATE %)', p_event, p_room_id, sqlerrm, sqlstate;
end;
$$;

create function public._trg_rooms_updated()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public._send_room_event(new.id, 'room_changed');
  return null;
end;
$$;

create function public._trg_rooms_deleted()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public._send_room_event(old.id, 'room_deleted');
  return null;
end;
$$;

create function public._trg_players_changed()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public._send_room_event(new.room_id, 'players_changed');
  return null;
end;
$$;

-- A seat deleted because the whole room is being deleted (the cascade) says nothing: the room's
-- single room_deleted covers it. By the time the cascade reaches the seat, the room row is gone.
create function public._trg_players_deleted()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if exists (select 1 from public.rooms where id = old.room_id) then
    perform public._send_room_event(old.room_id, 'players_changed');
  end if;
  return null;
end;
$$;

create function public._trg_turns_changed()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public._send_room_event(new.room_id, 'turns_changed');
  return null;
end;
$$;

create trigger rooms_updated after update on public.rooms
  for each row execute function public._trg_rooms_updated();
create trigger rooms_deleted after delete on public.rooms
  for each row execute function public._trg_rooms_deleted();
create trigger players_inserted after insert on public.players
  for each row execute function public._trg_players_changed();
create trigger players_updated after update of name, team, role, seat, submitted on public.players
  for each row execute function public._trg_players_changed();
create trigger players_deleted after delete on public.players
  for each row execute function public._trg_players_deleted();
create trigger turns_written after insert or update on public.turns
  for each row execute function public._trg_turns_changed();

-- Receive: only current members, only broadcast rows, and only rows of the topic that was authorised
-- (the connection's realtime.topic()). Created only where Realtime exists, so the migration also
-- applies on a database without it.
do $$
begin
  if to_regclass('realtime.messages') is not null and to_regprocedure('realtime.topic()') is not null then
    execute $policy$
      create policy room_members_receive on realtime.messages
        for select to authenticated
        using (
          realtime.messages.extension = 'broadcast'
          and realtime.messages.topic = realtime.topic()
          and case
            when realtime.topic() ~ '^room:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then public.is_room_member(substring(realtime.topic() from 6)::uuid)
            else false
          end
        )
    $policy$;
  end if;
end $$;

-- Send: deliberately no INSERT policy, so no client can publish on any topic.
