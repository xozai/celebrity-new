-- Realtime without Postgres Changes. Nothing from the game tables is published through the
-- supabase_realtime publication (that would send raw rows, and DELETE events are not filtered by
-- row-level security). Instead, triggers send small invalidation messages over private Broadcast,
-- on one topic per room, and the app refetches get_snapshot when one arrives.
--
--   topic     room:<room_id>
--   events    room_changed     a rooms row was updated
--             room_deleted     the room was deleted (last member left, or cleanup)
--             players_changed  a player joined, or name/team/role/seat/submitted changed
--             player_removed   a player left or was removed; payload also has user_id
--             turns_changed    a turn row was written or changed
--   payload   {"room_id": "<uuid>"}; player_removed adds "user_id": "<uuid>"
--
-- Heartbeats (players.last_seen_at) send nothing. Bursts are normal: one action can touch several
-- rows, so clients should coalesce messages and refetch once.
--
-- Receiving is allowed only to current members of the room (policy below). Nobody can send: there
-- is no INSERT policy on realtime.messages. A client that was removed keeps its already-joined
-- channel until it reconnects, which is how it receives its own player_removed; any new join is
-- refused. Message rows are short-lived (the Realtime service prunes them).

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

create function public._send_room_event(p_room_id uuid, p_event text, p_extra jsonb default '{}'::jsonb)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  select realtime.send(
    jsonb_build_object('room_id', p_room_id) || p_extra,
    p_event,
    'room:' || p_room_id::text,
    true
  );
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

create function public._trg_players_removed()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public._send_room_event(old.room_id, 'player_removed', jsonb_build_object('user_id', old.user_id));
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
  for each row execute function public._trg_players_removed();
create trigger turns_written after insert or update on public.turns
  for each row execute function public._trg_turns_changed();

-- Receive: only current members, only on room:<uuid> topics, only broadcast. Realtime sets the
-- topic for the connection (realtime.topic()) and evaluates this when a client joins a channel.
create policy room_members_receive on realtime.messages
  for select to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and case
      when realtime.topic() ~ '^room:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then public.is_room_member(substring(realtime.topic() from 6)::uuid)
      else false
    end
  );

-- Send: deliberately no INSERT policy, so no client can publish on any topic.
