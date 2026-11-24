// Hosted smoke test: drives real anonymous clients against a hosted Supabase project and checks
// private Broadcast delivery, channel authorisation, payload contents and the draw-token flow.
// It creates its own users and one room, and removes them when it ends.
//
//   SUPABASE_URL=https://<ref>.supabase.co SUPABASE_PUBLISHABLE_KEY=<publishable key> node smoke.mjs
//
// Use the publishable (anon) key only. Never the service_role or secret key.
import { createClient } from '@supabase/supabase-js'

const BASE = process.env.SUPABASE_URL
const KEY = process.env.SUPABASE_PUBLISHABLE_KEY
if (!BASE || !KEY) {
  console.error('Set SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY (publishable key only).')
  process.exit(2)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const results = []
const check = (ok, name, extra = '') => { results.push(ok); console.log(`${ok ? 'ok  ' : 'FAIL'} - ${name}${extra ? ' :: ' + extra : ''}`) }

async function mk(label) {
  const c = createClient(BASE, KEY, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data, error } = await c.auth.signInAnonymously()
  if (error) throw new Error(`anon sign-in failed for ${label}: ${error.message}`)
  await c.realtime.setAuth(data.session.access_token)
  return { label, c, uid: data.user.id, events: [], status: null, ch: null }
}
async function rpc(p, fn, args = {}) {
  const { data, error } = await p.c.rpc(fn, args)
  if (error) throw new Error(`${p.label} ${fn}: ${error.message}`)
  return data
}
async function rpcErr(p, fn, args = {}) {
  const { error } = await p.c.rpc(fn, args)
  return error ? error.message : null
}
function join(p, topic, priv = true, store = p) {
  return new Promise((resolve) => {
    const ch = p.c.channel(topic, { config: { private: priv, broadcast: { self: true } } })
    ch.on('broadcast', { event: '*' }, (m) => store.events.push({ event: m.event, payload: m.payload }))
    let done = false
    ch.subscribe((status, err) => {
      if (done) return
      if (status === 'SUBSCRIBED' || status === 'CHANNEL_ERROR' || status === 'TIMED_OUT' || status === 'CLOSED') {
        done = true; store.status = status; store.err = err?.message; store.ch = ch; resolve(status)
      }
    })
    setTimeout(() => { if (!done) { done = true; store.status = 'NO_REPLY'; store.ch = ch; resolve('NO_REPLY') } }, 12000)
  })
}
const count = (p, ev, since = 0) => p.events.slice(since).filter((e) => e.event === ev).length
const mark = (ps) => Object.fromEntries(ps.map((p) => [p.label, p.events.length]))

const all = []
try {
  const [A, B, D, E, F, C] = await Promise.all(['A-host', 'B', 'D-kicked', 'E', 'F', 'C-outsider'].map(mk))
  all.push(A, B, D, E, F, C)
  check(true, 'six anonymous sign-ins succeeded (anonymous sign-ins are enabled)')

  const snap = await rpc(A, 'create_room', { p_name: 'Alice' })
  const roomId = snap.room.id, code = snap.room.code
  const topic = `room:${roomId}`
  for (const [p, n] of [[B, 'Bob'], [D, 'Dana'], [E, 'Eve'], [F, 'Finn']]) await rpc(p, 'join_room', { p_code: code, p_name: n })
  check((await rpcErr(C, 'get_snapshot', { p_room_id: roomId }))?.includes('not_member'), 'outsider get_snapshot is refused with not_member')

  // --- joins
  for (const p of [A, B, D, E, F]) await join(p, topic)
  check([A, B, D, E, F].every((p) => p.status === 'SUBSCRIBED'), 'five members joined the private channel', [A, B, D, E, F].map((p) => `${p.label}=${p.status}${p.err ? '(' + p.err + ')' : ''}`).join(' '))
  await join(C, topic)
  check(C.status !== 'SUBSCRIBED', 'outsider is refused on the private channel', `${C.status} ${C.err ?? ''}`)
  const Cpub = { events: [] }
  await join(C, topic, false, Cpub)
  console.log(`info - outsider on a PUBLIC channel with the same topic name: ${Cpub.status}`)
  const up = `room:${roomId.toUpperCase()}`
  const Bup = { events: [] }
  await join(B, up, true, Bup)
  check(Bup.status !== 'SUBSCRIBED', 'member is refused on an upper-case spelling of the topic', `${Bup.status} ${Bup.err ?? ''}`)

  // --- room_changed
  let m = mark([A, B, D, E, F])
  await rpc(A, 'update_settings', { p_settings: { slips_per_player: 1, turn_seconds: 30 } })
  await sleep(2500)
  check([A, B, D, E, F].every((p) => count(p, 'room_changed', m[p.label]) >= 1), 'every member received room_changed after update_settings')
  check(C.events.length === 0 && Cpub.events.length === 0 && Bup.events.length === 0, 'outsider (private and public) and the mis-spelled topic received nothing')

  // --- client send must not reach anyone
  m = mark([A, E, F])
  const sent = await B.ch.send({ type: 'broadcast', event: 'room_changed', payload: { room_id: roomId, forged: true } })
  await sleep(2500)
  const forged = [A, E, F].some((p) => p.events.slice(m[p.label]).some((e) => e.payload?.forged))
  check(!forged, 'a broadcast sent by a member client reaches no other member', `send() returned ${sent}`)

  // --- players_changed on kick; kicked player cannot rejoin the channel
  m = mark([A, B, E, F, D])
  await rpc(A, 'kick_player', { p_user_id: D.uid })
  await sleep(2500)
  check([A, B, E, F].every((p) => count(p, 'players_changed', m[p.label]) >= 1), 'remaining members received players_changed after a kick')
  check((await rpcErr(D, 'get_snapshot', { p_room_id: roomId }))?.includes('not_member'), 'kicked player get_snapshot returns not_member')
  const dOld = D.events.length
  const D2 = { events: [] }
  await join(D, topic, true, D2)
  check(D2.status !== 'SUBSCRIBED', 'kicked player is refused when joining the channel again', `${D2.status} ${D2.err ?? ''}`)

  // --- play a game: turns_changed
  await rpc(A, 'set_teams', { p_assignments: { [A.uid]: 0, [B.uid]: 0, [E.uid]: 1, [F.uid]: 1 } })
  await rpc(A, 'start_game')
  const names = { 'A-host': 'ZXQ Alpha', B: 'ZXQ Bravo', E: 'ZXQ Echo', F: 'ZXQ Foxtrot' }
  for (const p of [A, B, E, F]) await rpc(p, 'submit_slips', { p_names: [names[p.label]] })
  let s = await rpc(A, 'get_snapshot', { p_room_id: roomId })
  check(s.room.phase === 'playing' && s.room.round === 1, 'last submission started round 1', `phase=${s.room.phase} round=${s.room.round}`)
  const giver = [A, B, E, F].find((p) => p.uid === s.room.turn_player_id)
  const other = [A, B, E, F].find((p) => p !== giver)
  m = mark([A, B, E, F])
  let draw = await rpc(giver, 'start_turn')
  const tokens = [draw.token]
  check((await rpc(other, 'current_slip')) === null, 'a non clue-giver gets null from current_slip')
  const stale = await rpc(giver, 'got_it', { p_token: '00000000-0000-4000-8000-000000000000' })
  check(stale && stale.token === draw.token, 'a stale token changes nothing and returns the current draw')
  let guard = 0
  while (draw && guard++ < 10) { draw = await rpc(giver, 'got_it', { p_token: draw.token }); if (draw) tokens.push(draw.token) }
  await sleep(2500)
  s = await rpc(A, 'get_snapshot', { p_room_id: roomId })
  check(s.room.phase === 'round_end' && s.turns.length === 1, 'clearing the pile ended the round and wrote one turn', `phase=${s.room.phase} turns=${s.turns.length}`)
  check([A, B, E, F].every((p) => count(p, 'turns_changed', m[p.label]) >= 1), 'every member received turns_changed')

  // --- payload hygiene over everything received so far
  const blob = JSON.stringify([A, B, E, F, D].flatMap((p) => p.events))
  const leaks = ['ZXQ', 'Alice', 'Bob', 'Eve', 'Finn', 'Dana', ...tokens, A.uid, B.uid, D.uid, E.uid, F.uid].filter((x) => blob.includes(x))
  const keys = new Set([A, B, E, F].flatMap((p) => p.events.flatMap((e) => Object.keys(e.payload ?? {}))))
  check(leaks.length === 0, 'no payload contains a slip name, player name, user id or token', leaks.join(','))
  check([...keys].every((k) => k === 'room_id' || k === 'id'), 'payload keys are only room_id and id', [...keys].join(','))
  const evs = new Set([A, B, E, F].flatMap((p) => p.events.map((e) => e.event)))
  console.log(`info - events seen: ${[...evs].sort().join(', ')}`)
  console.log(`info - kicked player's OLD socket, left open, received ${D.events.length - dOld} events after the kick: ${[...new Set(D.events.slice(dOld).map((e) => e.event))].join(', ')}`)

  // --- room_deleted when the last member leaves
  m = mark([A, B, E, F])
  for (const p of [B, E, F]) await rpc(p, 'leave_room')
  await rpc(A, 'leave_room')
  await sleep(2500)
  check(count(A, 'room_deleted', m['A-host']) === 1, 'the last member\'s open socket received exactly one room_deleted', `A=${count(A, 'room_deleted', m['A-host'])} B=${count(B, 'room_deleted', m.B)}`)
  check((await rpcErr(A, 'join_room', { p_code: code, p_name: 'Alice' }))?.includes('room_not_found'), 'the room code no longer exists')
} catch (e) {
  check(false, 'run aborted', e.message)
} finally {
  for (const p of all) { try { await p.c.rpc('delete_my_data') } catch {} ; try { await p.c.removeAllChannels() } catch {} }
  console.log(`\n${results.filter(Boolean).length}/${results.length} checks passed`)
  process.exit(results.every(Boolean) ? 0 : 1)
}
