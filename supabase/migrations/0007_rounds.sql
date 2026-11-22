-- Task 1.7: round end, game end, start_next_round, reset_room.

-- Called by got_it (0006) when the last slip in the pile is guessed. Writes the final turn of the
-- round to the history, then parks the room in round_end, or finished after round 3. ---------------
create function public._end_round(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public._finish_turn(p_room_id, false);

  update public.rooms
     set phase = case when round >= 3 then 'finished' else 'round_end' end,
         current_team = null,
         turn_player_id = null,
         finished_at = case when round >= 3 then clock_timestamp() end,
         last_activity_at = now()
   where id = p_room_id;
end;
$$;

-- start_next_round: host only, and only once the round has actually ended. -------------------------
create function public.start_next_round()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.rooms := public._lock_host_room();
begin
  if v_room.phase <> 'round_end' then
    raise exception 'wrong_phase';
  end if;
  perform public._start_round(v_room.id, v_room.round + 1);
end;
$$;

-- reset_room: rematch. Clears slips, scores and history; keeps players, teams and settings. -------
create function public.reset_room()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.rooms := public._lock_host_room();
begin
  if v_room.phase <> 'finished' then
    raise exception 'wrong_phase';
  end if;

  delete from public.slips where room_id = v_room.id;
  delete from public.turns where room_id = v_room.id;
  update public.players set submitted = false where room_id = v_room.id;

  update public.rooms
     set phase = 'lobby',
         round = 0,
         pile_count = 0,
         scores = '[[0,0],[0,0],[0,0]]'::jsonb,
         turn_idx = array[0, 0],
         current_team = null,
         turn_player_id = null,
         turn_ends_at = null,
         turn_got = 0,
         turn_skips = 0,
         submission_deadline = null,
         finished_at = null,
         last_activity_at = now()
   where id = v_room.id;
end;
$$;

grant execute on function
  public.start_next_round(),
  public.reset_room()
to authenticated;
