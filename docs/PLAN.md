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
| Live updates | Realtime on table changes | Firestore listeners | Push-based, slow for this |
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
5. Submission countdown that auto-starts with the slips received.
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
24. Each team starts alternate rounds, and the clue-giver rotation continues across rounds.
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
  CelebrityBackend/                 depends on CelebrityCore + supabase-swift
    Sources/CelebrityBackend/GameBackend.swift, SupabaseGameBackend.swift,
      FakeGameBackend.swift, BackendError.swift
    Tests/CelebrityBackendTests/    integration tests against local Supabase
supabase/
  config.toml
  migrations/0001_schema.sql, 0002_rls.sql, 0003_rooms.sql, 0004_lobby.sql,
    0005_submission.sql, 0006_turns.sql, 0007_rounds.sql, 0008_host.sql, 0009_cleanup.sql,
    0010_celebrities.sql
  tests/*.test.sql                  pgTAP
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

- `rooms`: `id`, `code` (unique, 4 chars from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`), `host_id`, `phase` (`lobby`, `submitting`, `playing`, `round_end`, `finished`), `round` (0-3), `team_names text[2]`, `slips_per_player`, `turn_seconds`, `submission_seconds`, `skip_mode` (`off`, `one_per_turn`, `unlimited`), `submission_deadline`, `current_team`, `turn_idx int[2]`, `turn_player_id`, `turn_ends_at`, `turn_got`, `turn_skips`, `pile_count`, `scores jsonb`, `last_activity_at`, `created_at`.
- `players`: primary key (`room_id`, `user_id`), `name`, `team`, `role` (`player`, `spectator`), `seat` (join order), `submitted`, `last_seen_at`. Unique on (`room_id`, `lower(name)`).
- `slips`: `id`, `room_id`, `author_id`, `name`, `in_pile`, `pile_order` (random per round), `is_current`. No client can select from this table.
- `turns`: `id`, `room_id`, `round`, `team`, `player_id`, `player_name`, `guessed text[]`, `skipped`, `ended_at`. This is the history.

`round_end` is a new phase (the reference server stays in `playing`); it is what makes the "start next round" guard possible.

Row-level security: members of a room can select its `rooms`, `players` and `turns` rows. No client inserts, updates or deletes anywhere. Every change goes through a `security definer` function that checks `auth.uid()`.

Functions (each locks the room row with `select ... for update` first):

| Function | Caller | Returns |
|---|---|---|
| `create_room(name)` | anyone, max 5 per user per hour | snapshot |
| `join_room(code, name)` | anyone; spectator if phase is not `lobby`; returns existing seat if `auth.uid()` is already a member | snapshot |
| `leave_room()` | member | - |
| `get_snapshot(room_id)` | member | room, players, turns, `server_now` |
| `heartbeat(room_id)` | member | `server_now` |
| `set_teams(assignments jsonb)`, `set_team_name(team, name)`, `update_settings(...)` | host, lobby only | - |
| `start_game()` | host, needs 2+ players on each team | - |
| `submit_slips(names text[])`, `retract_slips()` | player, `submitting` only | - |
| `close_submissions()` | any member once the deadline has passed and 1+ slips exist | - |
| `start_turn()` | the player whose turn it is | the slip |
| `got_it()` | clue-giver, before `turn_ends_at` | next slip, or null if the pile is empty |
| `skip_slip()` | clue-giver, subject to `skip_mode` | next slip |
| `current_slip()` | clue-giver (used after a reconnect) | the slip |
| `end_turn()` | any member once `turn_ends_at` has passed | - |
| `start_next_round()` | host, `round_end` only | - |
| `reset_room()` | host, `finished` only | - |
| `assign_spectator(user_id, team)` | host, no turn active | - |
| `transfer_host(user_id)`, `kick_player(user_id)` | host | - |
| `claim_host()` | any member when the host's `last_seen_at` is older than 45 s | - |
| `delete_my_data()` | anyone | - |

Timer design: there is no server-side timer process. `turn_ends_at` is the source of truth. `got_it` and `skip_slip` reject calls after it. Every phone in the room calls `end_turn()` when its countdown hits zero; the first call wins and the rest are no-ops. The same pattern closes submissions. This drops the reference server's 30-second pause on clue-giver disconnect: the clock keeps running, and a clue-giver who reconnects gets the slip back through `current_slip()`.

Live updates: the app subscribes to changes on `rooms` (by id), `players` and `turns` (by room id), and refetches `get_snapshot` on every reconnect and return to foreground. Recap sheets are derived on the phone by comparing the previous and new snapshot (`RoomEventDeriver`), not from separate server events.

Kicked detection: a deleted `players` row whose key matches the local user id.

Cleanup: a pg_cron job deletes finished rooms older than 1 hour and any room idle for 24 hours.

### 6a. Celebrity recommendations

Two layers feed the Submit screen.

**Layer 1: a curated list in Supabase (Wikipedia + IMDb).** A `celebrities` table of roughly 5,000 well-known names, rebuilt monthly by a script and queried through two functions. This is what makes recommendations fast, ranked by fame, and limited to actual people and characters.

- Table `celebrities`: `id`, `name`, `name_norm` (lowercased, accents stripped, unique), `description`, `category` (`film_tv`, `music`, `sports`, `public_figure`, `fictional`, `other`), `popularity` (0-1), `sources text[]` (`wikipedia`, `imdb`). No direct client access. A pg_trgm index on `name_norm`.
- `suggest_celebrities(q text, max int default 6)`: matches the start of the name or the start of any word in it ("jobs" finds Steve Jobs), ordered by popularity. Requires 2+ characters; `max` is clamped to 10.
- `random_celebrities(n int default 8, exclude text[])`: a popularity-weighted random sample for the "Need ideas?" row, skipping names the player has already typed. `n` is clamped to 20.
- `rooms.suggestions_enabled boolean default true`, set through `update_settings`.

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

One migration and one pgTAP file per task. Verify each with `supabase db reset && supabase test db`.

**Task 1.1: Schema** - `0001_schema.sql`, `001_schema.test.sql` (tables, checks, unique indexes exist).

**Task 1.2: Row-level security** - `0002_rls.sql`, `002_rls.test.sql`. Tests: a member reads their room; a non-member reads nothing; nobody can select from `slips`; direct insert, update and delete are denied on all four tables.

**Task 1.3: Rooms** - `create_room`, `join_room`, `leave_room`, `get_snapshot`, `heartbeat`. Tests: code format, empty name rejected, unknown code rejected, duplicate name rejected for a different user, same user rejoining gets the same seat, late joiner is a spectator, sixth room in an hour rejected.

**Task 1.4: Lobby** - `set_teams`, `set_team_name`, `update_settings`, `start_game`. Tests: non-host rejected, out-of-range values rejected, team name trimmed to 20 chars, start needs 2+ per team, start sets `submitting` and the deadline.

**Task 1.5: Submission** - `submit_slips`, `retract_slips`, `close_submissions`. Tests: wrong count rejected, spectator rejected, retract removes only that player's slips, last submission starts round 1 with `pile_count` equal to total slips, close before the deadline rejected, close with zero slips rejected, close after the deadline starts with partial slips.

**Task 1.6: Turns** - `start_turn`, `got_it`, `skip_slip`, `current_slip`, `end_turn`. Tests: only the current player can start; got it increments the count and returns a different slip; skip rejected when `skip_mode` is `off`; second skip rejected under `one_per_turn`; skipped slip stays in the pile; `end_turn` before the deadline rejected; after the deadline the current slip returns to the pile, a `turns` row is written, the score is added, and the turn passes to the other team's next player; a second `end_turn` is a no-op; `got_it` after the deadline rejected; non-clue-giver calling `current_slip` gets nothing.

**Task 1.7: Rounds and game end** - emptying the pile sets `round_end` (or `finished` after round 3); `start_next_round`; `reset_room`. Tests: `start_next_round` rejected during `playing`; pile refilled with every slip; rotation continues; total score per round equals the slip count; winner and tie cases; reset clears slips, scores and history and keeps players and teams.

**Task 1.8: Host management** - `transfer_host`, `kick_player`, `claim_host`, `assign_spectator`, `delete_my_data`. Tests: cannot kick self; kick during `submitting` removes that player's slips; kicking the current clue-giver ends their turn; `claim_host` rejected while the host is fresh and accepted when stale; spectator assignment rejected during an active turn.

**Task 1.9: Cleanup job** - `0009_cleanup.sql` with the pg_cron schedule and a `cleanup_rooms()` function tested directly.

**Task 1.10: Celebrity table and functions** - `0010_celebrities.sql`, `010_celebrities.test.sql`, seeded in the test with about 20 rows. Tests: no direct select; prefix match; word-start match; case and accent insensitive ("beyonce" finds Beyoncé); ordered by popularity; one-character query returns nothing; `max` and `n` clamped; `random_celebrities` honours `exclude` and returns no repeats; `suggestions_enabled` toggles through `update_settings` for the host only.

### Phase 1b: Recommendation list

Verify script tasks with `python3 -m unittest discover tools/celebrity-list/tests`.

**Task 1b.1: Normalise and merge** - `merge.py` with `normalise(name)`, `merge(wiki_rows, imdb_rows, blocklist)`. Tests: accents and case fold; overlap records both sources and the higher score; blocklisted names removed.

**Task 1b.2: Wikipedia source** - `sources_wikipedia.py`: fetch monthly top articles, batch-look-up Wikidata types and descriptions, return people and fictional characters. Tests run against saved API responses in `tests/fixtures/`, with no network.

**Task 1b.3: IMDb source** - `sources_imdb.py`: stream the three dataset files, score, filter adult-only, return the top N. Tests run against 50-line fixture files.

**Task 1b.4: Build and load** - `build.py` writes `celebrities.csv`; `load.py` upserts it into the database named by `DATABASE_URL` and deletes rows no longer in the list. Verify locally: `python3 tools/celebrity-list/build.py && python3 tools/celebrity-list/load.py`, then `select count(*) from celebrities` returns between 3,000 and 6,000, and `select * from suggest_celebrities('tom')` returns recognisable names. Spot-check 50 random rows by eye for junk.

**Task 1b.5: Monthly refresh** - `.github/workflows/refresh-celebrities.yml`, scheduled monthly and runnable by hand, using a repository secret for the production database URL. The job fails without loading if the built list has fewer than 2,000 rows.

### Phase 2: CelebrityCore

Verify each with `swift test --package-path Packages/CelebrityCore`.

**Task 2.1: Models** - `Room`, `Player`, `Turn`, `Settings`, `RoomSnapshot` as `Codable`, `Sendable`, `Equatable` with snake_case keys. Test: decode a JSON fixture captured from `get_snapshot`.

**Task 2.2: Derived values** - on `RoomSnapshot`: `me`, `isHost`, `isClueGiver`, `isSpectator`, `teamTotals`, `winner`, `canStartGame` with a reason string, `nextUp`. Table-driven tests.

**Task 2.3: Screen routing** - `Screen.from(snapshot:)` returning `.home`, `.lobby`, `.submit`, `.game`, `.finished`. One test per phase.

**Task 2.4: Event derivation** - `RoomEventDeriver.events(old:new:userID:)` returning `.roundStarting`, `.turnStarted`, `.turnEnded(Turn)`, `.roundEnded`, `.gameEnded`, `.kicked`, `.hostChanged`, `.submissionsAutoClosed`. One test per transition, plus one proving identical snapshots give no events.

**Task 2.5: Validation and rules text** - name trimming and length limits, room code normalisation, join-link parsing (`https://celeb.xozai.com/join/CODE`), the three round descriptions. Include a test that two identical names in one submission are both kept.

### Phase 3: CelebrityBackend

**Task 3.1: Protocol** - `GameBackend` with one async method per server function, plus `func updates(roomID:) -> AsyncStream<RoomSnapshot>` and `var connection: AsyncStream<ConnectionState>`. `BackendError` maps server error codes to user-facing messages.

**Task 3.2: Fake** - `FakeGameBackend`, scriptable, for previews and UI tests. It replays canned snapshots and does not reimplement the rules.

**Task 3.3: Supabase implementation, calls** - anonymous sign-in on first launch (session stored in the Keychain by the SDK), then one RPC wrapper per function.

**Task 3.4: Supabase implementation, live updates** - subscribe to the three tables, coalesce bursts, refetch the snapshot on each change and on reconnect.

**Task 3.4b: Recommendation calls** - add `suggestCelebrities(query:)` and `randomCelebrities(count:excluding:)` to `GameBackend`, returning `[CelebritySuggestion]` (name, description, source), with Supabase and fake implementations.

**Task 3.5: Integration tests** - port the 45 cases from the reference `test/integration.js` to Swift Testing, driving four signed-in clients against local Supabase. Verify: `supabase start && swift test --package-path Packages/CelebrityBackend`.

### Phase 4: App screens

Every view gets previews built on `FakeGameBackend`. Verify each task by building and by checking the preview states listed.

**Task 4.1: AppModel and routing** - `@Observable AppModel` holding the snapshot, connection state and pending recap events; root view switches on `Screen`. Unit tests with the fake.

**Task 4.2: Home** - name field (remembered), Create, Join with a 4-character code field, How to Play, connection status. Previews: empty, connecting, error.

**Task 4.3: Lobby** - player list, team editor (tap to move, shuffle, auto-balance), team names, host settings sheet including skip mode, invite sheet (code, QR, share), start button with the disabled reason. Previews: host, guest, uneven teams.

**Task 4.4: Submit** - one field per slip, countdown, submitted-count progress, retract. Previews: editing, waiting, spectator.

**Task 4.4b: Wikipedia live search** - `WikipediaSearch.swift`: build the request, decode, drop disambiguation pages. Unit tests with a stubbed `URLProtocol`: normal response, empty response, timeout, malformed JSON.

**Task 4.4c: NameSuggester** - `@Observable` class that debounces input, asks the backend first, tops up from Wikipedia when there are fewer than 6, removes duplicates by normalised name, and cancels stale requests. Unit tests: curated results come first; duplicates collapse; a slow earlier query never overwrites a newer one; Wikipedia failure still shows curated results; nothing is requested when the room has recommendations off.

**Task 4.4d: Suggestion list and ideas row** - `SlipField.swift` shows up to 6 suggestions with descriptions under the focused field; `IdeasRow.swift` shows 8 chips and a shuffle button, fills the next empty slip on tap, and excludes names already entered. Both are hidden when the host has turned recommendations off. Add the toggle to the host settings sheet from Task 4.3. Previews: suggestions showing, ideas row, recommendations off. VoiceOver reads name then description.

**Task 4.5: Game, clue-giver** - Start Turn, slip card, Got It, Skip (hidden, limited or free per setting), timer ring. Previews for each skip mode.

**Task 4.6: Game, watcher** - who is giving clues, "your team is guessing" or "stay quiet", timer, slips left, live count, round rule banner, scoreboard. Previews: guesser, opponent, spectator.

**Task 4.7: Recap sheets** - round intro, turn recap, round end with host-only Next Round, game end with winner or tie, history, share, Play Again for the host.

**Task 4.8: How to Play and app settings** - rules text based on the Coyier write-up, theme, sound toggle, delete my data, privacy policy link, version.

### Phase 5: Resilience

**Task 5.1: Server clock** - `ServerClock` stores the offset from `server_now`; the timer renders from `turn_ends_at` minus corrected now. Unit test with a 90-second skew.

**Task 5.2: Deadline calls** - when the countdown hits zero call `end_turn()` (or `close_submissions()`), ignoring "already ended" errors.

**Task 5.3: Lifecycle** - on `scenePhase == .active`, reconnect and refetch; the clue-giver also calls `current_slip()`. Persist the room id for auto-rejoin after relaunch. Non-blocking reconnecting banner.

**Task 5.4: Presence and host handoff** - `heartbeat` every 15 s; grey out players stale for 30 s; the lowest-seat connected player calls `claim_host()` when the host is stale for 45 s.

**Task 5.5: Kicked and room-gone handling** - alert, then return to Home and clear the stored room.

### Phase 6: Polish

**Task 6.1:** Haptics on start, got it, skip, last ten seconds, time up.
**Task 6.2:** Tick and buzzer sounds, respecting the mute switch and the in-app toggle.
**Task 6.3:** Keep the screen awake during `playing`.
**Task 6.4: Site for celeb.xozai.com** - build `site/` and deploy it with Cloudflare Pages (project connected to the repo, output directory `site`, custom domain `celeb.xozai.com`). Add a `site/_headers` file so the association file is served as `application/json`. `apple-app-site-association` lists `<TeamID>.com.xozai.CelebrityGame` with path `/join/*` and must be served with no redirect. Verify: `curl -sI https://celeb.xozai.com/.well-known/apple-app-site-association` returns 200 with `content-type: application/json`.
**Task 6.4b: Universal links in the app** - add the Associated Domains entitlement `applinks:celeb.xozai.com`; QR code and share sheet use `https://celeb.xozai.com/join/CODE`; handle with `onOpenURL` and `onContinueUserActivity`, prefilling the code and joining once a name is set. Verify on a real device by scanning the QR code with the Camera app (universal links do not work reliably in the simulator).
**Task 6.5:** Accessibility pass: labels, Dynamic Type up to the largest accessibility size on the slip card, reduced motion, contrast in both themes.

### Phase 7: End-to-end verification

**Task 7.1: UI tests** - with the fake backend: create room, submit, a clue-giver turn, game end.
**Task 7.2: Hosted dev project** - create a Supabase dev project, `supabase db push`, point a debug build at it.
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

- **Realtime lag or missed messages.** Mitigated by refetching the snapshot on every change and reconnect, and by having every phone call `end_turn()` at zero.
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
| 3. Parallel | Tasks 3.1 and 3.2 first, then the rest of Phase 3 | Phase 4 screens, once 3.1 and 3.2 are merged | Task 4.4b, `docs/qa-plan.md` |
| 4. Parallel | Phase 5 | Phase 6 | cross-reviews |

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
- Workers stop on approval prompts. Skip-approval flags stay off while the Supabase service key is on the machine.

## 10. Open questions

All earlier questions are resolved (section 1). One item remains, and it does not block starting:

1. "Celebrity Celebrity" must be available as an App Store name; check when creating the record and have a subtitle or alternative ready.
