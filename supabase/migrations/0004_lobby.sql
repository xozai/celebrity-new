-- Task 1.4: set_teams, set_team_name, update_settings, start_game.

-- Locks and returns the caller's room. Every mutating function starts here. -------------------
create function public._lock_my_room()
returns public.rooms
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid     uuid := public._uid();
  v_room_id uuid;
  v_room    public.rooms;
begin
  select room_id into v_room_id from public.players where user_id = v_uid;
  if v_room_id is null then
    raise exception 'not_member';
  end if;
  select * into v_room from public.rooms where id = v_room_id for update;
  return v_room;
end;
$$;

-- Same, but the caller must be the host. ---------------------------------------------------------
create function public._lock_host_room()
returns public.rooms
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.rooms := public._lock_my_room();
begin
  if v_room.host_id is distinct from auth.uid() then
    raise exception 'not_host';
  end if;
  return v_room;
end;
$$;

-- set_teams: {"<user_id>": 0 | 1 | null, ...}. Listed players move; the rest stay put. ---------
create function public.set_teams(p_assignments jsonb)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.rooms := public._lock_host_room();
  v_key  text;
  v_val  jsonb;
  v_team smallint;
  v_user uuid;
begin
  if v_room.phase <> 'lobby' then
    raise exception 'wrong_phase';
  end if;
  if p_assignments is null or jsonb_typeof(p_assignments) <> 'object' then
    raise exception 'invalid_team';
  end if;

  for v_key, v_val in select * from jsonb_each(p_assignments) loop
    if jsonb_typeof(v_val) = 'null' then
      v_team := null;
    elsif jsonb_typeof(v_val) = 'number' and v_val::text in ('0', '1') then
      v_team := (v_val::text)::smallint;
    else
      raise exception 'invalid_team';
    end if;

    begin
      v_user := v_key::uuid;
    exception when invalid_text_representation then
      raise exception 'player_not_found';
    end;

    -- Putting someone on a team also promotes a spectator left over from an earlier game.
    update public.players
       set team = v_team,
           role = case when v_team is not null then 'player' else role end
     where room_id = v_room.id and user_id = v_user;
    if not found then
      raise exception 'player_not_found';
    end if;
  end loop;

  update public.rooms set last_activity_at = now() where id = v_room.id;
end;
$$;

-- set_team_name --------------------------------------------------------------------------------
create function public.set_team_name(p_team int, p_name text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.rooms := public._lock_host_room();
  v_name text := left(btrim(coalesce(p_name, '')), 20);
begin
  if v_room.phase <> 'lobby' then
    raise exception 'wrong_phase';
  end if;
  if p_team is null or p_team not in (0, 1) then
    raise exception 'invalid_team';
  end if;
  if v_name = '' then
    raise exception 'invalid_name';
  end if;

  update public.rooms
     set team_names[p_team + 1] = v_name,
         last_activity_at = now()
   where id = v_room.id;
end;
$$;

-- update_settings: {"slips_per_player":1-10, "turn_seconds":30|60|90,
--                   "submission_seconds":30-600, "skip_mode":"off"|"one_per_turn"|"unlimited"}
-- Only the keys present change. 0010 adds "suggestions_enabled". -----------------------------------
create function public.update_settings(p_settings jsonb)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room   public.rooms := public._lock_host_room();
  v_key    text;
  v_val    jsonb;
  v_slips  int := v_room.slips_per_player;
  v_turn   int := v_room.turn_seconds;
  v_submit int := v_room.submission_seconds;
  v_skip   text := v_room.skip_mode;
begin
  if v_room.phase <> 'lobby' then
    raise exception 'wrong_phase';
  end if;
  if p_settings is null or jsonb_typeof(p_settings) <> 'object' then
    raise exception 'invalid_setting';
  end if;

  for v_key, v_val in select * from jsonb_each(p_settings) loop
    case v_key
      when 'slips_per_player' then
        if jsonb_typeof(v_val) <> 'number' or v_val::text !~ '^[0-9]+$' then
          raise exception 'invalid_setting';
        end if;
        v_slips := (v_val::text)::int;
        if v_slips not between 1 and 10 then raise exception 'invalid_setting'; end if;
      when 'turn_seconds' then
        if jsonb_typeof(v_val) <> 'number' or v_val::text !~ '^[0-9]+$' then
          raise exception 'invalid_setting';
        end if;
        v_turn := (v_val::text)::int;
        if v_turn not in (30, 60, 90) then raise exception 'invalid_setting'; end if;
      when 'submission_seconds' then
        if jsonb_typeof(v_val) <> 'number' or v_val::text !~ '^[0-9]+$' then
          raise exception 'invalid_setting';
        end if;
        v_submit := (v_val::text)::int;
        if v_submit not between 30 and 600 then raise exception 'invalid_setting'; end if;
      when 'skip_mode' then
        if jsonb_typeof(v_val) <> 'string' then
          raise exception 'invalid_setting';
        end if;
        v_skip := v_val #>> '{}';
        if v_skip not in ('off', 'one_per_turn', 'unlimited') then
          raise exception 'invalid_setting';
        end if;
      else
        raise exception 'invalid_setting';
    end case;
  end loop;

  update public.rooms
     set slips_per_player = v_slips,
         turn_seconds = v_turn,
         submission_seconds = v_submit,
         skip_mode = v_skip,
         last_activity_at = now()
   where id = v_room.id;
end;
$$;

-- start_game: two or more players on each team. Players left without a team become spectators. ----
create function public.start_game()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.rooms := public._lock_host_room();
begin
  if v_room.phase <> 'lobby' then
    raise exception 'wrong_phase';
  end if;

  if (select count(*) from public.players
       where room_id = v_room.id and role = 'player' and team = 0) < 2
     or (select count(*) from public.players
          where room_id = v_room.id and role = 'player' and team = 1) < 2 then
    raise exception 'not_enough_players';
  end if;

  update public.players set role = 'spectator'
   where room_id = v_room.id and team is null and role = 'player';
  update public.players set submitted = false where room_id = v_room.id;
  delete from public.slips where room_id = v_room.id;

  update public.rooms
     set phase = 'submitting',
         round = 0,
         submission_deadline = now() + submission_seconds * interval '1 second',
         last_activity_at = now()
   where id = v_room.id;
end;
$$;

grant execute on function
  public.set_teams(jsonb),
  public.set_team_name(int, text),
  public.update_settings(jsonb),
  public.start_game()
to authenticated;
