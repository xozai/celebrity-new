-- Task 1.1: core tables. See docs/PLAN.md section 6.
--
-- Conventions
--   team: 0 or 1 (index into rooms.team_names); null = not on a team.
--   scores: [[r1_team0, r1_team1], [r2_team0, r2_team1], [r3_team0, r3_team1]].
--   Nothing here references auth.users on purpose: identity is just the uuid in the JWT.

create table public.rooms (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null unique
                        check (code ~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{4}$'),
  host_id             uuid,
  created_by          uuid,
  phase               text not null default 'lobby'
                        check (phase in ('lobby', 'submitting', 'playing', 'round_end', 'finished')),
  round               smallint not null default 0 check (round between 0 and 3),
  team_names          text[] not null default array['Team 1', 'Team 2']
                        check (array_length(team_names, 1) = 2),
  slips_per_player    int not null default 3 check (slips_per_player between 1 and 10),
  turn_seconds        int not null default 60 check (turn_seconds in (30, 60, 90)),
  submission_seconds  int not null default 120 check (submission_seconds between 30 and 600),
  skip_mode           text not null default 'off'
                        check (skip_mode in ('off', 'one_per_turn', 'unlimited')),
  submission_deadline timestamptz,
  current_team        smallint check (current_team in (0, 1)),
  turn_idx            int[] not null default array[0, 0]
                        check (array_length(turn_idx, 1) = 2),
  turn_player_id      uuid,
  turn_ends_at        timestamptz,
  turn_got            int not null default 0 check (turn_got >= 0),
  turn_skips          int not null default 0 check (turn_skips >= 0),
  pile_count          int not null default 0 check (pile_count >= 0),
  scores              jsonb not null default '[[0,0],[0,0],[0,0]]'::jsonb
                        check (jsonb_typeof(scores) = 'array'),
  last_activity_at    timestamptz not null default now(),
  created_at          timestamptz not null default now()
);

create index rooms_last_activity_idx on public.rooms (last_activity_at);
create index rooms_created_by_idx on public.rooms (created_by, created_at);

create table public.players (
  room_id      uuid not null references public.rooms (id) on delete cascade,
  user_id      uuid not null,
  name         text not null check (char_length(name) between 1 and 20),
  team         smallint check (team in (0, 1)),
  role         text not null default 'player' check (role in ('player', 'spectator')),
  seat         int not null,
  submitted    boolean not null default false,
  last_seen_at timestamptz not null default now(),
  primary key (room_id, user_id)
);

-- Names are unique per room ignoring case; seats are join order; a user sits in one room at a time.
create unique index players_room_name_idx on public.players (room_id, lower(name));
create unique index players_room_seat_idx on public.players (room_id, seat);
create unique index players_user_idx on public.players (user_id);

create table public.slips (
  id               uuid primary key default gen_random_uuid(),
  room_id          uuid not null references public.rooms (id) on delete cascade,
  author_id        uuid,
  name             text not null check (char_length(name) between 1 and 60),
  in_pile          boolean not null default false,
  pile_order       double precision,
  is_current       boolean not null default false,
  -- Per-turn bookkeeping, cleared when the turn is written to public.turns.
  guessed_at       timestamptz,
  skipped_in_turn  boolean not null default false
);

create index slips_pile_idx on public.slips (room_id, in_pile, pile_order);
create unique index slips_one_current_idx on public.slips (room_id) where is_current;

create table public.turns (
  id          bigint generated always as identity primary key,
  room_id     uuid not null references public.rooms (id) on delete cascade,
  round       smallint not null check (round between 1 and 3),
  team        smallint not null check (team in (0, 1)),
  player_id   uuid not null,
  player_name text not null,
  guessed     text[] not null default '{}',
  skipped     text[] not null default '{}',
  ended_at    timestamptz not null default now()
);

create index turns_room_idx on public.turns (room_id, id);
