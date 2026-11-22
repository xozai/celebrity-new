-- Realtime: the app subscribes to changes on rooms (by id), players and turns (by room id), then
-- refetches get_snapshot. Realtime filters change events through the members-only select policies
-- from 0002. slips is deliberately left out: it holds the secret pile.

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;

alter publication supabase_realtime add table public.rooms, public.players, public.turns;
