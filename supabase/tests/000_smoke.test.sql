-- Proves the pgTAP harness runs. Real tests start at 001 (docs/PLAN.md, Phase 1).
begin;

create extension if not exists pgtap with schema extensions;

select plan(1);

select ok(true, 'pgTAP loads');

select * from finish();

rollback;
