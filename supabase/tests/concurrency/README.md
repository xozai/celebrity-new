# Concurrency checks

pgTAP (`supabase test db`) runs in one session, so it cannot test "request B queued behind request
A's open transaction". `run.sh` drives real concurrent sessions against the local database.

## Run

```
supabase start            # once
supabase db reset         # optional: a clean database with all migrations
bash supabase/tests/concurrency/run.sh
```

It exits 0 when every check passes and 1 otherwise, printing `ok` / `FAIL` per check (about 25 s).

- No dependencies beyond bash. It uses `psql` if installed, otherwise `psql` inside the local
  `supabase_db_*` container. The connection comes from `supabase status`; set `DB_URL` to override.
- Every session sets `lock_timeout` (10 s) and `statement_timeout` (30 s), so a hang fails fast.
- It creates its own users and rooms (ids starting `c0c0c0c0-`) and removes them when it ends, also
  after an aborted run.

## What it checks

1. `join_room` and `create_room` queued behind an open `delete_my_data` by the same user fail with
   `not_authenticated` and create nothing.
2. A member RPC (`end_turn`) queued behind that member being kicked fails with `not_member`.
3. Two users switching rooms in opposite directions at the same time (160 switches) finish without a
   deadlock or any error.
4. `cleanup_rooms` against a join into an expiring room: cleanup does not wait on the locked room or
   deadlock; a join queued behind cleanup waits, then gets `room_not_found`.
5. A heartbeat racing `claim_host`: the claim waits for the heartbeat and then refuses
   (`host_still_active`); the host keeps the room.

The interleavings are forced with an open transaction plus `pg_sleep` (session A holds its locks for
about 2.5 s; session B starts 0.8 s later). Each "queued" check also asserts that B waited at least a
second, so a run where the interleaving did not happen cannot pass.

If you change locking in the migrations, break one of the fixes on purpose and confirm the matching
check fails before trusting a green run.
