-- Task 1.10: celebrities table, suggest_celebrities, random_celebrities, rooms.suggestions_enabled.
begin;

create extension if not exists pgtap with schema extensions;

create function pg_temp.act_as(u uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
grant execute on function pg_temp.act_as(uuid) to public;

create function pg_temp.act_admin() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end $$;
grant execute on function pg_temp.act_admin() to public;

create function pg_temp.act_anon() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'anon', true);
end $$;
grant execute on function pg_temp.act_anon() to public;

-- Names the way the loader stores them: name_norm is lowercase, accents stripped, whitespace collapsed.
create function pg_temp.names(q text, m int default 6) returns text[] language sql as $$
  select coalesce(array_agg(name), '{}') from public.suggest_celebrities(q, m)
$$;
grant execute on function pg_temp.names(text, int) to public;

select plan(46);

insert into public.celebrities (name, name_norm, description, category, popularity, sources) values
  ('Taylor Swift',        'taylor swift',        'American singer-songwriter', 'music',         0.99, '{wikipedia,imdb}'),
  ('Tom Hanks',           'tom hanks',           'American actor',             'film_tv',       0.97, '{wikipedia,imdb}'),
  ('Tom Cruise',          'tom cruise',          'American actor',             'film_tv',       0.96, '{wikipedia,imdb}'),
  ('Beyoncé',             'beyonce',             'American singer',            'music',         0.95, '{wikipedia}'),
  ('Steve Jobs',          'steve jobs',          'Co-founder of Apple',        'public_figure', 0.93, '{wikipedia}'),
  ('Jennifer Lopez',      'jennifer lopez',      'American singer and actress','music',         0.92, '{wikipedia,imdb}'),
  ('Tom Holland',         'tom holland',         'English actor',              'film_tv',       0.90, '{imdb}'),
  ('Harry Potter',        'harry potter',        'Fictional wizard',           'fictional',     0.90, '{wikipedia}'),
  ('Lionel Messi',        'lionel messi',        'Argentine footballer',       'sports',        0.89, '{wikipedia}'),
  ('Jennifer Aniston',    'jennifer aniston',    'American actress',           'film_tv',       0.88, '{imdb}'),
  ('Oprah Winfrey',       'oprah winfrey',       'American talk show host',    'public_figure', 0.87, '{wikipedia}'),
  ('Serena Williams',     'serena williams',     'American tennis player',     'sports',        0.86, '{wikipedia}'),
  ('Albert Einstein',     'albert einstein',     'Physicist',                  'public_figure', 0.85, '{wikipedia}'),
  ('Sherlock Holmes',     'sherlock holmes',     'Fictional detective',        'fictional',     0.84, '{wikipedia}'),
  ('Marilyn Monroe',      'marilyn monroe',      'American actress',           'film_tv',       0.83, '{wikipedia}'),
  ('Céline Dion',         'celine dion',         'Canadian singer',            'music',         0.82, '{wikipedia}'),
  ('Björk',               'bjork',               'Icelandic singer',           'music',         0.70, '{wikipedia}'),
  ('Mickey Mouse',        'mickey mouse',        'Cartoon character',          'fictional',     0.81, '{wikipedia}'),
  ('Bob Dylan',           'bob dylan',           'American singer-songwriter', 'music',         0.80, '{wikipedia}'),
  ('Zendaya',             'zendaya',             'American actress',           'film_tv',       0.79, '{imdb}');

-- Twelve names sharing a prefix, to test the result limit and the sample size.
insert into public.celebrities (name, name_norm, description, category, popularity, sources)
select 'Zed ' || i, 'zed ' || i, 'Test person', 'other', 0.5 - i / 100.0, '{wikipedia}' from generate_series(1, 12) i;

-- Two names to check that sampling follows popularity.
insert into public.celebrities (name, name_norm, description, category, popularity, sources) values
  ('Heavy Hitter', 'heavy hitter', 'Test person', 'other', 1.0,  '{wikipedia}'),
  ('Light Touch',  'light touch',  'Test person', 'other', 0.01, '{wikipedia}');

