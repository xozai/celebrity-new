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

-- Sets turn_player_id for whoever is up next (current_team and turn_idx must already be right). ---
create function public._set_turn_player(p_room_id uuid)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.rooms r
     set turn_player_id = public._pick_turn_player(r.id, r.current_team, r.turn_idx[r.current_team + 1])
   where r.id = p_room_id and r.current_team is not null;
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
  if v_room.phase <> 'submitting' then
    raise exception 'wrong_phase';
  end if;
  if now() < v_room.submission_deadline then
    raise exception 'deadline_not_reached';
  end if;
  if not exists (select 1 from public.slips where room_id = v_room.id) then
    raise exception 'no_slips';
  end if;

  perform public._start_round(v_room.id, 1);
end;
$$;

grant execute on function
  public.submit_slips(text[]),
  public.retract_slips(),
  public.close_submissions()
to authenticated;
