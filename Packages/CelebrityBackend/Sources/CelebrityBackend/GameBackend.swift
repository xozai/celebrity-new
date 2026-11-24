import CelebrityCore
import Foundation

/// Everything the app needs from a game server, with Swift names and typed arguments.
///
/// There is one method per app RPC in docs/PLAN.md section 6. Implementations are
/// ``FakeGameBackend`` (previews, UI tests) and a Supabase client. This file and its siblings do not
/// import Supabase.
///
/// ## Use from a view model
/// The protocol is `Sendable` and every method is `async throws`, so a `@MainActor @Observable`
/// view model can hold an `any GameBackend` and call it directly under Swift 6 strict concurrency.
/// All results are `Sendable` value types.
///
/// ## Errors
/// Methods throw ``BackendError``. Domain failures are specific cases (`.wrongPhase`, `.notHost`, ...),
/// transport failures are ``BackendError/network(_:)``. Show ``BackendError/userMessage``.
///
/// ## Live state
/// Game state is whole ``RoomSnapshot``s. Call a method, then read the next snapshot from
/// ``updates(roomID:)``; the return value of void calls carries no state. Slips and draw tokens are never
/// in snapshots; the clue-giver gets ``Draw``s from ``startTurn()``, ``gotIt(token:)``, ``skip(token:)``
/// and ``currentSlip()``.
public protocol GameBackend: Sendable {
    // MARK: Identity and live state

    /// The signed-in user's id, signing in anonymously first if there is no session.
    ///
    /// The id equals `Player.userID` for the caller's seat, so pass it to the `RoomSnapshot` helpers
    /// (`me(userID:)`, `isHost(userID:)`, ...). It is stable for the install; call once at launch and keep it.
    /// - Throws: ``BackendError/network(_:)`` if sign-in cannot reach the server.
    func currentUserID() async throws -> UUID

    /// Snapshots for one room, each time it changes.
    ///
    /// The stream joins the room's live channel, yields the current snapshot first, then a fresh one after
    /// every change, reconnect and return to foreground. Bursts of changes may be coalesced. It carries only
    /// successful snapshots: if a refresh fails because the seat is gone, the stream stays open and the loss
    /// is reported on ``roomLosses`` instead. Cancel the consuming task (or finish iterating) to unsubscribe.
    /// Each call returns an independent stream.
    /// - Parameter roomID: The room to follow. Must be a room the caller is a member of.
    func updates(roomID: UUID) -> AsyncStream<RoomSnapshot>

    /// The live connection state. Each access returns an independent stream that first yields the current state.
    var connection: AsyncStream<ConnectionState> { get }

    /// Reports that the room the app is in is gone for this user.
    ///
    /// Emits ``RoomLoss/Reason/removed`` when a refresh of the joined room fails with `not_member`
    /// (kicked or otherwise removed), or ``RoomLoss/Reason/roomDeleted`` when a `room_deleted` event was
    /// seen first. After one is emitted the implementation closes that room's channel. The app should alert,
    /// return Home and clear stored room state. Each access returns an independent stream.
    var roomLosses: AsyncStream<RoomLoss> { get }

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
    /// If this fails with `.notMember` for the room the app is in, the backend also reports it on ``roomLosses``.
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
    /// - Parameter assignments: Player id to team. A missing id is left alone, `0` or `1` assigns,
    ///   and an explicit `nil` unassigns.
    /// - Throws: `.notHost`, `.wrongPhase`, `.invalidTeam`, `.playerNotFound`.
    func setTeams(_ assignments: [UUID: Int?]) async throws

    /// Renames a team (`set_team_name`). Host, lobby only. The server trims and keeps the first 20 characters.
    /// - Parameters:
    ///   - team: 0 or 1.
    ///   - name: The new name.
    /// - Throws: `.notHost`, `.wrongPhase`, `.invalidTeam`, `.invalidName`.
    func setTeamName(team: Int, name: String) async throws