-- Access -------------------------------------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select throws_ok('select * from public.celebrities', '42501', null, 'no direct select on celebrities for clients');
select throws_ok($$ insert into public.celebrities (name, name_norm) values ('X', 'x') $$, '42501', null, 'no direct insert either');
select pg_temp.act_anon();
select throws_ok($$ select * from public.suggest_celebrities('tom') $$, '42501', null, 'anon cannot call suggest_celebrities');
select throws_ok($$ select * from public.random_celebrities() $$, '42501', null, 'anon cannot call random_celebrities');

-- suggest_celebrities --------------------------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select is(pg_temp.names('tom'), array['Tom Hanks', 'Tom Cruise', 'Tom Holland'], 'prefix match, most famous first');
select is(pg_temp.names('tom c'), array['Tom Cruise'], 'a prefix can run across words');
select is(pg_temp.names('jobs'), array['Steve Jobs'], 'a match on the start of any word ("jobs" finds Steve Jobs)');
select is(pg_temp.names('wil'), array['Serena Williams'], 'word-start match on a later word');
select is(pg_temp.names('mon'), array['Marilyn Monroe'], 'a prefix of the second word, not the first');
select is(pg_temp.names('ob'), '{}'::text[], 'a match in the middle of a word does not count');
select is(pg_temp.names('beyonce'), array['Beyoncé'], 'accent-insensitive: "beyonce" finds Beyoncé');
select is(pg_temp.names('BEYONCÉ'), array['Beyoncé'], 'case- and accent-insensitive on the query side too');
select is(pg_temp.names('celine'), array['Céline Dion'], '"celine" finds Céline Dion');
select is(pg_temp.names('Bjork'), array['Björk'], '"Bjork" finds Björk');
select is(pg_temp.names('  tom   h '), array['Tom Hanks', 'Tom Holland'], 'the query is trimmed and its whitespace collapsed');
select is(pg_temp.names('jen'), array['Jennifer Lopez', 'Jennifer Aniston'], 'results are ordered by popularity');

-- Short or empty queries return nothing.
select is(pg_temp.names('t'), '{}'::text[], 'a one-character query returns nothing');
select is(pg_temp.names(' t '), '{}'::text[], 'a one-character query with spaces returns nothing');
select is(pg_temp.names(''), '{}'::text[], 'an empty query returns nothing');
select is(pg_temp.names(null), '{}'::text[], 'a null query returns nothing');

-- LIKE wildcards in the query are plain characters.
select is(pg_temp.names('t%'), '{}'::text[], 'a percent sign is not a wildcard');
select is(pg_temp.names('_o'), '{}'::text[], 'an underscore is not a wildcard');
select is(pg_temp.names('%%'), '{}'::text[], 'two percent signs are not a wildcard');

-- Result limit: default 6, at most 10, at least 1.
select is(cardinality(pg_temp.names('zed')), 6, 'the default limit is 6');
select is(cardinality(pg_temp.names('zed', 10)), 10, 'a limit of 10 is honoured');
select is(cardinality(pg_temp.names('zed', 50)), 10, 'a limit above 10 is clamped to 10');
select is(cardinality(pg_temp.names('zed', 0)), 1, 'a limit of 0 is clamped to 1');
select is(cardinality(pg_temp.names('zed', -5)), 1, 'a negative limit is clamped to 1');
select is(cardinality(pg_temp.names('zed', null)), 6, 'a null limit falls back to 6');
select is(pg_temp.names('zed', 3), array['Zed 1', 'Zed 2', 'Zed 3'], 'the limit keeps the most popular');

select row_eq(
  $$ select name, description, category, sources from public.suggest_celebrities('tom h', 1) $$,
  row('Tom Hanks'::text, 'American actor'::text, 'film_tv'::text, '{wikipedia,imdb}'::text[]),
  'each result carries name, description, category and sources');

