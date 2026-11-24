import CelebrityCore
import Foundation

/// Everything the app needs from a game server, with Swift names and typed arguments.
///
/// There is one method per app RPC in docs/PLAN.md section 6. Implementations are ``FakeGameBackend``
/// (previews, UI tests) and the Supabase client in the `CelebrityBackendSupabase` target. This module does not
/// link Supabase.
///
/// ## Use from a view model
/// The protocol is `Sendable` and every method is `async throws`, so a `@MainActor @Observable` view model can hold
/// an `any GameBackend` and call it directly under Swift 6 strict concurrency. All results are `Sendable` values.
///
/// ## Errors
/// Methods throw ``BackendError`` (or `CancellationError` when the calling task is cancelled; use
/// ``BackendError/isCancellation(_:)`` and ignore both). Show ``BackendError/userMessage``. Besides the codes listed per
/// method, every RPC can throw `.notAuthenticated`, every member-only RPC can throw `.notMember`, and any call can
/// throw `.network`.
///
/// ## Live state
/// Game state is whole ``RoomSnapshot``s delivered by ``observeRoom(roomID:)``. Void calls return no state; read the
/// result of a call from the observation. Slips and draw tokens are never in snapshots; the clue-giver gets ``Draw``s
/// from ``startTurn()``, ``gotIt(token:)``, ``skip(token:)`` and ``currentSlip()``.
public protocol GameBackend: Sendable {
    // MARK: Identity and live state

    /// The signed-in user's id, signing in anonymously first if there is no session.
    ///
    /// The id equals `Player.userID` for the caller's seat, so pass it to the `RoomSnapshot` helpers
    /// (`me(userID:)`, `isHost(userID:)`, ...). It is stable for the install, except after ``deleteMyData()`` deletes an
    /// anonymous account: the next call then signs in fresh and returns a new id.
    /// - Throws: ``BackendError/network(_:)`` if sign-in cannot reach the server.
    func currentUserID() async throws -> UUID

