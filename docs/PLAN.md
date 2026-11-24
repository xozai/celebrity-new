# Celebrity iOS (clean rewrite) Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Ship a new native SwiftUI Celebrity party game to the App Store (iOS 17+), with online rooms (one phone per player) backed by a managed service instead of the current Node/Socket.IO server.

**Architecture:** A new repo holding a SwiftUI app, two local Swift packages (pure game model + backend client), and a Supabase project (Postgres tables, row-level security, SQL functions, Realtime). All game rules run server-side inside SQL functions so the pile stays secret and two phones can never disagree; the app only renders room state and calls functions.

**Tech Stack:** Swift 5.10+/SwiftUI, `@Observable`, Swift Testing, XcodeGen, supabase-swift v2, Supabase (Postgres, anonymous auth, Realtime, pg_cron), pgTAP, GitHub Actions.

---

## 1. Decisions taken (from clarification)

| Topic | Decision |
|---|---|
| Scope | Clean rewrite in a new repo. `xozai/celebrity-game-ios` and `xozai/celebrity-game-claude` are functional references only. |
| Repo | `xozai/celebrity-new`, public. The user asked for "celebrity new"; GitHub repo names cannot contain spaces, so the hyphenated form is used. |
| Hosting for celeb.xozai.com | Cloudflare Pages; DNS for xozai.com is already on Cloudflare. |
| First version | 1.0.0 (build 1). No build with this bundle id was ever uploaded to App Store Connect, so a new app record is created. |
| App name | Celebrity Celebrity |
| Bundle id | `com.xozai.CelebrityGame`, reused from the reference app. |
| Play modes | Online rooms only. No pass-and-play. |
| Backend | Supabase, confirmed (reasoning in section 3). |
| Release | App Store, iOS 17+. Apple Developer membership is active. |
| Skipping | Host setting: off (strict rules), one per turn, unlimited. |
| Web client | Retired, along with the Render server (Phase 9). |
| Domain | `celeb.xozai.com` for invite links and the privacy policy. |
| Duplicate names | Allowed, both across players and within one player's slips. |
| Name recommendations | Players get celebrity recommendations while submitting, drawn from Wikipedia and IMDb (design in section 6a). English names only. |
| Monetisation | The app is free, with no ads and no purchases. IMDb's non-commercial datasets are used on that basis. |
| Licence | MIT for the code. The app name and icon are excluded. |

## 2. What the reference repos do today

Read at `celebrity-game-claude@f731d43` and `celebrity-game-ios@afb3fce`.

Backend (`server.js`, 883 lines, one file):
- Rooms with 4-character codes, kept in memory with optional Redis (24 h TTL).
- Phases: `lobby` -> `submitting` -> `playing` -> `finished`. Three rounds.
- Host actions: assign teams, name teams, slips per player (1-10), turn length (30/60/90 s), submission time limit (30-600 s, default 120), start game, start next round, kick, transfer host, reset room for a rematch.
- Player actions: submit names, retract submission, start turn, got it, skip.
- The current slip is sent only to the clue-giver (`your_slip`). Everyone else sees counts.
- Submission countdown auto-starts the game with whatever was submitted.
- Reconnect by re-joining with the same name. Clue-giver disconnect pauses the turn for 30 s.
- Late joiners become spectators. Host is reassigned if the host drops.
- Per-turn history, rate limit of 5 rooms per IP per hour, cleanup job, Wikipedia autocomplete proxy (`/api/suggest`).
- 45 integration tests in `test/integration.js` and a manual QA plan in `test/qa-plan.md`.

iOS app (10 Swift files, about 2,150 lines):
- Screens: Home, Lobby, Submit, Game, plus sheets for round intro, turn recap, round end, game end, and How to Play.
- One `GameViewModel` owns the socket, all state, the timer, haptics and theme.
- Extras: QR code and share sheet for the room code, autocomplete, light/dark/system theme, share final result, auto-rejoin after relaunch, some VoiceOver labels.
- No tests. `build/` output and a duplicate `CelebrityGame 2.xcodeproj` are committed.

Gaps against the written rules and problems worth fixing in the rewrite:
1. Identity is the socket id and reconnection matches on name, so anyone who types another player's name takes over their seat.
2. `start_next_round` does not check that the round has ended, so the host can reshuffle the pile mid-round.
3. `start_game` only needs one player per team. A team of one has nobody to guess.
4. Slips are plain strings. Two players submitting the same name share one identity, and retract or kick removes by string match.
5. Skipping is unlimited. The rules have no skip at all.
6. The timer trusts the phone's clock against a server timestamp, so a phone with a wrong clock sees a wrong countdown.
7. Turn expiry depends on an in-process `setTimeout`, which is lost when Render restarts the server without Redis.

## 3. Backend choice: Supabase

| Need | Supabase | Firebase | CloudKit |
|---|---|---|---|
| Hide the pile from other players | Row-level security plus SQL functions that return the slip only to the clue-giver | Needs Cloud Functions for every draw | No server-side logic |
| Atomic "got it" (pop pile, score, maybe end round) | One SQL function with a row lock | Callable function with a transaction; cold starts on a tap that happens every few seconds | Client-side only |
| Stable player identity | Anonymous sign-in | Anonymous sign-in | iCloud account required |
| Live updates | Private Realtime Broadcast | Firestore listeners | Push-based, slow for this |
| Tests for the rules | pgTAP, runs locally and in CI | Emulator suite | None |
| A future web or Android client | Yes | Yes | No |

Supabase wins on latency for the hot path and on testability, and the user has confirmed it. The app-side `GameBackend` protocol (Task 3.1) still keeps the backend swappable.

To verify before committing: current Supabase free-tier limits. As I understand them, free projects pause after about a week without activity, which is not acceptable for a released app, so budget for the paid tier at launch.

## 4. Recommended features

### Must have (parity with the reference apps)
1. Create a room and get a 4-character code. Join by code.
2. Lobby: player list, host badge, host assigns two teams, custom team names.
3. Host settings: slips per player (1-10, default 3), turn length (30/60/90 s), submission time limit.
4. Private slip submission with retract-and-edit until the game starts.
5. Submission countdown that auto-starts with the slips received. An empty window returns to the lobby.
6. Three rounds with a rule banner: Say Anything, One Word, Charades.
7. Clue-giver screen: big slip text, countdown, Got It.
8. Guesser and opponent screens: who is up, countdown, slips left, live count for this turn.
9. Unfinished slip returns to the pile when the timer ends.
10. Turn recap, round-end scoreboard, game-end screen with winner or tie and per-round breakdown.
11. Full turn history at game end, and share the result.
12. Rematch in the same room with the same players.
13. Reconnect and resume after backgrounding, network loss, or app relaunch.
14. Kick player, transfer host, automatic host handoff when the host disappears.
15. Late joiners watch as spectators.
16. Share the room by code, QR code, and share sheet.
17. Celebrity recommendations while submitting, sourced from Wikipedia and IMDb:
    - As-you-type suggestions under the field, each with a short description ("American actor"), most famous first.
    - A "Need ideas?" row of popular names with a shuffle button; tapping one fills the next empty slip.
    - Free text is always accepted. Recommendations never draw on other players' slips.
    - Host can switch recommendations off for groups that want to think for themselves.
18. How to Play screen, haptics, light/dark/system theme.