    /// Changes room settings (`update_settings`). Host, lobby only.
    /// - Parameter update: The fields to change.
    /// - Throws: `.notHost`, `.wrongPhase`, `.invalidSetting`.
    func updateSettings(_ update: SettingsUpdate) async throws

    /// Starts the game and opens the submission window (`start_game`). Host, lobby only.
    /// - Throws: `.notHost`, `.wrongPhase`, `.notEnoughPlayers`.
    func startGame() async throws

    // MARK: Submission

    /// Submits the caller's slips (`submit_slips`). Duplicate names are kept as separate slips.
    /// - Parameter names: Exactly `slipsPerPlayer` names.
    /// - Throws: `.wrongPhase`, `.submissionsClosed`, `.notAPlayer`, `.alreadySubmitted`, `.wrongSlipCount`, `.invalidSlip`.
    func submitSlips(_ names: [String]) async throws

    /// Withdraws the caller's slips so they can be edited (`retract_slips`).
    /// - Throws: `.wrongPhase`, `.submissionsClosed`.
    func retractSlips() async throws

    /// Closes the submission window once its deadline has passed (`close_submissions`). Any member may call it.
    /// Starts play with the slips received, or returns to the lobby if there are none.
    /// - Throws: `.wrongPhase` (benign after an empty window already reset the room), `.deadlineNotReached`.
    func closeSubmissions() async throws

    // MARK: Turns

    /// Starts the caller's turn (`start_turn`). Only the assigned clue-giver.
    /// - Returns: The first draw, or nil if the pile is empty.
    /// - Throws: `.wrongPhase`, `.notYourTurn`, `.turnAlreadyStarted`.
    func startTurn() async throws -> Draw?

    /// Scores the current draw as guessed (`got_it`).
    /// - Parameter token: The token of the draw on screen.
    /// - Returns: The next draw, or nil when the pile is empty. A stale token changes nothing and returns the current draw.
    /// - Throws: `.wrongPhase`, `.notYourTurn`, `.turnNotStarted`, `.turnOver`, `.invalidToken`.
    func gotIt(token: UUID) async throws -> Draw?

    /// Puts the current draw at the back of the pile and draws another (`skip_slip`).
    /// - Parameter token: The token of the draw on screen.
    /// - Returns: The new draw, or nil. A stale token changes nothing and returns the current draw.
    /// - Throws: `.wrongPhase`, `.notYourTurn`, `.turnNotStarted`, `.turnOver`, `.invalidToken`, `.skipNotAllowed`.
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
    /// - Throws: `.notHost`, `.wrongPhase`.
    func startNextRound() async throws

    /// Resets a finished game to the lobby, keeping players, teams and settings (`reset_room`). Host only.
    /// - Throws: `.notHost`, `.wrongPhase`.
    func resetRoom() async throws

    // MARK: Host and membership

    /// Moves a spectator onto a team between turns (`assign_spectator`). Host only.
    /// - Parameters:
    ///   - userID: The spectator.
    ///   - team: 0 or 1.
    /// - Throws: `.notHost`, `.invalidTeam`, `.playerNotFound`, `.notSpectator`, `.turnActive`.
    func assignSpectator(userID: UUID, team: Int) async throws

    /// Makes another member the host (`transfer_host`).
    /// - Parameter userID: The new host.
    /// - Throws: `.notHost`, `.cannotTargetSelf`, `.playerNotFound`.
    func transferHost(to userID: UUID) async throws

    /// Removes another member from the room (`kick_player`). Host only.
    /// - Parameter userID: The member to remove.
    /// - Throws: `.notHost`, `.cannotTargetSelf`, `.playerNotFound`.
    func kickPlayer(userID: UUID) async throws

    /// Takes over as host when the host's presence is older than 45 seconds (`claim_host`).
    /// - Throws: `.alreadyHost`, `.hostStillActive`.
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
