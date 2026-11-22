-- Task 1.8: transfer_host, kick_player, claim_host, assign_spectator, delete_my_data.

-- Full version of the helper first created in 0003. Used by leave_room, kick_player and
-- delete_my_data, always with the room row already locked.
--
--   * A running turn belonging to the leaver is closed out (their scored slips stay in the history).
--   * While submitting, their slips are deleted; in any other phase the pile must stay intact, so
--     their slips stay and lose the author.
--   * The host role moves to the lowest remaining seat.
--   * If the player who was up next is gone, the turn is re-picked.
--   * If everyone left has now submitted, round 1 starts.
create or replace function public._remove_player(p_room_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.rooms;
begin
  select * into v_room from public.rooms where id = p_room_id;

  if v_room.phase = 'playing'
     and v_room.turn_player_id = p_user_id
     and v_room.turn_ends_at is not null then
    perform public._finish_turn(p_room_id);
  end if;

  if v_room.phase = 'submitting' then
    delete from public.slips where room_id = p_room_id and author_id = p_user_id;
  else
    update public.slips set author_id = null where room_id = p_room_id and author_id = p_user_id;
  end if;

  delete from public.players where room_id = p_room_id and user_id = p_user_id;

  if v_room.host_id = p_user_id then
    update public.rooms
       set host_id = (select p.user_id from public.players p
                       where p.room_id = p_room_id order by p.seat limit 1)
     where id = p_room_id;
  end if;

  select * into v_room from public.rooms where id = p_room_id;

  if v_room.phase = 'playing' and v_room.turn_ends_at is null then
    perform public._set_turn_player(p_room_id);
  elsif v_room.phase = 'submitting'
        and exists (select 1 from public.players where room_id = p_room_id and role = 'player')
        and not exists (select 1 from public.players
                         where room_id = p_room_id and role = 'player' and not submitted)
        and exists (select 1 from public.slips where room_id = p_room_id) then
    perform public._start_round(p_room_id, 1);
  end if;

  update public.rooms set last_activity_at = now() where id = p_room_id;
end;
$$;

-- transfer_host ---------------------------------------------------------------------------------------
create function public.transfer_host(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.rooms := public._lock_host_room();
begin
  if p_user_id is not distinct from auth.uid() then
    raise exception 'cannot_target_self';
  end if;
  if not exists (select 1 from public.players where room_id = v_room.id and user_id = p_user_id) then
    raise exception 'player_not_found';
  end if;

  update public.rooms set host_id = p_user_id, last_activity_at = now() where id = v_room.id;
end;
$$;

-- kick_player ------------------------------------------------------------------------------------------
create function public.kick_player(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.rooms := public._lock_host_room();
begin
  if p_user_id is not distinct from auth.uid() then
    raise exception 'cannot_target_self';
  end if;
  if not exists (select 1 from public.players where room_id = v_room.id and user_id = p_user_id) then
    raise exception 'player_not_found';
  end if;

  perform public._remove_player(v_room.id, p_user_id);
end;
$$;

-- claim_host: any member, once the host has been silent for 45 seconds. --------------------------------
create function public.claim_host()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.rooms := public._lock_my_room();
  v_host_seen timestamptz;
begin
  if v_room.host_id = auth.uid() then
    raise exception 'already_host';
  end if;

  -- FOR UPDATE waits for a heartbeat that is mid-write, so the decision uses the latest value.
  select last_seen_at into v_host_seen
    from public.players where room_id = v_room.id and user_id = v_room.host_id
     for update;
  -- No host row at all counts as stale.
  if v_host_seen is not null and v_host_seen >= now() - interval '45 seconds' then
    raise exception 'host_still_active';
  end if;

  update public.rooms set host_id = auth.uid(), last_activity_at = now() where id = v_room.id;
end;
$$;

-- assign_spectator: put a spectator on a team between turns. ---------------------------------------------
create function public.assign_spectator(p_user_id uuid, p_team int)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room   public.rooms := public._lock_host_room();
  v_target public.players;
begin
  if p_team is null or p_team not in (0, 1) then
    raise exception 'invalid_team';
  end if;
  select * into v_target from public.players where room_id = v_room.id and user_id = p_user_id;
  if not found then
    raise exception 'player_not_found';
  end if;
  if v_target.role <> 'spectator' then
    raise exception 'not_spectator';
  end if;
  if v_room.turn_ends_at is not null then
    raise exception 'turn_active';
  end if;

  update public.players
     set role = 'player', team = p_team, submitted = false
   where room_id = v_room.id and user_id = p_user_id;

  -- Team sizes changed, so the round-robin may now point at someone else.
  if v_room.phase = 'playing' then
    perform public._set_turn_player(v_room.id);
  end if;
  update public.rooms set last_activity_at = now() where id = v_room.id;
end;
$$;

-- delete_my_data: leave any room and drop everything tied to this user. An anonymous account
-- (what the app signs in with) is deleted as well; any other account type keeps its login. -------------
create function public.delete_my_data()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid     uuid := public._uid();
  v_room_id uuid;
begin
  perform public._lock_user(v_uid);

  select room_id into v_room_id from public.players where user_id = v_uid;
  if v_room_id is not null then
    perform 1 from public.rooms where id = v_room_id for update;
    if exists (select 1 from public.players where room_id = v_room_id and user_id = v_uid) then
      perform public._remove_player(v_room_id, v_uid);
    end if;
  end if;

  update public.slips set author_id = null where author_id = v_uid;
  update public.rooms set created_by = null where created_by = v_uid;
  -- Scores and results stay; the name and identity do not.
  update public.turns set player_id = null, player_name = 'Former player' where player_id = v_uid;
  delete from auth.users where id = v_uid and is_anonymous;
end;
$$;

grant execute on function
  public.transfer_host(uuid),
  public.kick_player(uuid),
  public.claim_host(),
  public.assign_spectator(uuid, int),
  public.delete_my_data()
to authenticated;