### Should have (new in the rewrite)
19. Skip setting: off, one per turn, unlimited. Default off, matching the written rules.
20. Device-bound identity so a seat cannot be taken by typing someone's name.
21. Countdown corrected for clock differences between phone and server.
22. Minimum of two players per team to start, with a warning when teams are uneven.
23. Auto-balance and shuffle teams buttons for the host.
24. Teams alternate round starts when eligible, and the clue-giver rotation continues across rounds.
25. Host can move a spectator onto a team between turns.
26. Sounds: tick for the last ten seconds and a buzzer at zero, with a mute switch.
27. Screen stays awake during a game.
28. Join by link or QR scan from the camera (`https://celeb.xozai.com/join/CODE`), landing directly in the room, or on an App Store page if the app is not installed.
29. Duplicate names are accepted as separate slips, as at a real table. No warning and no blocking.
30. Full VoiceOver labels, Dynamic Type, and reduced-motion support.
31. Room-creation rate limit and automatic cleanup of old rooms.
32. "Delete my data" in settings, for App Store privacy review.

### Later (not in this plan)
33. Carry leftover time into the next round when a player empties the pile.
34. Fishbowl mode (any word or phrase) and themed starter packs for groups short on ideas.
35. Per-player stats and an MVP callout at game end.
36. More than two teams.
37. Host "undo last Got It" for mis-taps.
38. iPad layout, Live Activity for the countdown, localisation.
39. Pass-and-play on one device.

## 5. Repository layout (new repo `xozai/celebrity-new`)

```
project.yml                         XcodeGen spec (no .xcodeproj in git)
.gitignore                          build/, DerivedData/, *.xcodeproj, .env, supabase/.temp
App/
  CelebrityApp.swift
  AppModel.swift                    @Observable root: session, navigation, lifecycle
  Config.swift                      reads SUPABASE_URL / SUPABASE_ANON_KEY from Info.plist
  Features/
    Home/HomeView.swift
    Lobby/LobbyView.swift, TeamEditor.swift, SettingsSheet.swift, InviteSheet.swift
    Submit/SubmitView.swift, SlipField.swift, IdeasRow.swift,
      NameSuggester.swift, WikipediaSearch.swift
    Game/GameView.swift, ClueGiverView.swift, WatcherView.swift, TimerRing.swift
    Recap/RoundIntroSheet.swift, TurnRecapSheet.swift, RoundEndSheet.swift, GameEndView.swift
    HowToPlay/HowToPlayView.swift
    AppSettings/AppSettingsView.swift
  Services/Haptics.swift, SoundPlayer.swift, ServerClock.swift
  Resources/Assets.xcassets, PrivacyInfo.xcprivacy, Sounds/
Packages/
  CelebrityCore/                    no dependencies, tested with `swift test`
    Sources/CelebrityCore/Room.swift, Player.swift, Turn.swift, Settings.swift,
      RoomSnapshot.swift, RoomEvent.swift, RoomEventDeriver.swift, Screen.swift,
      Validation.swift, RoundRules.swift
    Tests/CelebrityCoreTests/
  CelebrityBackend/                 one package, two library products
    Sources/CelebrityBackend/       depends only on CelebrityCore
      GameBackend.swift, BackendTypes.swift, BackendError.swift,
      TeamAssignments.swift, FakeGameBackend.swift, SampleScenario.swift
    Sources/CelebrityBackendSupabase/  adapter, the only product linking supabase-swift
    Tests/CelebrityBackendTests/    interface, fake and fixture tests
    Tests/CelebrityBackendSupabaseTests/  adapter tests, including local Supabase integration
supabase/
  config.toml
  migrations/0001_schema.sql, 0002_rls.sql, 0003_rooms.sql, 0004_lobby.sql,
    0005_submission.sql, 0006_turns.sql, 0007_rounds.sql, 0008_host.sql, 0009_cleanup.sql,
    0010_celebrities.sql, 0011_realtime.sql
  tests/*.test.sql                  pgTAP
  tests/fixtures/snapshot.example.json
  tests/concurrency/run.sh          two-session database checks
tools/celebrity-list/               builds the recommendation list (Python 3, standard library only)
  build.py, sources_wikipedia.py, sources_imdb.py, merge.py, load.py
  tests/                            unit tests with small fixture files
  blocklist.txt                     names to never recommend
CelebrityUITests/
site/                               static site for celeb.xozai.com
  .well-known/apple-app-site-association
  join/index.html                   fallback page with the App Store link
  privacy/index.html
  index.html
docs/qa-plan.md
.github/workflows/ci.yml
.github/workflows/refresh-celebrities.yml   monthly rebuild of the recommendation list
```

## 6. Data model and server functions

Tables:

- `rooms`: `id uuid`, `code` (unique, 4 chars from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`), `host_id uuid` (nullable), `phase` (`lobby`, `submitting`, `playing`, `round_end`, `finished`), `round` (0-3), `team_names text[2]`, `slips_per_player`, `turn_seconds`, `submission_seconds`, `skip_mode` (`off`, `one_per_turn`, `unlimited`), `suggestions_enabled boolean` (default true), `submission_deadline`, `current_team`, `turn_idx int[2]`, `turn_player_id uuid`, `turn_ends_at`, `turn_got`, `turn_skips`, `pile_count`, `scores jsonb`, `last_activity_at`, `finished_at`, `created_at`. The deadline, current team, turn player, turn end and finish time are nullable. Scores are `[[r1_team0,r1_team1],[r2_team0,r2_team1],[r3_team0,r3_team1]]` and include scores from the active turn. There is no `created_by` column.
- `players`: primary key (`room_id`, `user_id`), both UUIDs, plus `name`, `team` (0, 1 or null), `role` (`player`, `spectator`), `seat` (join order, starting at 1), `submitted`, `last_seen_at`. Unique on (`room_id`, `lower(name)`), (`room_id`, `seat`) and `user_id`.
- `slips`: `id uuid`, `room_id`, `author_id uuid` (nullable), `name`, `in_pile`, `pile_order` (nullable, shuffled each round), `is_current`, `draw_token uuid` (present exactly while current), `guessed_at` (nullable), `skipped_in_turn`. No client can select from this table.
- `turns`: `id bigint` (generated identity), `room_id`, `round`, `team`, `player_id uuid` (nullable), `player_name`, `guessed text[]`, `skipped int` (number of skip actions), `ended_at`. History includes guessed names. After data deletion, that player's turns have a null `player_id` and the name `Former player`.
- `room_creations`: `user_id uuid`, `created_at timestamptz`. A private quota log that survives room deletion.
- `celebrities`: the curated recommendation table (section 6a).

Row-level security: signed-in members with a live account can read their room, players and turns. Clients cannot write the tables directly or read slips, the quota log or the recommendation table. Anonymous sign-in uses the `authenticated` database role. The app RPCs below require that role and a live, non-deleted `auth.users` row. Room mutations lock the room and check membership under the lock where applicable. Membership changes by the same caller are serialised, and moves lock both rooms in UUID order.

App RPCs in `public` (use the SQL argument names as JSON keys). Domain errors use SQLSTATE `P0001` with the code in the message. Every row can raise `not_authenticated` for a missing or deleted account. A call under the unsigned `anon` role has no execute grant (`42501`).

| Function | Caller and result | Other domain errors |
|---|---|---|
| `create_room(p_name text)` | Signed-in user, up to five rooms per rolling hour. Returns snapshot JSON. | `invalid_name`, `rate_limited`, `code_unavailable` |
| `join_room(p_code text, p_name text)` | Signed-in user. Returns snapshot JSON. Returns the existing seat for a caller already in the room. A new member outside the lobby is a spectator. | `room_not_found`, `invalid_name`, `name_taken` |
| `leave_room()` | Member. Returns void. | `not_member` |
| `get_snapshot(p_room_id uuid)` | Member. Returns snapshot JSON. | `not_member` |
| `heartbeat(p_room_id uuid)` | Member. Updates presence and returns a single server timestamp (`timestamptz`). | `not_member` |
| `set_teams(p_assignments jsonb)` | Host in lobby. Partial object mapping player UUID strings to 0, 1 or null. A team assignment promotes a spectator. Returns void. | `not_member`, `not_host`, `wrong_phase`, `invalid_team`, `player_not_found` |
| `set_team_name(p_team int, p_name text)` | Host in lobby. Trims the name and takes its first 20 characters. Returns void. | `not_member`, `not_host`, `wrong_phase`, `invalid_team`, `invalid_name` |
| `update_settings(p_settings jsonb)` | Host in lobby. Partial object with keys `slips_per_player`, `turn_seconds`, `submission_seconds`, `skip_mode`, `suggestions_enabled`. Returns void. | `not_member`, `not_host`, `wrong_phase`, `invalid_setting` |
| `start_game()` | Host in lobby, with at least two players per team. Unassigned players become spectators. Sets the submission deadline and returns void. | `not_member`, `not_host`, `wrong_phase`, `not_enough_players` |
| `submit_slips(p_names text[])` | Assigned player during the open submission window. Returns void. | `not_member`, `wrong_phase`, `submissions_closed`, `not_a_player`, `already_submitted`, `wrong_slip_count`, `invalid_slip` |
| `retract_slips()` | Member during the open submission window. Removes only the caller's slips and returns void. | `not_member`, `wrong_phase`, `submissions_closed` |
| `close_submissions()` | Member at or after the deadline. Starts with the slips received or returns the room to the lobby if the pile is empty. Returns void. | `not_member`, `wrong_phase` (lobby), `deadline_not_reached` |
| `start_turn()` | Assigned clue-giver before their turn starts. Returns a draw JSON object or null. | `not_member`, `wrong_phase`, `not_your_turn`, `turn_already_started` |
| `got_it(p_token uuid)` | Clue-giver during a running turn. Scores the current draw and returns the next draw, or null when the pile empties. | `not_member`, `wrong_phase`, `not_your_turn`, `turn_not_started`, `turn_over`, `invalid_token` |
| `skip_slip(p_token uuid)` | Clue-giver during a running turn. Returns the draw JSON object or null. | `not_member`, `wrong_phase`, `not_your_turn`, `turn_not_started`, `turn_over`, `invalid_token`, `skip_not_allowed` |
| `current_slip()` | Member. Returns the draw to the clue-giver during a running, unexpired turn, or null otherwise. | `not_member` |
| `end_turn()` | Member at or after turn expiry. Returns void. No-op when there is no running turn. | `not_member`, `deadline_not_reached` |
| `start_next_round()` | Host in `round_end`. Returns void. | `not_member`, `not_host`, `wrong_phase` |
| `reset_room()` | Host in `finished`. Clears slips, scores, history and finish time, keeps the seats, teams and settings, and returns to the lobby. Returns void. | `not_member`, `not_host`, `wrong_phase` |
| `assign_spectator(p_user_id uuid, p_team int)` | Host, with no running turn. Moves a spectator to team 0 or 1. Returns void. | `not_member`, `not_host`, `invalid_team`, `player_not_found`, `not_spectator`, `turn_active` |
| `transfer_host(p_user_id uuid)`, `kick_player(p_user_id uuid)` | Host. Target must be another room member. Return void. | `not_member`, `not_host`, `cannot_target_self`, `player_not_found` |
| `claim_host()` | Member when the host's presence is older than 45 s or the host seat is missing. Returns void. | `not_member`, `already_host`, `host_still_active` |
| `delete_my_data()` | Signed-in user, including one without a room. Leaves the room and anonymises turn history. Deletes the caller's anonymous Auth account and quota rows. A non-anonymous account keeps its login and quota rows until the normal quota expiry. Returns void. | None |
| `suggest_celebrities(q text, max int default 6)` | Signed-in user. Returns rows with `name text, description text, category text, sources text[]`. | None |
| `random_celebrities(n int default 8, exclude text[] default '{}')` | Signed-in user. Returns the same row shape as suggestions. | None |

`cleanup_rooms()` is a service-role RPC that returns the number of rooms deleted as an integer. Every 10 minutes pg_cron runs it to remove rooms finished over an hour ago (using `finished_at`, with an activity-time fallback) or idle over 24 hours. It skips locked rooms and prunes quota entries older than an hour. `is_room_member(p_room_id uuid) → boolean` and `my_room_ids() → setof uuid` are policy helpers executable by `authenticated`. An invalid account or missing membership gives false or an empty set.

Snapshot: `get_snapshot`, `create_room` and `join_room` return one JSON object with `room` (all room columns), `players` (rows ordered by `seat`), `turns` (rows ordered by numeric `id`) and `server_now`. Keys use the column names above. Empty collections are arrays. Slips and draw tokens are never included. Timestamps use ISO 8601 with a UTC offset and up to microsecond precision (see `supabase/tests/fixtures/snapshot.example.json`). Decode with `RoomSnapshot.makeDecoder()` and use its date strategy for standalone timestamps such as `heartbeat`. Swift groups the flat room settings in `Room.settings` and uses `Int64` for turn IDs.

Membership: each user has one seat across all rooms. Creating or joining another room takes the caller out of their previous room. Leaving or being kicked closes an active turn belonging to that clue-giver, with scores and history retained. Removal during submission deletes that player's slips. Outside submission it detaches their authorship and keeps the pile intact. If the host leaves, the lowest remaining seat becomes host. The last member's departure deletes the room and its rows, so the code can no longer be joined.

Submission: the last eligible submission starts round 1 immediately. Submit and retract are closed at `submission_deadline`. At zero, any member can call `close_submissions()`. An expired window with no slips clears the deadline and submitted flags, and returns the room to the lobby. A duplicate close after play starts is a no-op. A duplicate after the empty-window reset can return `wrong_phase`. The deadline can remain populated after play starts. Use it only while submitting.

Turns: the round starter alternates by team and the rotation carries across rounds in seat order. A team with fewer than two players is skipped when assigning a turn. Use `nextUp` for the server assignment and `turn_ends_at` to tell whether that turn is running. If neither team can play, the room stays in `playing` with a null `turn_player_id` and `nextUp` is nil. The host can assign a spectator between turns. Scoring happens on Got It, the completed turn is written to history, and an empty pile ends the round or finishes the game after round 3.

Draws: the clue-giver alone receives `{"id": "<slip UUID>", "name": "<slip name>", "token": "<draw UUID>"}`. Every draw has a new token, even when skipping the last slip redraws the same slip. Both actions require the displayed draw's `p_token` with no default. After checking turn ownership and expiry, they reject null with `invalid_token`. A stale token changes nothing and returns the current draw before applying any skip limit. Skipping puts the slip at the back of the pile. Turn end returns the unfinished slip to the pile. The timer keeps running on disconnect, and `current_slip()` retrieves the current draw on reconnect. The turn expires at `turn_ends_at`. Every phone can call `end_turn()` at zero.

Live updates: call Realtime `setAuth` with the session token, then join private Broadcast on `room:<room_id>` using a lowercase UUID. Every event is an invalidation. Coalesce bursts and refetch `get_snapshot` on any event, reconnect and return to foreground. Recaps are derived from snapshots by `RoomEventDeriver`.

| Event | Sent when |
|---|---|
| `room_changed` | The room row is updated. |
| `room_deleted` | The room is deleted. One event covers the room and its cascading seat deletions. |
| `players_changed` | A player joins, leaves or is removed while the room remains, or their name, team, role, seat or submitted status changes. |
| `turns_changed` | A turn row is inserted or updated. |

Each payload contains only `room_id` plus Realtime's own message `id`. Heartbeats do not broadcast. Clients cannot publish on the channel. Joining requires membership and a live account. A previously authorised socket can still see invalidation timing until it reauthorises. For the currently joined room, `get_snapshot` returning `not_member` means the seat is gone. Treat it as kicked unless a known deletion or intentional leave explains it. Broadcast send failures are logged without rolling back the game write, so reconnect and foreground refetches still matter.

### 6a. Celebrity recommendations

Two layers feed the Submit screen.

**Layer 1: a curated list in Supabase (Wikipedia + IMDb).** A `celebrities` table designed for roughly 5,000 well-known names, built by a script with a monthly refresh workflow and queried through two functions. This is what makes recommendations fast, ranked by fame, and limited to actual people and characters.

- Table `celebrities`: `id bigint` (generated identity), `name text` (1-100 chars), `name_norm text` (unique), `description text`, `category` (`film_tv`, `music`, `sports`, `public_figure`, `fictional`, `other`), `popularity double precision` (0-1), `sources text[]` (`wikipedia`, `imdb`). No direct client access. A GIN pg_trgm index on `name_norm`.
- Normalisation order: unaccent or transliterate, lowercase, collapse whitespace to single spaces, then trim. Keep punctuation apart from transliteration mappings. SQL uses PostgreSQL unaccent and the offline builder uses Unicode decomposition and a Latin mapping table. Full Unicode and locale parity is unverified.
- `suggest_celebrities(q text, max int default 6)`: matches the start of the name or the start of any word in it ("jobs" finds Steve Jobs), ordered by descending popularity, then name. Requires 2+ normalised characters. Clamp `max` to 1-10, default 6.
- `random_celebrities(n int default 8, exclude text[] default '{}')`: a popularity-weighted random sample without replacement for the "Need ideas?" row. Compare excluded names after normalisation. Clamp `n` to 1-20, default 8.
- `rooms.suggestions_enabled boolean default true`, set by the host in the lobby through `update_settings`. The app uses this flag to decide whether to request or show recommendations.

How the list is built (`tools/celebrity-list/build.py`):

- **Wikipedia:** take the most-viewed English Wikipedia articles for each of the last 12 months from the Wikimedia Pageviews API, then keep only those whose Wikidata item is a human or a fictional character. The Wikidata short description becomes `description`. This source covers musicians, athletes, politicians, historical figures and fictional characters. Expect 2,000-3,000 names.
- **IMDb:** download `name.basics.tsv.gz`, `title.basics.tsv.gz` and `title.ratings.tsv.gz` from `datasets.imdbws.com`. Score each person by the summed vote counts of their known-for titles, drop anyone whose known-for titles are all flagged adult, and keep the top 3,000. This source covers actors and directors.
- **Merge:** join on `name_norm`, record both sources where they overlap, set `popularity` to the higher of the two rank-normalised scores, apply `blocklist.txt`, and upsert into the table.

**Layer 2: live Wikipedia search for the long tail.** When Layer 1 returns fewer than 6 matches, the app also queries the Wikipedia API (`generator=prefixsearch` with `prop=description|pageprops`), drops disambiguation pages, and appends the results after the curated ones with duplicates removed. It uses a descriptive User-Agent, a 300 ms debounce, a 3-second timeout and an in-memory cache, and fails silently. No backend proxy.

**IMDb is used through its dataset files only.** imdb.com has no free search API, and scraping the site or calling its undocumented endpoints from the app would break its conditions of use. See the licensing risk in section 8.

Attribution: the app settings screen and the privacy page credit both sources. IMDb's non-commercial licence asks for a specific credit line; copy the current wording from IMDb's licensing page when implementing.

## 7. Tasks

Each task ends with a commit using Conventional Commits (the reference repos use release-please). Tests are written first in every task that has them.

### Phase 0: Bootstrap

Done.

**Task 0.1: Create the repo and tooling**
- Run: `gh repo create xozai/celebrity-new --public --clone`.
- Because the repo is public: `.gitignore` must cover `.env*`, `*.xcconfig` holding keys, `supabase/.temp`, and `tools/celebrity-list/celebrities.csv` plus downloaded IMDb files (IMDb's licence does not allow republishing its data). The Supabase anon key is designed to be public and may ship in the app; the service-role key and database URL live only in GitHub and Cloudflare secrets. Add a `LICENSE` file with the MIT licence (confirmed by the user), and a README note that the app name "Celebrity Celebrity" and the app icon are not covered by it.
- Create: `.gitignore`, `README.md`, `project.yml` (bundle id `com.xozai.CelebrityGame`, display name `Celebrity Celebrity`, iOS 17.0, iPhone only), `App/CelebrityApp.swift` with a placeholder view.
- Verify: `xcodegen generate && xcodebuild -scheme Celebrity -destination 'platform=iOS Simulator,name=iPhone 17' build` succeeds. Check the simulator name with `xcrun simctl list devices available` first.

**Task 0.2: Empty packages**
- Create: `Packages/CelebrityCore/Package.swift`, `Packages/CelebrityBackend/Package.swift` (supabase-swift `from: "2.0.0"`), one placeholder test each; wire both into `project.yml`.
- Verify: `swift test --package-path Packages/CelebrityCore` passes.

**Task 0.3: Local Supabase**
- Run: `supabase init`, `supabase start` (needs Docker running).
- Create: `supabase/tests/000_smoke.test.sql` asserting pgTAP loads.
- Verify: `supabase test db` reports 1 passing test.

**Task 0.4: CI**
- Create: `.github/workflows/ci.yml` with three jobs: `swift test` for CelebrityCore, `supabase test db`, `xcodebuild build`. Copy `pr-title.yml` and the release-please config from the reference repo.

### Phase 1: Database and rules

Done.

Verify with `supabase db reset && supabase test db`. Private Broadcast is in `0011_realtime.sql` and is covered by `011_realtime.test.sql`.

**Task 1.1: Schema** - `0001_schema.sql`, `001_schema.test.sql` (tables, checks, unique indexes exist).

**Task 1.2: Row-level security** - `0002_rls.sql`, `002_rls.test.sql`. Tests: a member reads their room; a non-member reads nothing; nobody can select from `slips`; direct insert, update and delete are denied on all four tables.

**Task 1.3: Rooms** - `create_room`, `join_room`, `leave_room`, `get_snapshot`, `heartbeat`. Tests: code format, empty name rejected, unknown code rejected, duplicate name rejected for a different user, same user rejoining gets the same seat, late joiner is a spectator, sixth room in an hour rejected.

**Task 1.4: Lobby** - `set_teams`, `set_team_name`, `update_settings`, `start_game`. Tests: non-host rejected, out-of-range values rejected, team name trimmed to 20 chars, start needs 2+ per team, start sets `submitting` and the deadline.

**Task 1.5: Submission** - `submit_slips`, `retract_slips`, `close_submissions`. Tests: wrong count rejected, spectator rejected, retract removes only that player's slips, last submission starts round 1 with `pile_count` equal to total slips, close before the deadline rejected, close with zero slips returns to the lobby, close after the deadline starts with partial slips.

**Task 1.6: Turns** - `start_turn`, `got_it`, `skip_slip`, `current_slip`, `end_turn`. Tests: only the current player can start; got it increments the count and returns a different slip; skip rejected when `skip_mode` is `off`; second skip rejected under `one_per_turn`; skipped slip stays in the pile; `end_turn` before the deadline rejected; at expiry the current slip returns to the pile, a `turns` row is written, and play passes to the next eligible clue-giver. Got It adds the score immediately; a second `end_turn` is a no-op; `got_it` after the deadline rejected; non-clue-giver calling `current_slip` gets nothing.

**Task 1.7: Rounds and game end** - emptying the pile sets `round_end` (or `finished` after round 3); `start_next_round`; `reset_room`. Tests: `start_next_round` rejected during `playing`; pile refilled with every slip; rotation continues; total score per round equals the slip count; winner and tie cases; reset clears slips, scores and history and keeps players and teams.

**Task 1.8: Host management** - `transfer_host`, `kick_player`, `claim_host`, `assign_spectator`, `delete_my_data`. Tests: cannot kick self; kick during `submitting` removes that player's slips; kicking the current clue-giver ends their turn; `claim_host` rejected while the host is fresh and accepted when stale; spectator assignment rejected during an active turn.

**Task 1.9: Cleanup job** - `0009_cleanup.sql` with the pg_cron schedule and a `cleanup_rooms()` function tested directly.

**Task 1.10: Celebrity table and functions** - `0010_celebrities.sql`, `010_celebrities.test.sql`, seeded in the test with about 20 rows. Tests: no direct select; prefix match; word-start match; case and accent insensitive ("beyonce" finds Beyoncé); ordered by popularity; one-character query returns nothing; `max` and `n` clamped; `random_celebrities` honours `exclude` and returns no repeats; `suggestions_enabled` toggles through `update_settings` for the host only.

### Phase 1b: Recommendation list

Done. Live verification is carried forward below.

Verify script tasks with `python3 -m unittest discover tools/celebrity-list/tests`.

**Task 1b.1: Normalise and merge** - `merge.py` with `normalise(name)`, `merge(wiki_rows, imdb_rows, blocklist)`. Tests: accents and case fold; overlap records both sources and the higher score; blocklisted names removed.

**Task 1b.2: Wikipedia source** - `sources_wikipedia.py`: fetch monthly top articles, batch-look-up Wikidata types and descriptions, return people and fictional characters. Tests run against saved API responses in `tests/fixtures/`, with no network.

**Task 1b.3: IMDb source** - `sources_imdb.py`: stream the three dataset files, score, filter adult-only, return the top N. Tests run against 50-line fixture files.

**Task 1b.4: Build and load** - `build.py` writes `celebrities.csv`; `load.py` upserts it into the database named by `DATABASE_URL` and deletes rows no longer in the list. Verify locally: `python3 tools/celebrity-list/build.py && python3 tools/celebrity-list/load.py`, then `select count(*) from celebrities` returns between 3,000 and 6,000, and `select * from suggest_celebrities('tom')` returns recognisable names. Spot-check 50 random rows by eye for junk.

**Task 1b.5: Monthly refresh** - `.github/workflows/refresh-celebrities.yml`, scheduled monthly and runnable by hand, using a repository secret for the production database URL. The job fails without loading if the built list has fewer than 2,000 rows.

### Phase 2: CelebrityCore

Done.

Verify each with `swift test --package-path Packages/CelebrityCore`.

**Task 2.1: Models** - `Room`, `Player`, `Turn`, `Settings`, `RoomSnapshot` as `Codable`, `Sendable`, `Equatable` with snake_case keys. Tests: decode the captured and hand-written fixtures and round-trip through the snapshot wire encoder and decoder.

**Task 2.2: Derived values** - on `RoomSnapshot`: `me`, `isHost`, `isClueGiver`, `isSpectator`, `teamTotals`, `winner`, `canStartGame` with a reason string, `nextUp`. Table-driven tests.

**Task 2.3: Screen routing** - `Screen.from(snapshot:)` returning `.home`, `.lobby`, `.submit`, `.game`, `.finished`. One test per phase.

**Task 2.4: Event derivation** - `RoomEventDeriver.events(old:new:userID:)` returning `.roundStarting`, `.turnStarted`, `.turnEnded(Turn)`, `.roundEnded`, `.gameEnded`, `.kicked`, `.hostChanged`, `.submissionsAutoClosed`. One test per transition, plus one proving identical snapshots give no events.

**Task 2.5: Validation and rules text** - name trimming and length limits, room code normalisation, join-link parsing (`https://celeb.xozai.com/join/CODE`), the three round descriptions. Include a test that two identical names in one submission are both kept.

**Carried forward**

- Task 1b.4's live build, load and spot check have yet to run.
- Replace the `TEAMID` and `APP_STORE_URL` placeholders in `site/` before release. Verify the IMDb credit wording.
- Hosted dev project `celebrity-dev` (ref `mrfjxgunecbjzmfkacvu`, us-east-2) exists with all 11 migrations applied and anonymous sign-ins on. It is the Task 7.2 project. Checked there: private Broadcast end to end (`supabase/tests/hosted/smoke.mjs`), the join authorisation probe with the `topic = realtime.topic()` binding, the `realtime.send(jsonb, text, text, boolean)` signature, the extensions, the cleanup schedule, and definer functions reading `auth.users`.
- Accepted: a removed player's open socket keeps receiving invalidations (room id and event name only) until it reauthorises. Topics are not rotated.
- Still open on hosted: query plans for `rooms`, `players` and `turns` under the REST role with realistic history sizes. The first channel join on the new project was refused once and has not recurred.
- The monthly schedule in `refresh-celebrities.yml` is commented out until the live build is checked and the `PRODUCTION_DATABASE_URL` secret is set.
- Put every database change from here on in a new forward migration. `supabase/tests/concurrency/run.sh` covers the two-session checks and runs in CI.

### Phase 3: CelebrityBackend

**Task 3.1: Protocol** - Done. `GameBackend` is `Sendable` and exposes one async method per app RPC, `currentUserID()` for anonymous session identity, and the room observation, connection and foreground APIs below.

**Task 3.2: Fake** - Done. `FakeGameBackend` records calls and replays scripted snapshots, draws and recommendation results for previews and tests. Script delays and failures, including room-scoped refresh failures, refused channel joins and losses during local membership changes, without reimplementing the game rules. Use `script(_:transitions:)` to set or clear a private draw in the same commit as a snapshot, or `script(_:followUpOf:)` to replay a fixture's next step and any paired draw.

- `observeRoom(roomID:) -> AsyncStream<RoomUpdate>` delivers `.snapshot(RoomSnapshot)` and, when the room observation ends, exactly one terminal `.lost(RoomLossReason)` followed by stream completion. Cancellation ends the stream without a loss. Before starting the consuming task, obtain the stream so it is registered. Use one consuming task per returned stream and cancel it on teardown. Room and connection streams keep only the newest undelivered element, so terminal loss can replace a pending snapshot and is buffered even if it occurs before the consumer's first read. Void RPCs return no state. Read the result from the observation.
- Refresh failures, including the first refresh and foreground refresh, have four paths. Retry network failures and report only `.reconnecting` on `connection`. Map `not_member` to `.removed` (including a stale stored room ID) or `.roomDeleted` if a deletion event was seen first. For an invalid or deleted session, try token recovery once and emit `.sessionEnded` if it fails. Other permanent failures, such as denied permission or an undecodable response, emit `.failed(BackendError)`. A local leave or switch ends the old observation with `.left`, and data deletion or sign-out ends it with `.sessionEnded`. One refresh outcome applies to all observers of that room.
- `connection: AsyncStream<ConnectionState>` starts with the current state and describes the live room channel. States are `.idle` with no room observed, `.connecting` during the first join, `.connected`, `.reconnecting` while retrying and `.disconnected` when the observed room's channel is down without an active retry. Show the reconnecting banner only when `showsReconnectingBanner` is true (`.reconnecting` or `.disconnected`). `didEnterForeground() async` refreshes Realtime auth, reconnects as needed and refetches on the existing streams. It does not throw and has no effect without an observed room.
- `BackendError` maps section 6 domain codes to `userMessage`. Use `from(postgrestBody:httpStatus:)` or `from(code:message:httpStatus:)` for structured server errors. Domain tokens are the exact message under `P0001`. PostgREST JWT errors (`PGRST301/302/303`) and HTTP 401 map to `.notAuthenticated`; `42501` with HTTP 403 or unavailable status maps to `.permissionDenied`. HTTP 502/503/504 map to `.network`. Use `from(_:)` for generic errors and ignore cancellation with `BackendError.isCancellation(_:)`.
- `TeamAssignments` is keyed by `Player.userID`. Use `.team(0)`, `.team(1)` or `.unassigned` (JSON null). Omitted users keep their assignments. `SettingsUpdate` sends only supplied fields using the section 6 wire keys. The private `Draw` carries the slip `id`, `name` and current draw `token`. Both recommendation methods return `[CelebritySuggestion]` with name, description, category and sources. The protocol and fake halves of Task 3.4b are done.
- `SampleScenario.ID` cases: `lobbyHost`, `lobbyGuest`, `lobbyUnevenHost`; `submittingEditing`, `submittingWaiting`, `submittingSpectator`, `submittingRecommendationsOff`, `submittingExpiredEmpty`; `playingClueGiverReady`, `playingClueGiver`, `playingClueGiverSkipOff`, `playingClueGiverSkipUsed`, `playingClueGiverUnlimited`, `playingGuesser`, `playingOpponent`, `playingSpectator`; `stalledHost`, `stalledGuest`; `roundEndHost`, `roundEndGuest`, `finishedWinner`, `finishedTie`. Follow-ups cover Start Turn (first draw, no score change), spectator assignment in a stalled room, and an expired empty window returning to Lobby.

**Task 3.3: Supabase implementation, calls** - implement the RPC adapter in `CelebrityBackendSupabase`. The `CelebrityBackend` product depends only on CelebrityCore and holds the protocol, types, fake and samples. The adapter product is in the same package and is the only library product linking the SDK.

1. Sign in anonymously on first launch when no session exists. Use the SDK's Keychain session storage. Wrap the app RPCs using the argument keys in section 6, with recommendation wrappers tracked in Task 3.4b.
2. Map typed SDK Auth errors in the adapter, with tests. Local `sessionMissing` without an HTTP response, API `session_not_found`, `refresh_token_not_found`, `bad_jwt` and other invalid-session codes, and a rejected refresh map to `.notAuthenticated`. Use those codes without relying on HTTP 401. Nested `CancellationError` and `URLError.cancelled` map to `.cancelled`. Genuine configuration failures such as a bad URL/key or disabled provider map to `.unknown`. Network errors map to `.network`.
3. Pass the PostgREST response body and HTTP status to `BackendError.from(postgrestBody:httpStatus:)`, or pass the extracted code, message and status to `from(code:message:httpStatus:)`. Preserve the distinction between `42501` with HTTP 401 and with HTTP 403.
4. Decode snapshots with `RoomSnapshot.makeDecoder()`. Decode the nullable draw as a top-level JSON object or null and `heartbeat` as a timestamp scalar using the snapshot date strategy. The interface tests include fixtures for null draws and the standalone timestamp.
5. Send `TeamAssignments.wireJSON()` as the JSON object inside `p_assignments` and encode `SettingsUpdate` inside `p_settings`.
6. After `deleteMyData()`, clear the local session if the anonymous account was deleted. Keep the login for a retained account.
7. When Task 3.3 lands, add the `CelebrityBackendSupabase` product to the app target's `CelebrityBackend` package dependencies in `project.yml`, alongside the existing interface product.

**Task 3.4: Supabase implementation, live updates** - implement the observation and foreground contract in `CelebrityBackendSupabase`.

1. Probe membership with `get_snapshot` even when private channel authorisation refuses the join. If the probe finds no seat, end with `lost(.removed)`. If the probe finds a seat, deliver the snapshot, show `.reconnecting` and retry the join.
2. Fetch again after a successful join whenever a snapshot was fetched before joining.
3. Defer `.removed` and `.roomDeleted` classification while a local leave, room switch or deletion is in flight. On success, end with `.left` or `.sessionEnded` and discard the deferred classification. On failure, apply the deferred classification.
4. Share one channel per active room and session across observers. Keep invalidations received during an initial or later fetch and fetch again afterwards. Check the generation of every fetch, membership probe, publication and loss. Drop results from before a reconnect, leave, delete, loss, room switch or session replacement.
5. Apply the same failure classes on the first and later refreshes. Network failure retries and signals only `.reconnecting`. For an invalid session, attempt token recovery once and emit `lost(.sessionEnded)` if it fails. Other permanent failures emit `lost(.failed(error))`. `not_member` emits `lost(.removed)` or `lost(.roomDeleted)` if a deletion event was seen first.
6. Publish `.idle` with no observation, `.connecting` on the initial join, `.connected` on success and `.reconnecting` or `.disconnected` when the channel drops. Return to `.idle` after loss, leave, delete or cancellation by the last observer if no room remains observed.
7. Buffer the newest undelivered element per room or connection subscriber. Deliver one terminal loss to each active room observer, then finish, with no later snapshots. Cancelling an observer finishes its stream without a loss and leaves other observers running. Close the channel once when the last observer finishes.
8. On `didEnterForeground()`, refresh Realtime auth, reconnect if needed, and refetch and publish on the existing observation streams. With no room observed, do nothing.
9. Call Realtime `setAuth` with the session token before joining private Broadcast on `room:<room_id>` with a lowercase UUID. Listen for all four section 6 events, coalesce bursts and refetch on every event type, reconnect and foregrounding.

**Task 3.4b: Recommendation calls** - implement `suggestCelebrities(query:limit:)` and `randomCelebrities(count:excluding:)` in `CelebrityBackendSupabase`. Use section 6's `q`/`max` and `n`/`exclude` keys and decode the returned rows as `[CelebritySuggestion]`.

**Task 3.5: Integration tests** - port the 45 cases from the reference `test/integration.js` to Swift Testing in `CelebrityBackendSupabaseTests`, driving four signed-in clients against local Supabase. Exercise stale draw tokens, clue-giver-only draw access, removal detected by snapshot refresh, and the join, catch-up and local membership orderings in Task 3.4. Verify: `supabase start && swift test --package-path Packages/CelebrityBackend`.

### Phase 4: App screens

Build previews and UI tests with `FakeGameBackend` and the applicable `SampleScenario` fixtures. Use scripted follow-ups and failures for transitions. Verify each task by building and by checking the preview states listed.

**Task 4.1: AppModel and routing** - `@MainActor @Observable AppModel` holds the caller's user ID, snapshot, connection state and pending recap events. Get the ID from `currentUserID()` at launch. Route the root view using `Screen`. Create one `observeRoom(roomID:)` stream for the active room and consume it in one task. Cancel the old task on room change or teardown, and ignore results from superseded observations. Keep one task for `connection`. Derive recaps from delivered snapshots and their turn history, allowing intermediate snapshots to be coalesced. Handle each terminal reason as in Task 5.5, including a loss before any snapshot. Unit tests with the fake.

**Task 4.2: Home** - name field (remembered), Create and Join using the returned room snapshot and a 4-character code field for Join, How to Play, and pending/error states for room requests. The live room connection stream is idle on Home, so use request state for the Home connecting preview. Previews: empty, connecting, error.

**Task 4.3: Lobby** - player list, team editor (tap to move, shuffle, auto-balance) using `TeamAssignments` keyed by `Player.userID`, team names, host settings sheet sending a partial `SettingsUpdate` including skip mode, invite sheet (code, QR, share), start button with the disabled reason. Previews: host, guest, uneven teams.

**Task 4.4: Submit** - one field per slip, countdown, submitted-count progress, and submit/retract via `submitSlips(_:)` and `retractSlips()`. Disable edits at the deadline. Route an empty expired window back to Lobby from the observed snapshot. Previews: editing, waiting, spectator, and the expired-empty follow-up.

**Task 4.4b: Wikipedia live search** - `WikipediaSearch.swift`: build the request, decode, drop disambiguation pages. Unit tests with a stubbed `URLProtocol`: normal response, empty response, timeout, malformed JSON.

**Task 4.4c: NameSuggester** - `@Observable` class that debounces input, asks `suggestCelebrities(query:)` first, tops up from Wikipedia when there are fewer than 6, removes duplicates by normalised name, and cancels stale requests without showing a cancellation error. Unit tests: curated results come first; duplicates collapse; a slow earlier query never overwrites a newer one; Wikipedia failure still shows curated results; nothing is requested when the room has recommendations off.

**Task 4.4d: Suggestion list and ideas row** - `SlipField.swift` shows up to 6 suggestions with descriptions under the focused field; `IdeasRow.swift` shows 8 chips and a shuffle button, fills the next empty slip on tap, and excludes names already entered with `randomCelebrities(count:excluding:)`. Both are hidden when the host has turned recommendations off. Add the toggle to the host settings sheet from Task 4.3. Previews: suggestions showing, ideas row, recommendations off. VoiceOver reads name then description.

**Task 4.5: Game, clue-giver** - Start Turn, slip card, Got It, Skip (hidden, limited or free per setting), timer ring. Store the private `Draw?` from `startTurn()`. Pass the displayed `draw.token` to `gotIt(token:)` and `skip(token:)`, and replace the whole draw with the result, including a stale-token reply or nil. Apply replies only to the room and turn that requested them. Clear the draw on turn end, loss of the clue-giver role, room switch or any terminal loss. Keep it out of shared snapshots and recap state. Previews: ready to start and running with Skip off, available, used, or unlimited.

**Task 4.6: Game, watcher** - who is giving clues, "your team is guessing" or "stay quiet", timer, slips left, live count, round rule banner, scoreboard. During `playing`, a nil `nextUp` means there is no assigned clue-giver. Show the host an "assign a spectator" state with `assignSpectator(userID:team:)`, and tell other players they are waiting for the host. Previews: guesser, opponent, spectator, stalled host and stalled guest. Use the stalled follow-up to check that assigning the spectator restores `nextUp`.

**Task 4.7: Recap sheets** - round intro, turn recap, round end with host-only Next Round (`startNextRound()`), game end with winner or tie, history, share, and Play Again for the host (`resetRoom()`). Use snapshot-derived events and turn history for recaps. Show skip counts and use the saved display name for anonymised turns.

**Task 4.8: How to Play and app settings** - rules text based on the Coyier write-up, theme, sound toggle, delete my data, privacy policy link, version. Call `deleteMyData()`. On success, clear the stored room and local game state, and treat `.sessionEnded` as expected. The backend clears the local session when it deletes the anonymous account. Call `currentUserID()` again to obtain the fresh anonymous identity or the retained account's ID.

### Phase 5: Resilience

**Task 5.1: Server clock** - `ServerClock` stores the offset from snapshot `server_now` or the timestamp returned by `heartbeat(roomID:)`; the timer renders from `turn_ends_at` minus corrected now. Unit test with a 90-second skew.

**Task 5.2: Deadline calls** - when the countdown hits zero call `endTurn()` (or `closeSubmissions()`) and refetch with `snapshot(roomID:)`. The server uses its own clock at the deadline. Treat a close that returns `wrong_phase` after an empty window returned to the lobby as benign. If the server says `deadline_not_reached`, refresh the clock and wait for the deadline.

**Task 5.3: Lifecycle** - call `await backend.didEnterForeground()` when SwiftUI's `scenePhase` becomes `.active`. The backend refreshes Realtime auth, reconnects and refetches on the existing streams. Afterwards, if still the active clue-giver for the same room and turn, use `currentSlip()` to restore or clear the private `Draw`. Persist the room ID and start auto-rejoin with `observeRoom(roomID:)` after relaunch. Exit loading on the first snapshot or any terminal loss, including `.failed(error)`. Show a non-blocking reconnecting banner only when `connectionState.showsReconnectingBanner` is true.

**Task 5.4: Presence and host handoff** - `heartbeat(roomID:)` every 15 s; grey out players stale for 30 s; the lowest-seat connected player calls `claimHost()` when the host is stale for 45 s.

**Task 5.5: Kicked and room-gone handling** - handle the final `.lost(reason)` from room observation, even if no snapshot arrived. Stop using that observation and clear its stored room, local game state and private draw. For `.removed`, alert and return Home. For `.roomDeleted`, return Home and explain that the room closed. For `.left`, end the old room quietly and preserve any replacement room. For `.sessionEnded`, clear the room and cached identity, alert on unexpected session loss, and reacquire identity with `currentUserID()` when needed. For `.failed(error)`, leave the loading state, return Home and show `error.userMessage`. Ignore cancellation.

### Phase 6: Polish

**Task 6.1:** Haptics on start, got it, skip, last ten seconds, time up.
**Task 6.2:** Tick and buzzer sounds, respecting the mute switch and the in-app toggle.
**Task 6.3:** Keep the screen awake during `playing`.
**Task 6.4: Site for celeb.xozai.com** - build `site/` and deploy it with Cloudflare Pages (project connected to the repo, output directory `site`, custom domain `celeb.xozai.com`). Add a `site/_headers` file so the association file is served as `application/json`. `apple-app-site-association` lists `<TeamID>.com.xozai.CelebrityGame` with path `/join/*` and must be served with no redirect. Verify: `curl -sI https://celeb.xozai.com/.well-known/apple-app-site-association` returns 200 with `content-type: application/json`.
**Task 6.4b: Universal links in the app** - add the Associated Domains entitlement `applinks:celeb.xozai.com`; QR code and share sheet use `https://celeb.xozai.com/join/CODE`; handle with `onOpenURL` and `onContinueUserActivity`, prefilling the code and joining once a name is set. Verify on a real device by scanning the QR code with the Camera app (universal links do not work reliably in the simulator).
**Task 6.5:** Accessibility pass: labels, Dynamic Type up to the largest accessibility size on the slip card, reduced motion, contrast in both themes.

### Phase 7: End-to-end verification

**Task 7.1: UI tests** - with `FakeGameBackend` and `SampleScenario` fixtures and scripted follow-ups: create room, submit, a clue-giver turn, game end.
**Task 7.2: Hosted dev project** - the project exists and is migrated (see Carried forward). Remaining: point a debug build at it.
**Task 7.3: Multi-device run** - four simulators or devices through a full three-round game, following an updated copy of the reference `test/qa-plan.md` saved as `docs/qa-plan.md`. Include: kill and relaunch the clue-giver mid-turn, airplane-mode a guesser, host leaves, kick, late joiner, rematch.

### Phase 8: App Store

**Task 8.1:** Production Supabase project, separate keys per build configuration, anonymous sign-in rate limits reviewed.
**Task 8.2:** App icon, launch screen, `PrivacyInfo.xcprivacy`, `ITSAppUsesNonExemptEncryption = false`.
**Task 8.3:** Privacy policy at `https://celeb.xozai.com/privacy`, rewritten for Supabase and anonymous sign-in (the current one describes the Render server).
**Task 8.4:** New App Store Connect record for `com.xozai.CelebrityGame` with the name "Celebrity Celebrity", version 1.0.0, screenshots, age rating, review notes explaining how to test a multiplayer game alone (a second device or a demo room).
**Task 8.5:** TestFlight build, one real game night, then submit.

### Phase 9: Retire the old stack

Do this only after the new app is approved and live.

**Task 9.1:** Suspend the Render service `celebrity-game-claude` and delete its Redis database if one was attached. This takes the web client offline too.
**Task 9.2:** Archive `xozai/celebrity-game-claude` and `xozai/celebrity-game-ios` on GitHub, with a README line pointing to `xozai/celebrity-new`.
**Task 9.3:** If the old iOS build was distributed through TestFlight, expire those builds so testers move to the new one.

## 8. Risks and tradeoffs

- **Realtime lag or missed messages.** Refetch the snapshot on any private Broadcast event, reconnect and foregrounding. Every phone calls `end_turn()` at zero. An already authorised socket can still see invalidation timing after removal until it reauthorises.
- **Rules live in SQL.** Harder to debug than Swift or JavaScript. Mitigated by pgTAP coverage per function and the ported integration suite.
- **No turn pause on disconnect.** A clue-giver who drops loses that time. Simpler and matches a real table; revisit if testers complain.
- **Player-typed names are user-generated content.** Rooms are private and code-gated, and the host can kick, but App Review sometimes asks for reporting or filtering. Have a short answer ready in the review notes; add a report link if they push back.
- **Anonymous identity is tied to the install.** Reinstalling mid-game loses the seat; the host can kick the stale entry and the player rejoins as a spectator, then gets assigned to a team.
- **Web client is retired.** After Phase 9 there is no way to play without an iPhone. Anyone opening an invite link on another device sees the fallback page.
- **Universal links are fiddly.** They fail silently if the association file is redirected, cached wrong, or the Team ID is off. The room code is always shown as a fallback.
- **IMDb licensing.** IMDb's dataset page says the files are "for personal and non-commercial use". The user has confirmed the app stays free with no ads or purchases and accepts using the datasets on that basis. The app is still published under a company bundle id, so this remains a judgement call rather than a clearance. If ads, purchases or a paid tier are ever added, the IMDb source must be removed or licensed first; the fallback is Wikipedia only (which already includes famous actors) or TMDB, which offers a free API with attribution. The merge step treats sources as pluggable, so the change is confined to one file.
- **Recommendation quality.** Pageview and vote counts skew recent and English-speaking, and can surface people famous for grim reasons. Mitigated by the blocklist, the adult-title filter and the eyeball check in Task 1b.4.
- **Recommendations make games samey.** Popular chips push players toward the same names. Mitigated by weighted-random sampling over a large list, and the host toggle.
- **Cost.** See the free-tier note in section 3.
- **Local disk.** `supabase start` pulls several GB of Docker images. The Mac has 24 GB free today.

## 9. Execution with herdr (Hermes as lead)

Herdr 0.9.5 is installed (`brew install herdr`). A Hermes session running in a herdr pane leads; Claude Code, Codex and Antigravity (`agy`) are workers. The lead loads the `herdr` skill, including `references/hermes-lead.md`, which records the Hermes-specific rules found in testing.

### Start the lead

Run `herdr` in a terminal first (default session; the lead cannot reach a named session), then from a second terminal:

```bash
REPO=~/code/celebrity-new
created=$(herdr workspace create --cwd "$REPO" --label lead --env HERDR_AGENT=hermes --no-focus)
pane=$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id')
herdr agent start lead --kind hermes --pane "$pane" --timeout 90000 -- --skills herdr
herdr agent prompt lead "Load the herdr skill and its references/hermes-lead.md. Read docs/PLAN.md section 9 and run the next stage. Stop and tell me at each merge point."
```

`--env HERDR_AGENT=hermes` is required: without it herdr does not recognise Hermes on this machine.

### Lanes

Each worker gets its own git worktree (`herdr worktree create --cwd "$REPO" --branch lane/<name> --base main --label <name>`) and one directory. No two lanes share files.

| Stage | Claude (`--kind claude`) | Codex (`--kind codex`) | Antigravity (`--kind agy`) |
|---|---|---|---|
| 1. Serial | Phase 0 on main | waits | waits |
| 2. Parallel | Phase 1, `supabase/` | Phase 2, `Packages/CelebrityCore` | Phase 1b, `tools/celebrity-list`, then static files in `site/` |
| 3. Parallel | Tasks 3.3 to 3.5, `Packages/CelebrityBackend` (Supabase target and its tests only) | Phase 4, `App/` | Quota exhausted until about 29 November 2026 |
| 4. Parallel | Phase 5 | Phase 6 | cross-reviews |

- Task 4.4b is part of Codex's Phase 4 lane. Assign `docs/qa-plan.md` separately.
- The `CelebrityBackend` interface target is frozen for stage 3. Route changes to it through the lead.
- CI runs the Swift tests for both packages: `swift test --package-path Packages/CelebrityCore` and `swift test --package-path Packages/CelebrityBackend`. The macOS job has no Supabase stack, so integration tests that need one must skip themselves when it is absent. The lead owns workflow changes.
- Claude owns all database work, because only one local Supabase stack can run at a time.
- Codex runs with `-s workspace-write` and does not commit; the lead commits its lane after review.
- Phases 7.3, 8 and 9 stay with the user (real devices, App Store Connect, Render).

### Lead loop, per stage

1. Create the worktrees and start one worker per lane with `agent start`.
2. Prompt each worker: read `docs/PLAN.md`, do the listed tasks in order with tests first, touch only its directory, write `LANE_STATUS.md` when finished or stuck.
3. Wait with `herdr agent wait <name>`; on `blocked`, read the pane and ask the user unless the answer is obvious and harmless.
4. When `LANE_STATUS.md` says done, run that lane's verify command from the plan itself. Do not trust the worker's report.
5. Have a different model review the lane's diff, fix findings, rebase on main, merge.
6. Report to the user and wait for a go before the next stage.

### Known limits

- Herdr shows the lead as idle even while it works, so the sidebar and `agent wait` cannot tell when the lead is done. Read the lead's pane, or have it print a sentinel line.
- Antigravity reads idle while background tasks run. The status file is the completion signal.
- Claude asks before reading files outside its worktree. Codex asks before running `swift test`.
- Workers stop on approval prompts. Skip-approval flags stay off while the Supabase service key is on the machine.

## 10. Open questions

All earlier questions are resolved (section 1). One item remains, and it does not block starting:

1. "Celebrity Celebrity" must be available as an App Store name; check when creating the record and have a subtitle or alternative ready.