    /// Observes one room: its snapshots, then a terminal loss. **One call per room the app is in.**
    ///
    /// ### Elements
    /// The stream yields ``RoomUpdate/snapshot(_:)`` with the current state first, then a fresh one after every change,
    /// reconnect and ``didEnterForeground()``. It ends with exactly one ``RoomUpdate/lost(_:)`` and then finishes;
    /// nothing follows it. A consumer that sees `lost` must stop using the room.
    ///
    /// ### Coalescing
    /// The stream keeps only the newest undelivered element, so a slow consumer sees the latest state, not every
    /// intermediate one, and memory stays bounded. A pending `lost` always survives, because it is the newest.
    /// Derive recap events by diffing the snapshots you receive: completed turns are recoverable from
    /// `RoomSnapshot.turns`, but transient events (a round starting and ending between two delivered snapshots) can be
    /// missed. Do not depend on seeing every snapshot.
    ///
    /// ### Ownership
    /// The backend keeps **one live channel per active room and session**, however many observers there are. The first
    /// observer joins it; the last one to finish closes it. Observers share it: cancelling one never tears the channel
    /// down under the others. Invalidations that arrive while a fetch is in flight are not lost: the backend fetches again
    /// afterwards. A fetch started for an older generation (a different session, a room switch, a leave, a reconnect) is
    /// dropped instead of published when it completes late.
    ///
    /// ### One consumer per stream
    /// Iterate each returned stream from exactly one task. Do not share one stream between tasks, and do not create
    /// several iterators on it. To unsubscribe, cancel the consuming task (for example in the view model's teardown);
    /// merely breaking out of the loop while still holding the stream is not a guaranteed unsubscribe. For another
    /// consumer, call `observeRoom` again.
    ///
    /// ### When the observation ends, and failures of a refresh
    /// Refresh failures (the first one and every later one, including ``didEnterForeground()``) are classified:
    /// - **Network failure**: retried by the backend. The observation stays open, nothing is yielded, and the only signal
    ///   is ``connection`` (`.reconnecting`). It never ends the observation.
    /// - **`not_member`**: `lost(.removed)`, or `lost(.roomDeleted)` if a `room_deleted` event was seen first. This is also
    ///   what a stale persisted room id produces on the first refresh, delivered even though no snapshot ever arrived and
    ///   even if it happens before the consumer starts iterating. A later `observeRoom` for the same room starts a new,
    ///   independent attempt. One refresh outcome applies to every observer of the room, never just the newest.
    /// - **Invalid or deleted session** (`not_authenticated`, JWT errors): one recovery attempt (refresh the token); if it
    ///   fails, `lost(.sessionEnded)`. The app then clears its session and rooms and may sign in again.
    /// - **Any other permanent failure** (permission denied, an undecodable response, an unknown error):
    ///   `lost(.failed(error))`, so an auto-rejoin that is showing a loading state can leave it and show the error.
    /// - **Leave** (``leaveRoom()``) and **room switch** (``createRoom(name:)`` or ``joinRoom(code:name:)`` into a
    ///   different room): observers of the old room get `lost(.left)`.
    /// - **Session replacement** (``deleteMyData()``, sign-out): observers get `lost(.sessionEnded)`.
    /// - **Cancellation**: the stream finishes without a `lost`.
    ///
    /// After any `lost`, room-bound private state (the clue-giver's current ``Draw``) must be discarded, and
    /// ``connection`` is `.idle` unless another room is still observed.
    ///
    /// ## Requirements on any live implementation (Task 3.4)
    /// These decide which terminal reason a screen sees, so the Supabase implementation must satisfy them and the fake
    /// can script both orderings (``FakeGameBackend/refuseChannelJoin(_:)``, delayed local calls with
    /// ``FakeGameBackend/simulateRoomLoss(_:roomID:)``):
    /// 1. **Membership probe even when the join is refused.** A kicked client or a stale persisted room fails private
    ///    Broadcast authorisation before it can join. The implementation must still call `get_snapshot` to learn
    ///    `not_member` (and end with `lost(.removed)`); it must not wait for a successful join before fetching, or it would
    ///    retry forever. If the probe succeeds but the join is refused, deliver the snapshot, show `.reconnecting` and retry.
    /// 2. **Catch-up fetch after a successful join** whenever a snapshot was fetched before joining, so a change committed
    ///    between that fetch and the join is not missed.
    /// 3. **Defer terminal classification during local membership changes.** While a local `leave_room`, room switch
    ///    (`create_room`/`join_room`) or `delete_my_data` is in flight, a refresh or event that would classify as
    ///    `removed` or `roomDeleted` must wait for the RPC's outcome. If the RPC succeeds, the observation ends with the
    ///    local reason (`left` or `sessionEnded`) and the remote classification is discarded; if it fails, the deferred
    ///    classification then applies.
    /// 4. **One channel per active room and session**, shared by all observers (see Ownership), with a generation check on
    ///    every fetch, probe, script-free commit and loss, so results of an operation started before a leave, delete, loss
    ///    or room switch are dropped.
    /// - Parameter roomID: The room to follow.
    func observeRoom(roomID: UUID) -> AsyncStream<RoomUpdate>

    /// The state of the **live room channel**, not general network reachability. Each access returns an independent stream
    /// that first yields the current state and then changes, keeping only the newest undelivered value. One consumer per
    /// stream, as for ``observeRoom(roomID:)``.
    ///
    /// It is `.idle` when no room is observed: before any observation, after a loss, leave or delete, and after the last
    /// observer cancels. With a room observed it is `.connecting` (first join), `.connected`, `.reconnecting` (dropped or a
    /// refresh hit the network; retrying) or `.disconnected`. Show the reconnecting banner only when
    /// ``ConnectionState/showsReconnectingBanner`` is true. A Home screen should not show "connected" from this stream.
    var connection: AsyncStream<ConnectionState> { get }

    /// Tells the backend the app became active (call it when `scenePhase` becomes `.active`).
    ///
    /// The backend refreshes the Realtime auth token, reconnects the room channel if it dropped, and refetches the
    /// snapshot, publishing it on the existing ``observeRoom(roomID:)`` streams. It does not throw: a refetch that finds
    /// the seat gone ends the observation with `lost(.removed)`, and connection trouble shows on ``connection``.
    /// Calling it with no room is harmless. The clue-giver should still call ``currentSlip()`` afterwards.
    func didEnterForeground() async

    // MARK: Rooms

