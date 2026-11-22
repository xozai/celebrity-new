-- Task 1.2: row-level security. Clients read; every write goes through a security definer function.

-- Anything created later in public starts with no client access. Each function below is granted
-- to `authenticated` explicitly; anonymous-sign-in users carry the `authenticated` role.
alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated;
alter default privileges for role postgres
  revoke execute on functions from public;
alter default privileges for role postgres in schema public
  revoke execute on functions from anon, authenticated;

revoke all on public.rooms, public.players, public.slips, public.turns, public.room_creations from anon, authenticated;
grant select on public.rooms, public.players, public.turns to authenticated;

alter table public.rooms enable row level security;
alter table public.players enable row level security;
alter table public.slips enable row level security;
alter table public.turns enable row level security;
alter table public.room_creations enable row level security;

-- Membership checks used by the policies. security definer so the players policy does not recurse.
-- A seat only counts while the account behind the token is live (the RPCs refuse such tokens with
-- not_authenticated). Non-throwing, so safe inside policies.
create function public.is_room_member(p_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.players p
    where p.room_id = p_room_id and p.user_id = auth.uid()
  ) and exists (
    select 1 from auth.users u
    where u.id = auth.uid() and u.deleted_at is null
  );
$$;

-- The rooms the caller sits in, empty if their account is gone. The table policies use it as an
-- uncorrelated subquery (room_id in (select my_room_ids())), so PostgreSQL evaluates the account
-- check and the indexed seat lookup (players_user_idx) once per statement, not once per row.
create function public.my_room_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p.room_id from public.players p
   where p.user_id = auth.uid()
     and exists (select 1 from auth.users u where u.id = auth.uid() and u.deleted_at is null);
$$;

revoke all on function public.is_room_member(uuid), public.my_room_ids() from public, anon;
grant execute on function public.is_room_member(uuid), public.my_room_ids() to authenticated;

create policy rooms_member_select on public.rooms
  for select to authenticated
  using (id in (select public.my_room_ids()));

create policy players_member_select on public.players
  for select to authenticated
  using (room_id in (select public.my_room_ids()));

create policy turns_member_select on public.turns
  for select to authenticated
  using (room_id in (select public.my_room_ids()));

-- slips: RLS on, no policy and no grant. Only security definer functions touch it.
