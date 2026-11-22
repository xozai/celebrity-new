-- Task 1.3: create_room, join_room, leave_room, get_snapshot, heartbeat.
--
-- Error convention: every rejected call raises P0001 with the error code as the message
-- (not_member, not_host, invalid_name, ...). The client maps codes to user-facing text.
-- Functions starting with an underscore are internal and not granted to clients.

-- Caller identity ---------------------------------------------------------------------------
create function public._uid()
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  return v_uid;
end;
$$;

-- Snapshot: the only way a client sees the whole room. Slips are never included. -------------
create function public._snapshot(p_room_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'room',    (select to_jsonb(r) - 'created_by' from public.rooms r where r.id = p_room_id),
    'players', coalesce((select jsonb_agg(to_jsonb(p) order by p.seat)
                           from public.players p where p.room_id = p_room_id), '[]'::jsonb),
    'turns',   coalesce((select jsonb_agg(to_jsonb(t) order by t.id)
                           from public.turns t where t.room_id = p_room_id), '[]'::jsonb),
    'server_now', to_jsonb(clock_timestamp())
  );
$$;

-- Removes a player from a room. 0008 extends this with the submission and turn rules. -------
create function public._remove_player(p_room_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_was_host boolean;
begin
  select (host_id = p_user_id) into v_was_host from public.rooms where id = p_room_id;

  delete from public.players where room_id = p_room_id and user_id = p_user_id;
  update public.slips set author_id = null where room_id = p_room_id and author_id = p_user_id;

  if v_was_host then
    update public.rooms
       set host_id = (select p.user_id from public.players p
                       where p.room_id = p_room_id order by p.seat limit 1)
     where id = p_room_id;
  end if;

  update public.rooms set last_activity_at = now() where id = p_room_id;
end;
$$;

-- Takes the caller out of whatever room they are in, if any. ---------------------------------
create function public._leave_current_room(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room_id uuid;
begin
  select room_id into v_room_id from public.players where user_id = p_user_id;
  if v_room_id is null then
    return;
  end if;
  perform 1 from public.rooms where id = v_room_id for update;
  perform public._remove_player(v_room_id, p_user_id);
end;
$$;

create function public._clean_player_name(p_name text)
returns text
language plpgsql
immutable
as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
begin
  if char_length(v_name) < 1 or char_length(v_name) > 20 then
    raise exception 'invalid_name';
  end if;
  return v_name;
end;
$$;

-- create_room --------------------------------------------------------------------------------
create function public.create_room(p_name text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_uid     uuid := public._uid();
  v_name    text := public._clean_player_name(p_name);
  v_room_id uuid;
  v_code    text;
  v_try     int := 0;
begin
  if (select count(*) from public.rooms
       where created_by = v_uid and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'rate_limited';
  end if;

  perform public._leave_current_room(v_uid);

  loop
    v_try := v_try + 1;
    select string_agg(substr(c_alphabet, 1 + floor(random() * length(c_alphabet))::int, 1), '')
      into v_code from generate_series(1, 4);

    insert into public.rooms (code, host_id, created_by)
    values (v_code, v_uid, v_uid)
    on conflict (code) do nothing
    returning id into v_room_id;

    exit when v_room_id is not null;
    if v_try >= 25 then
      raise exception 'code_unavailable';
    end if;
  end loop;

  insert into public.players (room_id, user_id, name, seat)
  values (v_room_id, v_uid, v_name, 1);

  return public._snapshot(v_room_id);
end;
$$;

-- join_room ----------------------------------------------------------------------------------
create function public.join_room(p_code text, p_name text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid  uuid := public._uid();
  v_room public.rooms;
  v_name text;
begin
  select * into v_room from public.rooms
   where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then
    raise exception 'room_not_found';
  end if;

  -- Already seated here: hand back the existing seat untouched.
  if exists (select 1 from public.players where room_id = v_room.id and user_id = v_uid) then
    return public._snapshot(v_room.id);
  end if;

  v_name := public._clean_player_name(p_name);
  if exists (select 1 from public.players
              where room_id = v_room.id and lower(name) = lower(v_name)) then
    raise exception 'name_taken';
  end if;

  perform public._leave_current_room(v_uid);

  insert into public.players (room_id, user_id, name, role, seat)
  values (
    v_room.id, v_uid, v_name,
    case when v_room.phase = 'lobby' then 'player' else 'spectator' end,
    coalesce((select max(seat) from public.players where room_id = v_room.id), 0) + 1
  );

  update public.rooms set last_activity_at = now() where id = v_room.id;
  return public._snapshot(v_room.id);
end;
$$;

-- leave_room ---------------------------------------------------------------------------------
create function public.leave_room()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid     uuid := public._uid();
  v_room_id uuid;
begin
  select room_id into v_room_id from public.players where user_id = v_uid;
  if v_room_id is null then
    raise exception 'not_member';
  end if;
  perform 1 from public.rooms where id = v_room_id for update;
  perform public._remove_player(v_room_id, v_uid);
end;
$$;

-- get_snapshot -------------------------------------------------------------------------------
create function public.get_snapshot(p_room_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (select 1 from public.players
                  where room_id = p_room_id and user_id = public._uid()) then
    raise exception 'not_member';
  end if;
  return public._snapshot(p_room_id);
end;
$$;

-- heartbeat ----------------------------------------------------------------------------------
create function public.heartbeat(p_room_id uuid)
returns timestamptz
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public._uid();
begin
  update public.players set last_seen_at = now()
   where room_id = p_room_id and user_id = v_uid;
  if not found then
    raise exception 'not_member';
  end if;
  return clock_timestamp();
end;
$$;

-- Grants ---------------------------------------------------------------------------------------
grant execute on function
  public.create_room(text),
  public.join_room(text, text),
  public.leave_room(),
  public.get_snapshot(uuid),
  public.heartbeat(uuid)
to authenticated;