-- random_celebrities ------------------------------------------------------------------------------------------------------
select is((select count(*)::int from public.random_celebrities()), 8, 'the default sample is 8');
select is((select count(*)::int from public.random_celebrities(5)), 5, 'n is honoured');
select is((select count(*)::int from public.random_celebrities(100)), 20, 'n above 20 is clamped to 20');
select is((select count(*)::int from public.random_celebrities(0)), 1, 'n of 0 is clamped to 1');
select is((select count(*)::int from public.random_celebrities(null)), 8, 'a null n falls back to 8');
select is(
  (select count(distinct name)::int from public.random_celebrities(20)), 20, 'a sample never repeats a name');

-- exclude: everything except two rows is excluded, written in other cases and with accents.
select pg_temp.act_admin();
create temp table ex as
  select array_agg(upper(name)) as names from public.celebrities where name not in ('Zed 1', 'Beyoncé');
grant all on ex to public;
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select is(
  (select array_agg(name order by name) from public.random_celebrities(20, (select names from ex))),
  array['Beyoncé', 'Zed 1'],
  'exclude hides the listed names, ignoring case and accents');
select is(
  (select count(*)::int from public.random_celebrities(8, array['Tom Hanks', 'tom cruise', null])), 8,
  'excluding a few names still returns a full sample');
select is(
  (select count(*)::int from public.random_celebrities(100, array['Tom Hanks']) where name = 'Tom Hanks'), 0,
  'an excluded name never appears');

-- Sampling follows popularity: with only two names left, the famous one should win about 99 times in 100.
select pg_temp.act_admin();
create temp table ex2 as
  select array_agg(name) as names from public.celebrities where name not in ('Heavy Hitter', 'Light Touch');
grant all on ex2 to public;
select pg_temp.act_as('00000000-0000-0000-0000-000000000001');
select cmp_ok(
  (select count(*)::int from generate_series(1, 300) g,
     lateral public.random_celebrities(1, (select names from ex2)) r where r.name = 'Heavy Hitter'),
  '>=', 270, 'the sample is weighted by popularity');

-- rooms.suggestions_enabled ----------------------------------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-000000000011');
select public.create_room('Hal');
select pg_temp.act_admin();
select ok(
  (select suggestions_enabled from public.rooms where host_id = '00000000-0000-0000-0000-000000000011'),
  'suggestions are on by default');
select pg_temp.act_admin();
create temp table room_code as select code from public.rooms where host_id = '00000000-0000-0000-0000-000000000011';
grant all on room_code to public;
select pg_temp.act_as('00000000-0000-0000-0000-000000000012');
select public.join_room((select code from room_code), 'Ivy');
select throws_ok(
  $$ select public.update_settings('{"suggestions_enabled": false}'::jsonb) $$, 'P0001', 'not_host', 'only the host can turn suggestions off');
select pg_temp.act_as('00000000-0000-0000-0000-000000000011');
select throws_ok(
  $$ select public.update_settings('{"suggestions_enabled": "no"}'::jsonb) $$, 'P0001', 'invalid_setting', 'suggestions_enabled must be a boolean');
select public.update_settings('{"suggestions_enabled": false, "slips_per_player": 4}'::jsonb);
select pg_temp.act_admin();
select row_eq(
  $$ select suggestions_enabled, slips_per_player from public.rooms where host_id = '00000000-0000-0000-0000-000000000011' $$,
  row(false, 4), 'the host can turn suggestions off, alongside other settings');
select pg_temp.act_as('00000000-0000-0000-0000-000000000011');
select public.update_settings('{"suggestions_enabled": true}'::jsonb);
select is(
  (public.get_snapshot((select id from public.rooms where host_id = '00000000-0000-0000-0000-000000000011')) -> 'room' ->> 'suggestions_enabled')::boolean,
  true, 'the setting is toggled back on and shows up in the snapshot');

select * from finish();

rollback;
