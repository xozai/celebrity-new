#!/usr/bin/env bash
# Two-session concurrency checks for the game database. pgTAP runs in one session, so it cannot
# express "B queued behind A's open transaction"; this script drives real concurrent sessions.
#
# Needs the local Supabase stack running (`supabase start`) with migrations applied. No other tools:
# uses `psql` if it is installed, otherwise `psql` inside the local database container. The
# connection comes from `supabase status`; set DB_URL to override. It creates its own users and
# rooms (ids starting c0c0c0c0-) and removes them afterwards. Exits non-zero if any check fails.
#
# Every session sets lock_timeout and statement_timeout, so a hang fails fast instead of blocking.

set -u

# ---------------------------------------------------------------------------------- connection
DB_URL="${DB_URL:-$(supabase status -o env 2>/dev/null | sed -n 's/^DB_URL="\(.*\)"$/\1/p')}"
if command -v psql >/dev/null 2>&1 && [ -n "$DB_URL" ]; then
  PSQL=(psql "$DB_URL")
else
  CONTAINER="$(docker ps --filter 'name=supabase_db' --format '{{.Names}}' | head -1)"
  if [ -z "$CONTAINER" ]; then
    echo "No psql and no supabase_db container found. Run 'supabase start' first." >&2
    exit 2
  fi
  PSQL=(docker exec -i "$CONTAINER" psql -U postgres -d postgres)
fi

TMP="$(mktemp -d)"
FAILURES=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILURES=$((FAILURES + 1)); }
note() { echo "       $1"; }

# psql with errors fatal and quiet output; SQL on stdin.
sql() { "${PSQL[@]}" -X -q -A -t -v ON_ERROR_STOP=1 -f - 2>&1; }
admin() { echo "$1" | sql; }

# A session acting as a signed-in user. Body runs inside one transaction (so pg_sleep in the body
# keeps locks held). Usage: as_user <uuid> "<sql>"
as_user() {
  sql <<SQL
set lock_timeout = '10s';
set statement_timeout = '30s';
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"$1","role":"authenticated"}', true);
$2
commit;
SQL
}

now() { date +%s; }

# --------------------------------------------------------------------------------------- ids
id() { printf 'c0c0c0c0-0000-0000-0000-%012d' "$1"; }
ALL_IDS="$(for i in $(seq 1 30); do printf "'%s'," "$(id "$i")"; done)'00000000-0000-0000-0000-000000000000'"

