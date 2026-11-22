-- Task 1.9: remove old rooms. Finished rooms go an hour after they finished (finished_at), anything
-- idle goes after a day. Also prunes the room-creation log.
-- Deleting a room cascades to its players, slips and turns.

create function public.cleanup_rooms()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_deleted int;
begin
  with gone as (
    delete from public.rooms
     where (phase = 'finished' and coalesce(finished_at, last_activity_at) < now() - interval '1 hour')
        or last_activity_at < now() - interval '24 hours'
    returning 1
  )
  select count(*) into v_deleted from gone;

  -- The creation log only matters for the rate-limit window.
  delete from public.room_creations where created_at < now() - interval '1 hour';

  return v_deleted;
end;
$$;

revoke all on function public.cleanup_rooms() from public, anon, authenticated;
grant execute on function public.cleanup_rooms() to service_role;

create extension if not exists pg_cron;

select cron.schedule('cleanup-rooms', '*/10 * * * *', 'select public.cleanup_rooms()');