    /// Creates a room and seats the caller as host (`create_room`).
    /// - Parameter name: The caller's display name.
    /// - Returns: The new room's snapshot.
    /// - Throws: `.invalidName`, `.rateLimited`, `.codeUnavailable`.
    func createRoom(name: String) async throws -> RoomSnapshot

    /// Joins the room with the given code (`join_room`). A caller already in the room gets their existing
    /// seat. A new member outside the lobby becomes a spectator.
    /// - Parameters:
    ///   - code: The 4-character room code.
    ///   - name: The caller's display name.
    /// - Returns: The room's snapshot.
    /// - Throws: `.roomNotFound`, `.invalidName`, `.nameTaken`.
    func joinRoom(code: String, name: String) async throws -> RoomSnapshot

    /// Leaves the current room (`leave_room`).
    /// - Throws: `.notMember`.
    func leaveRoom() async throws

    /// Fetches the room's current snapshot (`get_snapshot`).
    ///
    /// If this fails with `.notMember` for the room the app is observing, the backend also ends that observation with
    /// `lost(.removed)`; a probe of an unrelated room does not.
    /// - Parameter roomID: The room.
    /// - Throws: `.notMember`.
    func snapshot(roomID: UUID) async throws -> RoomSnapshot

    /// Records presence (`heartbeat`). Call every 15 seconds while in a room.
    /// - Parameter roomID: The room.
    /// - Returns: The server's current time, for clock correction.
    /// - Throws: `.notMember`.
    func heartbeat(roomID: UUID) async throws -> Date

    // MARK: Lobby

    /// Assigns players to teams (`set_teams`). Host, lobby only. Assigning a spectator to a team promotes them.
    /// - Parameter assignments: Keyed by `Player.userID`. Players not listed stay put; see ``TeamAssignments``.
    /// - Throws: `.notMember`, `.notHost`, `.wrongPhase`, `.invalidTeam`, `.playerNotFound`.
    func setTeams(_ assignments: TeamAssignments) async throws

    /// Renames a team (`set_team_name`). Host, lobby only. The server trims and keeps the first 20 characters.
    /// - Parameters:
    ///   - team: 0 or 1.
    ///   - name: The new name.
    /// - Throws: `.notMember`, `.notHost`, `.wrongPhase`, `.invalidTeam`, `.invalidName`.
    func setTeamName(team: Int, name: String) async throws

    /// Changes room settings (`update_settings`). Host, lobby only.
    /// - Parameter update: The fields to change.
    /// - Throws: `.notMember`, `.notHost`, `.wrongPhase`, `.invalidSetting`.
    func updateSettings(_ update: SettingsUpdate) async throws

    /// Starts the game and opens the submission window (`start_game`). Host, lobby only.
    /// - Throws: `.notMember`, `.notHost`, `.wrongPhase`, `.notEnoughPlayers`.
    func startGame() async throws

    // MARK: Submission

    /// Submits the caller's slips (`submit_slips`). Duplicate names are kept as separate slips.
    /// - Parameter names: Exactly `slipsPerPlayer` names.
    /// - Throws: `.notMember`, `.wrongPhase`, `.submissionsClosed`, `.notAPlayer`, `.alreadySubmitted`, `.wrongSlipCount`, `.invalidSlip`.
    func submitSlips(_ names: [String]) async throws

    /// Withdraws the caller's slips so they can be edited (`retract_slips`).
    /// - Throws: `.notMember`, `.wrongPhase`, `.submissionsClosed`.
    func retractSlips() async throws

    /// Closes the submission window once its deadline has passed (`close_submissions`). Any member may call it.
    /// Starts play with the slips received, or returns to the lobby if there are none.
    /// - Throws: `.notMember`, `.wrongPhase` (benign after an empty window already reset the room), `.deadlineNotReached`.
    func closeSubmissions() async throws

    // MARK: Turns

    /// Starts the caller's turn (`start_turn`). Only the assigned clue-giver.
    /// - Returns: The first draw, or nil if the pile is empty.
    /// - Throws: `.notMember`, `.wrongPhase`, `.notYourTurn`, `.turnAlreadyStarted`.
    func startTurn() async throws -> Draw?