cleanup() {
  admin "delete from public.rooms where host_id in ($ALL_IDS)
         or id in (select room_id from public.players where user_id in ($ALL_IDS));
         delete from public.room_creations where user_id in ($ALL_IDS);
         delete from auth.users where id in ($ALL_IDS);" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

make_users() {
  for n in "$@"; do
    admin "insert into auth.users (id, aud, role, is_anonymous)
           values ('$(id "$n")', 'authenticated', 'authenticated', true) on conflict do nothing;" >/dev/null
  done
}
code_of() { admin "select r.code from public.rooms r join public.players p on p.room_id = r.id where p.user_id = '$(id "$1")';"; }
room_of() { admin "select room_id from public.players where user_id = '$(id "$1")';"; }

cleanup >/dev/null 2>&1; TMP="$(mktemp -d)"   # start from a clean slate (also after an aborted run)
admin "select 1;" >/dev/null || { echo "cannot reach the database" >&2; exit 2; }

# =============================================================================== 1a. join behind delete_my_data
echo "# join_room / create_room queued behind an open delete_my_data by the same user"
make_users 1 2 3
as_user "$(id 2)" "select public.create_room('Yara');" >/dev/null
CODE2="$(code_of 2)"
as_user "$(id 1)" "select public.create_room('Xavier');" >/dev/null
as_user "$(id 3)" "select public.create_room('Zoe');" >/dev/null

( as_user "$(id 1)" "select public.delete_my_data(); select pg_sleep(2.5);" >"$TMP/1a.A" 2>&1; echo $? >"$TMP/1a.A.rc" ) &
PA=$!
sleep 0.8
T0=$(now)
as_user "$(id 1)" "select public.join_room('$CODE2', 'Xavier');" >"$TMP/1a.B" 2>&1; RCB=$?
T1=$(now)
wait $PA
if [ "$RCB" -ne 0 ] && grep -q 'not_authenticated' "$TMP/1a.B"; then pass "join_room queued behind delete_my_data fails with not_authenticated"; else fail "join_room behind delete_my_data: rc=$RCB $(tr '\n' ' ' <"$TMP/1a.B")"; fi
[ $((T1 - T0)) -ge 1 ] && pass "...and it really waited for the deletion ($((T1 - T0))s)" || fail "join_room did not wait (interleaving not forced)"
[ "$(admin "select count(*) from public.players where user_id = '$(id 1)';")" = "0" ] && pass "no seat was created for the deleted account" || fail "a seat exists for the deleted account"
[ "$(admin "select count(*) from auth.users where id = '$(id 1)';")" = "0" ] && pass "the anonymous account is gone" || fail "the account still exists"

( as_user "$(id 3)" "select public.delete_my_data(); select pg_sleep(2.5);" >"$TMP/1b.A" 2>&1 ) &
PA=$!
sleep 0.8
as_user "$(id 3)" "select public.create_room('Zed');" >"$TMP/1b.B" 2>&1; RCB=$?
wait $PA
if [ "$RCB" -ne 0 ] && grep -q 'not_authenticated' "$TMP/1b.B"; then pass "create_room queued behind delete_my_data fails with not_authenticated"; else fail "create_room behind delete_my_data: rc=$RCB $(tr '\n' ' ' <"$TMP/1b.B")"; fi
[ "$(admin "select count(*) from public.players where user_id = '$(id 3)';")" = "0" ] && pass "no room was created for the deleted account" || fail "a seat exists for the deleted account"

# =============================================================================== 2. member RPC queued behind a kick
echo "# a member RPC queued behind that member being kicked"
make_users 4 5
as_user "$(id 4)" "select public.create_room('Hana');" >/dev/null
CODE4="$(code_of 4)"
as_user "$(id 5)" "select public.join_room('$CODE4', 'Mo');" >/dev/null
( as_user "$(id 4)" "select public.kick_player('$(id 5)'); select pg_sleep(2.5);" >"$TMP/2.A" 2>&1 ) &
PA=$!
sleep 0.8
T0=$(now)
as_user "$(id 5)" "select public.end_turn();" >"$TMP/2.B" 2>&1; RCB=$?
T1=$(now)
wait $PA
if [ "$RCB" -ne 0 ] && grep -q 'not_member' "$TMP/2.B"; then pass "end_turn queued behind the kick fails with not_member"; else fail "end_turn behind a kick: rc=$RCB $(tr '\n' ' ' <"$TMP/2.B")"; fi
[ $((T1 - T0)) -ge 1 ] && pass "...and it really waited for the kick ($((T1 - T0))s)" || fail "end_turn did not wait (interleaving not forced)"

# =============================================================================== 3. opposite room switches
echo "# two users switching rooms in opposite directions at the same time"
make_users 6 7 8 9
as_user "$(id 8)" "select public.create_room('HostA');" >/dev/null
as_user "$(id 9)" "select public.create_room('HostB');" >/dev/null
CODEA="$(code_of 8)"; CODEB="$(code_of 9)"
as_user "$(id 6)" "select public.join_room('$CODEA', 'Pat');" >/dev/null
as_user "$(id 7)" "select public.join_room('$CODEB', 'Quinn');" >/dev/null
N=40
: >"$TMP/3.P.sql"; : >"$TMP/3.Q.sql"
for i in $(seq 1 $N); do
  for pair in "P:6:$CODEB:Pat" "P:6:$CODEA:Pat"; do
    IFS=: read -r who u c nm <<<"$pair"
    printf "begin; set local role authenticated; select set_config('request.jwt.claims','{\"sub\":\"%s\",\"role\":\"authenticated\"}',true); select public.join_room('%s','%s'); commit;\n" "$(id $u)" "$c" "$nm" >>"$TMP/3.P.sql"
  done
  for pair in "Q:7:$CODEA:Quinn" "Q:7:$CODEB:Quinn"; do
    IFS=: read -r who u c nm <<<"$pair"
    printf "begin; set local role authenticated; select set_config('request.jwt.claims','{\"sub\":\"%s\",\"role\":\"authenticated\"}',true); select public.join_room('%s','%s'); commit;\n" "$(id $u)" "$c" "$nm" >>"$TMP/3.Q.sql"
  done
done
for who in P Q; do
  { echo "set lock_timeout = '10s'; set statement_timeout = '30s';"; cat "$TMP/3.$who.sql"; } >"$TMP/3.$who.full.sql"
done
( "${PSQL[@]}" -X -q -A -t -f - <"$TMP/3.P.full.sql" >"$TMP/3.P.out" 2>&1; echo $? >"$TMP/3.P.rc" ) &
PP=$!
( "${PSQL[@]}" -X -q -A -t -f - <"$TMP/3.Q.full.sql" >"$TMP/3.Q.out" 2>&1; echo $? >"$TMP/3.Q.rc" ) &
PQ=$!
wait $PP $PQ
if grep -qi 'deadlock' "$TMP/3.P.out" "$TMP/3.Q.out"; then fail "a deadlock was detected while switching rooms"; else pass "no deadlock across $((N * 4)) opposite switches"; fi
ERRS=$(grep -c 'ERROR' "$TMP/3.P.out" "$TMP/3.Q.out" | awk -F: '{s+=$2} END {print s}')
[ "$ERRS" = "0" ] && pass "every switch succeeded" || { fail "$ERRS switch(es) failed"; grep -h ERROR "$TMP/3.P.out" "$TMP/3.Q.out" | sort | uniq -c | head -5; }
[ "$(admin "select count(*) from public.players where user_id in ('$(id 6)','$(id 7)');")" = "2" ] && pass "both users still sit in exactly one room each" || fail "unexpected seat count after switching"

# =============================================================================== 4. cleanup_rooms vs join into an expiring room
echo "# cleanup_rooms running against a join into an expiring room"
make_users 10 11 12 13 14 15
for n in 10 11 12; do as_user "$(id $n)" "select public.create_room('Host$n');" >/dev/null; done
as_user "$(id 13)" "select public.create_room('Jay');" >/dev/null
as_user "$(id 14)" "select public.create_room('Kit');" >/dev/null
E1="$(room_of 10)"; E2="$(room_of 11)"; E3="$(room_of 12)"; CODE_E2="$(code_of 11)"; CODE_E3="$(code_of 12)"
admin "update public.rooms set last_activity_at = now() - interval '30 hours' where id in ('$E1', '$E2');" >/dev/null

# 4a. the join holds its rooms; cleanup must not wait for them or deadlock.
( as_user "$(id 13)" "select public.join_room('$CODE_E2', 'Jay'); select pg_sleep(2.5);" >"$TMP/4a.A" 2>&1; echo $? >"$TMP/4a.A.rc" ) &
PA=$!
sleep 0.8
T0=$(now)
OUT="$(admin "select public.cleanup_rooms();")"; RCB=$?
T1=$(now)
wait $PA
[ "$(cat "$TMP/4a.A.rc")" = "0" ] && pass "the join into the expiring room succeeded" || fail "the join failed: $(tr '\n' ' ' <"$TMP/4a.A")"
if echo "$OUT" | grep -qi 'error\|deadlock'; then fail "cleanup_rooms errored while a join held the room: $OUT"; else pass "cleanup_rooms ran against the locked room without error"; fi
[ $((T1 - T0)) -le 1 ] && pass "...and did not wait for it ($((T1 - T0))s)" || fail "cleanup_rooms waited $((T1 - T0))s on a locked room"
[ "$(admin "select count(*) from public.rooms where id = '$E2';")" = "1" ] && pass "the room that was being joined survived" || fail "the room being joined was deleted"
[ "$(admin "select count(*) from public.rooms where id = '$E1';")" = "0" ] && pass "an unlocked expired room was deleted" || fail "the unlocked expired room was not deleted"

# 4b. cleanup holds the rooms; a join arriving meanwhile waits, then finds the room gone.
# (E3 only expires now: the cleanup in 4a would otherwise have deleted it already.)
admin "update public.rooms set last_activity_at = now() - interval '30 hours' where id = '$E3';" >/dev/null
( admin "begin; select public.cleanup_rooms(); select pg_sleep(2.5); commit;" >"$TMP/4b.A" 2>&1 ) &
PA=$!
sleep 0.8
T0=$(now)
as_user "$(id 14)" "select public.join_room('$CODE_E3', 'Kit');" >"$TMP/4b.B" 2>&1; RCB=$?
T1=$(now)
wait $PA
if [ "$RCB" -ne 0 ] && grep -q 'room_not_found' "$TMP/4b.B"; then pass "a join queued behind cleanup finds the room gone (room_not_found)"; else fail "join behind cleanup: rc=$RCB $(tr '\n' ' ' <"$TMP/4b.B")"; fi
grep -qi 'deadlock' "$TMP/4b.A" "$TMP/4b.B" && fail "deadlock between cleanup and join" || pass "no deadlock"
[ $((T1 - T0)) -ge 1 ] && pass "...and it really waited for cleanup ($((T1 - T0))s)" || fail "join did not wait (interleaving not forced)"

# =============================================================================== 5. heartbeat vs claim_host
echo "# a heartbeat racing claim_host"
make_users 20 21
as_user "$(id 20)" "select public.create_room('Hera');" >/dev/null
CODE20="$(code_of 20)"; ROOM20="$(room_of 20)"
as_user "$(id 21)" "select public.join_room('$CODE20', 'Ike');" >/dev/null
admin "update public.players set last_seen_at = now() - interval '60 seconds' where user_id = '$(id 20)';" >/dev/null
( as_user "$(id 20)" "select public.heartbeat('$ROOM20'); select pg_sleep(2.5);" >"$TMP/5.A" 2>&1 ) &
PA=$!
sleep 0.8
T0=$(now)
as_user "$(id 21)" "select public.claim_host();" >"$TMP/5.B" 2>&1; RCB=$?
T1=$(now)
wait $PA
if [ "$RCB" -ne 0 ] && grep -q 'host_still_active' "$TMP/5.B"; then pass "claim_host that raced a heartbeat saw the fresh heartbeat (host_still_active)"; else fail "claim_host vs heartbeat: rc=$RCB $(tr '\n' ' ' <"$TMP/5.B")"; fi
[ $((T1 - T0)) -ge 1 ] && pass "...and it really waited for the heartbeat ($((T1 - T0))s)" || fail "claim_host did not wait (interleaving not forced)"
[ "$(admin "select host_id from public.rooms where id = '$ROOM20';")" = "$(id 20)" ] && pass "the host kept the room" || fail "the host lost the room despite the heartbeat"

# ------------------------------------------------------------------------------------- summary
echo
if [ "$FAILURES" -eq 0 ]; then echo "concurrency: all checks passed"; exit 0; fi
echo "concurrency: $FAILURES check(s) FAILED"
exit 1
