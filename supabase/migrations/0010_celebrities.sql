-- Task 1.10: celebrity recommendations (docs/PLAN.md section 6a, layer 1).
--
-- name_norm contract, shared with tools/celebrity-list, applied in this order: unaccent (PostgreSQL's
-- default rules), lowercase, runs of whitespace collapsed to one space, trim. Punctuation is kept. public._norm_name() applies the
-- same rule to queries, so a loader that follows it will always match what suggest_celebrities sees.

create extension if not exists unaccent with schema extensions;
create extension if not exists pg_trgm with schema extensions;

create table public.celebrities (
  id          bigint generated always as identity primary key,
  name        text not null check (char_length(name) between 1 and 100),
  name_norm   text not null unique,
  description text not null default '',
  category    text not null default 'other'
                check (category in ('film_tv', 'music', 'sports', 'public_figure', 'fictional', 'other')),
  popularity  double precision not null default 0 check (popularity between 0 and 1),
  sources     text[] not null default '{}'
);

-- Serves both "starts with" and "a later word starts with" lookups.
create index celebrities_name_trgm_idx on public.celebrities
  using gin (name_norm extensions.gin_trgm_ops);

alter table public.celebrities enable row level security;
revoke all on public.celebrities from anon, authenticated;

create function public._norm_name(p_text text)
returns text
language sql
stable
set search_path = public, extensions, pg_temp
as $$
  -- Order matters: unaccent can add whitespace of its own (e.g. '½' becomes ' 1/2'), so collapse
  -- and trim after it.
  select lower(btrim(regexp_replace(extensions.unaccent(coalesce(p_text, '')), '\s+', ' ', 'g')));
$$;

-- As-you-type suggestions: names starting with q, or with any word starting with q. ------------------
create function public.suggest_celebrities(q text, max int default 6)
returns table (name text, description text, category text, sources text[])
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_q     text := public._norm_name(q);
  v_limit int  := greatest(1, least(coalesce(max, 6), 10));
  v_like  text;
begin
  perform public._uid();
  if char_length(v_q) < 2 then
    return;
  end if;

  -- Backslash is LIKE's escape character; neutralise it and the two wildcards.
  v_like := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');

  return query
    select c.name, c.description, c.category, c.sources
      from public.celebrities c
     where c.name_norm like v_like || '%'
        or c.name_norm like '% ' || v_like || '%'
     order by c.popularity desc, c.name
     limit v_limit;
end;
$$;

-- "Need ideas?": a popularity-weighted random sample without repeats (Efraimidis-Spirakis:
-- sort by -ln(u) / weight). Names in `exclude` are skipped, compared after normalisation. -------------
create function public.random_celebrities(n int default 8, exclude text[] default '{}')
returns table (name text, description text, category text, sources text[])
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_n  int := greatest(1, least(coalesce(n, 8), 20));
  v_ex text[];
begin
  perform public._uid();
  select coalesce(array_agg(public._norm_name(e)), '{}') into v_ex
    from unnest(coalesce(exclude, '{}')) as e
   where e is not null;

  return query
    select c.name, c.description, c.category, c.sources
      from public.celebrities c
     where not (c.name_norm = any (v_ex))
     order by -ln(1 - random()) / greatest(c.popularity, 0.001)
     limit v_n;
end;
$$;

grant execute on function
  public.suggest_celebrities(text, int),
  public.random_celebrities(int, text[])
to authenticated;

-- rooms.suggestions_enabled, set by the host through update_settings. --------------------------------------
alter table public.rooms add column suggestions_enabled boolean not null default true;

-- Same function as 0004 with one more key.
create or replace function public.update_settings(p_settings jsonb)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room   public.rooms := public._lock_host_room();
  v_key    text;
  v_val    jsonb;
  v_slips  int := v_room.slips_per_player;
  v_turn   int := v_room.turn_seconds;
  v_submit int := v_room.submission_seconds;
  v_skip   text := v_room.skip_mode;
  v_sugg   boolean := v_room.suggestions_enabled;
begin
  if v_room.phase <> 'lobby' then
    raise exception 'wrong_phase';
  end if;
  if p_settings is null or jsonb_typeof(p_settings) <> 'object' then
    raise exception 'invalid_setting';
  end if;

  for v_key, v_val in select * from jsonb_each(p_settings) loop
    case v_key
      when 'slips_per_player' then
        if jsonb_typeof(v_val) <> 'number' or v_val::text !~ '^[0-9]+$' then
          raise exception 'invalid_setting';
        end if;
        v_slips := (v_val::text)::int;
        if v_slips not between 1 and 10 then raise exception 'invalid_setting'; end if;
      when 'turn_seconds' then
        if jsonb_typeof(v_val) <> 'number' or v_val::text !~ '^[0-9]+$' then
          raise exception 'invalid_setting';
        end if;
        v_turn := (v_val::text)::int;
        if v_turn not in (30, 60, 90) then raise exception 'invalid_setting'; end if;
      when 'submission_seconds' then
        if jsonb_typeof(v_val) <> 'number' or v_val::text !~ '^[0-9]+$' then
          raise exception 'invalid_setting';
        end if;
        v_submit := (v_val::text)::int;
        if v_submit not between 30 and 600 then raise exception 'invalid_setting'; end if;
      when 'skip_mode' then
        if jsonb_typeof(v_val) <> 'string' then
          raise exception 'invalid_setting';
        end if;
        v_skip := v_val #>> '{}';
        if v_skip not in ('off', 'one_per_turn', 'unlimited') then
          raise exception 'invalid_setting';
        end if;
      when 'suggestions_enabled' then
        if jsonb_typeof(v_val) <> 'boolean' then
          raise exception 'invalid_setting';
        end if;
        v_sugg := (v_val #>> '{}')::boolean;
      else
        raise exception 'invalid_setting';
    end case;
  end loop;

  update public.rooms
     set slips_per_player = v_slips,
         turn_seconds = v_turn,
         submission_seconds = v_submit,
         skip_mode = v_skip,
         suggestions_enabled = v_sugg,
         last_activity_at = now()
   where id = v_room.id;
end;
$$;
