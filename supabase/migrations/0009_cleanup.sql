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
  -- Rooms that something else holds are skipped (the next run gets them), so cleanup never waits on
  -- one room while another call waits on it from the other side. Expiry is re-checked once a row is
  -- locked, and rows are taken in id order, the same order join_room uses.
  with doomed as (
    select id from public.rooms
     where (phase = 'finished' and coalesce(finished_at, last_activity_at) < now() - interval '1 hour')
        or last_activity_at < now() - interval '24 hours'
     order by id
       for update skip locked
  ), gone as (
    delete from public.rooms where id in (select id from doomed) returning 1
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
