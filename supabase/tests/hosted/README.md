# Hosted smoke test

The local stack cannot prove Realtime authorisation: pgTAP exercises the `realtime.messages` policy
by setting the topic by hand. `smoke.mjs` drives six real anonymous clients against a hosted project.

## Run

```
cd supabase/tests/hosted
npm install
SUPABASE_URL=https://<ref>.supabase.co SUPABASE_PUBLISHABLE_KEY=<publishable key> npm run smoke
```

Use the publishable key only (Project Settings > API, or `supabase projects api-keys`). Never put
the service_role key, a secret key or the database password in this command or in the repo.
The project needs anonymous sign-ins enabled. It exits 0 when every check passes.

## What it checks

- Members join the private channel `room:<room_id>`; an outsider, a kicked player joining again and
  an upper-case spelling of the topic are refused.
- Members receive `room_changed`, `players_changed`, `turns_changed` and `room_deleted` after real RPCs.
- A broadcast sent by a client reaches nobody.
- Payloads hold only `room_id` and Realtime's message `id`: no names, user ids, slips or tokens.
- The draw-token flow, including a stale token.
- It reports how many events a kicked player's old socket still receives (known and accepted:
  ids only, until that socket reauthorises).

It uses six anonymous sign-ins per run; the default limit is 30 per hour per IP address. It deletes
its users and room at the end through `delete_my_data`.

A first run against a brand-new project once refused the host's first channel join and then passed
on every later run. If that recurs on an established project, treat it as a bug.