    /// Scores the current draw as guessed (`got_it`).
    /// - Parameter token: The token of the draw on screen. A null token is `.invalidToken`; a well-formed but stale one
    ///   changes nothing and returns the current draw (which the app should display).
    /// - Returns: The next draw, or nil when the pile is empty.
    /// - Throws: `.notMember`, `.wrongPhase`, `.notYourTurn`, `.turnNotStarted`, `.turnOver`, `.invalidToken`.
    func gotIt(token: UUID) async throws -> Draw?

    /// Puts the current draw at the back of the pile and draws another (`skip_slip`).
    /// - Parameter token: The token of the draw on screen; stale tokens behave as for ``gotIt(token:)``.
    /// - Returns: The new draw, or nil.
    /// - Throws: `.notMember`, `.wrongPhase`, `.notYourTurn`, `.turnNotStarted`, `.turnOver`, `.invalidToken`, `.skipNotAllowed`.
    func skip(token: UUID) async throws -> Draw?

    /// Fetches the clue-giver's current draw (`current_slip`), for example after a reconnect.
    /// - Returns: The draw during the caller's running, unexpired turn; nil otherwise.
    /// - Throws: `.notMember`.
    func currentSlip() async throws -> Draw?

    /// Ends the turn once `turn_ends_at` has passed (`end_turn`). Any member may call it; a no-op if no turn is running.
    /// - Throws: `.notMember`, `.deadlineNotReached`.
    func endTurn() async throws

    // MARK: Rounds

    /// Starts the next round (`start_next_round`). Host, from the round-end screen.
    /// - Throws: `.notMember`, `.notHost`, `.wrongPhase`.
    func startNextRound() async throws

    /// Resets a finished game to the lobby, keeping players, teams and settings (`reset_room`). Host only.
    /// - Throws: `.notMember`, `.notHost`, `.wrongPhase`.
    func resetRoom() async throws

    // MARK: Host and membership

    /// Moves a spectator onto a team between turns (`assign_spectator`). Host only.
    /// - Parameters:
    ///   - userID: The spectator.
    ///   - team: 0 or 1.
    /// - Throws: `.notMember`, `.notHost`, `.invalidTeam`, `.playerNotFound`, `.notSpectator`, `.turnActive`.
    func assignSpectator(userID: UUID, team: Int) async throws

    /// Makes another member the host (`transfer_host`).
    /// - Parameter userID: The new host.
    /// - Throws: `.notMember`, `.notHost`, `.cannotTargetSelf`, `.playerNotFound`.
    func transferHost(to userID: UUID) async throws

    /// Removes another member from the room (`kick_player`). Host only.
    /// - Parameter userID: The member to remove.
    /// - Throws: `.notMember`, `.notHost`, `.cannotTargetSelf`, `.playerNotFound`.
    func kickPlayer(userID: UUID) async throws

    /// Takes over as host when the host's presence is older than 45 seconds (`claim_host`).
    /// - Throws: `.notMember`, `.alreadyHost`, `.hostStillActive`.
    func claimHost() async throws

    /// Deletes the caller's data (`delete_my_data`): leaves the room, anonymises turn history and deletes an
    /// anonymous account. On success the implementation also clears its local session when the account was deleted,
    /// so the next ``currentUserID()`` signs in fresh.
    func deleteMyData() async throws

    // MARK: Recommendations

    /// Finds celebrities whose name, or any word in it, starts with the query (`suggest_celebrities`).
    /// The server needs at least two characters and returns nothing for less.
    /// - Parameters:
    ///   - query: What the player has typed.
    ///   - limit: Maximum rows, clamped by the server to 1-10.
    /// - Returns: Rows ordered by fame.
    func suggestCelebrities(query: String, limit: Int) async throws -> [CelebritySuggestion]

    /// A popularity-weighted random sample for the "Need ideas?" row (`random_celebrities`).
    /// - Parameters:
    ///   - count: How many names, clamped by the server to 1-20.
    ///   - names: Names to leave out, such as ones already entered.
    /// - Returns: Up to `count` distinct suggestions.
    func randomCelebrities(count: Int, excluding names: [String]) async throws -> [CelebritySuggestion]
}

extension GameBackend {
    /// ``suggestCelebrities(query:limit:)`` with the server's default limit of 6.
    /// - Parameter query: What the player has typed.
    public func suggestCelebrities(query: String) async throws -> [CelebritySuggestion] {
        try await suggestCelebrities(query: query, limit: 6)
    }
}
