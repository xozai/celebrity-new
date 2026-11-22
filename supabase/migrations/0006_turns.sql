-- Task 1.6: start_turn, got_it, skip_slip, current_slip, end_turn.
--
-- Timer design (docs/PLAN.md section 6): there is no server-side timer. turn_ends_at is the source
-- of truth, got_it and skip_slip reject calls after it, and every phone calls end_turn() when its
-- countdown reaches zero. The first call wins; later calls see turn_ends_at is null and do nothing.
--
-- _end_round(room_id) is called by got_it when the pile empties. It is defined in 0007.

-- Marks the next slip in the pile as current and returns it as {"id", "name"}, or null if none. ----
create function public._draw_slip(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_slip public.slips;
begin
  update public.slips s
     set is_current = true
   where s.id = (select id from public.slips
                  where room_id = p_room_id and in_pile and not is_current
                  order by pile_order, id
                  limit 1)
  returning s.* into v_slip;

  if v_slip.id is null then
    return null;
  end if;
  return jsonb_build_object('id', v_slip.id, 'name', v_slip.name);
end;
$$;

-- Writes the finished turn to public.turns and tidies up. Does not check the clock. ---------------
-- p_continue = true  : hand the turn to the other team's next player.
-- p_continue = false : the round is over (pile empty); the caller decides what happens next.
create function public._finish_turn(p_room_id uuid, p_continue boolean default true)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.rooms;
begin
  select * into v_room from public.rooms where id = p_room_id;

  insert into public.turns (room_id, round, team, player_id, player_name, guessed, skipped)
  values (
    v_room.id,
    v_room.round,
    v_room.current_team,
    v_room.turn_player_id,
    coalesce((select name from public.players
               where room_id = v_room.id and user_id = v_room.turn_player_id), 'Unknown'),
    coalesce((select array_agg(name order by guessed_at, id) from public.slips
               where room_id = v_room.id and guessed_at is not null), '{}'),
    coalesce((select array_agg(name order by id) from public.slips
               where room_id = v_room.id and skipped_in_turn and guessed_at is null), '{}')
  );

  -- The unfinished slip goes back into the pile at a new random position.
  update public.slips
     set is_current = false,
         pile_order = case when in_pile then random() else pile_order end,
         guessed_at = null,
         skipped_in_turn = false
   where room_id = v_room.id
     and (is_current or guessed_at is not null or skipped_in_turn);

  update public.rooms
     set turn_idx[current_team + 1] = turn_idx[current_team + 1] + 1,
         turn_ends_at = null,
         turn_got = 0,
         turn_skips = 0,
         last_activity_at = now()
   where id = v_room.id;

  if p_continue then
    update public.rooms set current_team = 1 - current_team where id = v_room.id;
    perform public._set_turn_player(v_room.id);
  end if;
end;
$$;

-- Common checks for calls made by the clue-giver during a running turn. --------------------------
create function public._lock_running_turn()
returns public.rooms
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.rooms := public._lock_my_room();
begin
  if v_room.phase <> 'playing' then
    raise exception 'wrong_phase';
  end if;
  if v_room.turn_player_id is distinct from auth.uid() then
    raise exception 'not_your_turn';
  end if;
  if v_room.turn_ends_at is null then
    raise exception 'turn_not_started';
  end if;
  if now() > v_room.turn_ends_at then
    raise exception 'turn_over';
  end if;
  return v_room;
end;
$$;

-- start_turn -----------------------------------------------------------------------------------------
create function public.start_turn()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.rooms := public._lock_my_room();
begin
  if v_room.phase <> 'playing' then
    raise exception 'wrong_phase';
  end if;
  if v_room.turn_player_id is distinct from auth.uid() then
    raise exception 'not_your_turn';
  end if;
  if v_room.turn_ends_at is not null then
    raise exception 'turn_already_started';
  end if;

  update public.rooms
     set turn_ends_at = now() + turn_seconds * interval '1 second',
         turn_got = 0,
         turn_skips = 0,
         last_activity_at = now()
   where id = v_room.id;

  return public._draw_slip(v_room.id);
end;
$$;

-- got_it: score the current slip, return the next one (null when the pile is empty). ---------------
create function public.got_it()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.rooms := public._lock_running_turn();
  v_left int;
begin
  update public.slips
     set in_pile = false,
         is_current = false,
         skipped_in_turn = false,
         guessed_at = clock_timestamp()
   where room_id = v_room.id and is_current;

  update public.rooms
     set turn_got = turn_got + 1,
         pile_count = pile_count - 1,
         scores = jsonb_set(
           scores,
           array[(round - 1)::text, current_team::text],
           to_jsonb(((scores -> (round - 1) -> current_team)::text)::int + 1)
         ),
         last_activity_at = now()
   where id = v_room.id
  returning pile_count into v_left;

  if v_left = 0 then
    perform public._end_round(v_room.id);
    return null;
  end if;
  return public._draw_slip(v_room.id);
end;
$$;

-- skip_slip: the slip stays in the pile but moves to the back; returns the next one. -----------------
create function public.skip_slip()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.rooms := public._lock_running_turn();
begin
  if v_room.skip_mode = 'off'
     or (v_room.skip_mode = 'one_per_turn' and v_room.turn_skips >= 1) then
    raise exception 'skip_not_allowed';
  end if;

  update public.slips
     set is_current = false,
         skipped_in_turn = true,
         pile_order = coalesce((select max(pile_order) from public.slips
                                 where room_id = v_room.id and in_pile), 0) + 1
   where room_id = v_room.id and is_current;

  update public.rooms set turn_skips = turn_skips + 1 where id = v_room.id;

  return public._draw_slip(v_room.id);
end;
$$;

-- current_slip: the clue-giver's slip after a reconnect. Everyone else gets null. -------------------
create function public.current_slip()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid  uuid := public._uid();
  v_room public.rooms;
  v_slip public.slips;
begin
  select r.* into v_room
    from public.rooms r join public.players p on p.room_id = r.id
   where p.user_id = v_uid;
  if not found then
    raise exception 'not_member';
  end if;

  if v_room.phase <> 'playing'
     or v_room.turn_player_id is distinct from v_uid
     or v_room.turn_ends_at is null
     or now() > v_room.turn_ends_at then
    return null;
  end if;

  select * into v_slip from public.slips where room_id = v_room.id and is_current;
  if not found then
    return null;
  end if;
  return jsonb_build_object('id', v_slip.id, 'name', v_slip.name);
end;
$$;

-- end_turn: any member once turn_ends_at has passed. Safe to call from every phone. ----------------
create function public.end_turn()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.rooms := public._lock_my_room();
begin
  if v_room.phase <> 'playing' or v_room.turn_ends_at is null then
    return;
  end if;
  if now() < v_room.turn_ends_at then
    raise exception 'deadline_not_reached';
  end if;

  perform public._finish_turn(v_room.id);
end;
$$;

grant execute on function
  public.start_turn(),
  public.got_it(),
  public.skip_slip(),
  public.current_slip(),
  public.end_turn()
to authenticated;
