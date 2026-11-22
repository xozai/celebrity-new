-- Task 1.5: submit_slips, retract_slips, close_submissions, plus the round-start helpers.

-- Who is up for a team: players of that team in seat order, indexed round-robin by turn_idx. -----
create function public._pick_turn_player(p_room_id uuid, p_team int, p_idx int)
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select s.user_id
    from (
      select p.user_id,
             row_number() over (order by p.seat) - 1 as rn,
             count(*) over () as n
        from public.players p
       where p.room_id = p_room_id and p.team = p_team and p.role = 'player'
    ) s
   where s.rn = mod(p_idx, s.n);
$$;

-- Decides who is up next. A team can take a turn only with a clue-giver and at least one
-- teammate to guess (two or more players). If the team whose turn it is cannot, the other team
-- takes the turn; if neither can, turn_player_id is null and the game waits for the host
-- (assign_spectator calls this again). current_team and turn_idx must already be right. ----------------
create function public._set_turn_player(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.rooms;
  v_n0   int;
  v_n1   int;
  v_team int;
begin
  select * into v_room from public.rooms where id = p_room_id;
  if v_room.current_team is null then
    return;
  end if;

  select count(*) filter (where team = 0), count(*) filter (where team = 1)
    into v_n0, v_n1
    from public.players where room_id = p_room_id and role = 'player';

  v_team := v_room.current_team;
  if (case v_team when 0 then v_n0 else v_n1 end) < 2 then
    if (case v_team when 0 then v_n1 else v_n0 end) >= 2 then
      v_team := 1 - v_team;
    else
      update public.rooms set turn_player_id = null where id = p_room_id;
      return;
    end if;
  end if;

  update public.rooms
     set current_team = v_team,
         turn_player_id = public._pick_turn_player(id, v_team, turn_idx[v_team + 1])
   where id = p_room_id;
end;
$$;

-- Starts a round: every slip goes back into the pile in a fresh random order. Teams alternate
-- who starts (round 1 team 0, round 2 team 1, round 3 team 0); turn_idx carries over so the
-- clue-giver rotation continues across rounds. -------------------------------------------------------
create function public._start_round(p_room_id uuid, p_round int)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.slips
     set in_pile = true,
         is_current = false,
         draw_token = null,
         pile_order = random(),
         guessed_at = null,
         skipped_in_turn = false
   where room_id = p_room_id;

  update public.rooms
     set phase = 'playing',
         round = p_round,
         current_team = (p_round - 1) % 2,
         pile_count = (select count(*) from public.slips where room_id = p_room_id),
         turn_ends_at = null,
         turn_got = 0,
         turn_skips = 0,
         last_activity_at = now()
   where id = p_room_id;

  perform public._set_turn_player(p_room_id);
end;
$$;

-- submit_slips ---------------------------------------------------------------------------------------
create function public.submit_slips(p_names text[])
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room   public.rooms := public._lock_my_room();
  v_player public.players;
  v_names  text[];
begin
  if v_room.phase <> 'submitting' then
    raise exception 'wrong_phase';
  end if;
  -- Judged now, under the room lock, not at the start of the caller's transaction.
  if clock_timestamp() >= v_room.submission_deadline then
    raise exception 'submissions_closed';
  end if;

  select * into v_player from public.players
   where room_id = v_room.id and user_id = auth.uid();
  if v_player.role <> 'player' or v_player.team is null then
    raise exception 'not_a_player';
  end if;
  if v_player.submitted then
    raise exception 'already_submitted';
  end if;

  if p_names is null or coalesce(cardinality(p_names), 0) <> v_room.slips_per_player then
    raise exception 'wrong_slip_count';
  end if;

  select array_agg(btrim(coalesce(n, '')) order by ord) into v_names
    from unnest(p_names) with ordinality as t(n, ord);
  if exists (select 1 from unnest(v_names) n where char_length(n) < 1 or char_length(n) > 60) then
    raise exception 'invalid_slip';
  end if;

  insert into public.slips (room_id, author_id, name)
  select v_room.id, v_player.user_id, n from unnest(v_names) as n;

  update public.players set submitted = true
   where room_id = v_room.id and user_id = v_player.user_id;

  -- Everyone who is playing has handed in their slips: the game starts at once.
  if not exists (select 1 from public.players
                  where room_id = v_room.id and role = 'player' and not submitted) then
    perform public._start_round(v_room.id, 1);
  else
    update public.rooms set last_activity_at = now() where id = v_room.id;
  end if;
end;
$$;

-- retract_slips: take your slips back to edit them. A no-op if you have not submitted. --------------
create function public.retract_slips()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.rooms := public._lock_my_room();
begin
  if v_room.phase <> 'submitting' then
    raise exception 'wrong_phase';
  end if;
  if clock_timestamp() >= v_room.submission_deadline then
    raise exception 'submissions_closed';
  end if;

  delete from public.slips where room_id = v_room.id and author_id = auth.uid();
  update public.players set submitted = false
   where room_id = v_room.id and user_id = auth.uid();
end;
$$;

-- close_submissions: anyone in the room once the deadline has passed. Starts with what came in. ---
create function public.close_submissions()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.rooms := public._lock_my_room();
begin
  if v_room.phase = 'lobby' then
    raise exception 'wrong_phase';
  end if;
  -- Every phone calls this when its countdown ends; the first one wins and the rest do nothing.
  if v_room.phase <> 'submitting' then
    return;
  end if;
  if clock_timestamp() < v_room.submission_deadline then
    raise exception 'deadline_not_reached';
  end if;
  if not exists (select 1 from public.slips where room_id = v_room.id) then
    -- Nobody handed anything in. Edits are closed and the game cannot start with an empty pile, so
    -- send everyone back to the lobby for the host to start again.
    update public.players set submitted = false where room_id = v_room.id;
    update public.rooms
       set phase = 'lobby',
           submission_deadline = null,
           last_activity_at = now()
     where id = v_room.id;
    return;
  end if;

  perform public._start_round(v_room.id, 1);
end;
$$;

grant execute on function
  public.submit_slips(text[]),
  public.retract_slips(),
  public.close_submissions()
to authenticated;
