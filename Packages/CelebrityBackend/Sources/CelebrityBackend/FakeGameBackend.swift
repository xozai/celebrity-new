import CelebrityCore
import Foundation

/// A scriptable ``GameBackend`` for SwiftUI previews, unit tests and UI tests.
///
/// The fake replays canned snapshots and draws and records every call. It **does not implement any game
/// rules**: `startGame()` succeeds on an empty lobby, `gotIt(token:)` never checks the token, and a call changes
/// state only if a test scripted a snapshot for it with ``script(_:snapshots:)`` or calls ``push(_:)``.
/// To exercise error paths, arm a failure with ``fail(_:with:times:)``.
///
/// ```swift
/// let backend = FakeGameBackend(scenario: .make(.playingClueGiver))   // preview
///
/// let fake = FakeGameBackend(scenario: .make(.lobbyHost))             // test
/// fake.fail(.startGame, with: .notEnoughPlayers)
/// await model.start()
/// #expect(fake.calls == [.startGame])
/// ```
///
/// Everything is thread-safe. Configuration methods are synchronous so previews can set them up inline.
/// It imports no networking code and does not need Supabase.
public final class FakeGameBackend: GameBackend, @unchecked Sendable {
    // MARK: Call recording

    /// The kind of a backend call, without arguments. Used to arm failures, delays and scripted snapshots.
    public enum CallKind: Sendable, Equatable, Hashable, CaseIterable {
        /// ``GameBackend/currentUserID()``
        case currentUserID
        /// ``GameBackend/createRoom(name:)``
        case createRoom
        /// ``GameBackend/joinRoom(code:name:)``
        case joinRoom
        /// ``GameBackend/leaveRoom()``
        case leaveRoom
        /// ``GameBackend/snapshot(roomID:)``
        case snapshot
        /// ``GameBackend/heartbeat(roomID:)``
        case heartbeat
        /// ``GameBackend/setTeams(_:)``
        case setTeams
        /// ``GameBackend/setTeamName(team:name:)``
        case setTeamName
        /// ``GameBackend/updateSettings(_:)``
        case updateSettings
        /// ``GameBackend/startGame()``
        case startGame
        /// ``GameBackend/submitSlips(_:)``
        case submitSlips
        /// ``GameBackend/retractSlips()``
        case retractSlips
        /// ``GameBackend/closeSubmissions()``
        case closeSubmissions
        /// ``GameBackend/startTurn()``
        case startTurn
        /// ``GameBackend/gotIt(token:)``
        case gotIt
        /// ``GameBackend/skip(token:)``
        case skip
        /// ``GameBackend/currentSlip()``
        case currentSlip
        /// ``GameBackend/endTurn()``
        case endTurn
        /// ``GameBackend/startNextRound()``
        case startNextRound
        /// ``GameBackend/resetRoom()``
        case resetRoom
        /// ``GameBackend/assignSpectator(userID:team:)``
        case assignSpectator
        /// ``GameBackend/transferHost(to:)``
        case transferHost
        /// ``GameBackend/kickPlayer(userID:)``
        case kickPlayer
        /// ``GameBackend/claimHost()``
        case claimHost
        /// ``GameBackend/deleteMyData()``
        case deleteMyData
        /// ``GameBackend/suggestCelebrities(query:limit:)``
        case suggestCelebrities
        /// ``GameBackend/randomCelebrities(count:excluding:)``
        case randomCelebrities
    }

    /// One recorded call with its arguments, in the order received. Failed calls are recorded too.
    public enum Call: Sendable, Equatable {
        /// ``GameBackend/currentUserID()``
        case currentUserID
        /// ``GameBackend/createRoom(name:)``
        case createRoom(name: String)
        /// ``GameBackend/joinRoom(code:name:)``
        case joinRoom(code: String, name: String)
        /// ``GameBackend/leaveRoom()``
        case leaveRoom
        /// ``GameBackend/snapshot(roomID:)``
        case snapshot(roomID: UUID)
        /// ``GameBackend/heartbeat(roomID:)``
        case heartbeat(roomID: UUID)
        /// ``GameBackend/setTeams(_:)``
        case setTeams([UUID: Int?])
        /// ``GameBackend/setTeamName(team:name:)``
        case setTeamName(team: Int, name: String)
        /// ``GameBackend/updateSettings(_:)``
        case updateSettings(SettingsUpdate)
        /// ``GameBackend/startGame()``
        case startGame
        /// ``GameBackend/submitSlips(_:)``
        case submitSlips([String])
        /// ``GameBackend/retractSlips()``
        case retractSlips
        /// ``GameBackend/closeSubmissions()``
        case closeSubmissions
        /// ``GameBackend/startTurn()``
        case startTurn
        /// ``GameBackend/gotIt(token:)``
        case gotIt(token: UUID)
        /// ``GameBackend/skip(token:)``
        case skip(token: UUID)
        /// ``GameBackend/currentSlip()``
        case currentSlip
        /// ``GameBackend/endTurn()``
        case endTurn
        /// ``GameBackend/startNextRound()``
        case startNextRound
        /// ``GameBackend/resetRoom()``
        case resetRoom
        /// ``GameBackend/assignSpectator(userID:team:)``
        case assignSpectator(userID: UUID, team: Int)
        /// ``GameBackend/transferHost(to:)``
        case transferHost(to: UUID)
        /// ``GameBackend/kickPlayer(userID:)``
        case kickPlayer(userID: UUID)
        /// ``GameBackend/claimHost()``
        case claimHost
        /// ``GameBackend/deleteMyData()``
        case deleteMyData
        /// ``GameBackend/suggestCelebrities(query:limit:)``
        case suggestCelebrities(query: String, limit: Int)
        /// ``GameBackend/randomCelebrities(count:excluding:)``
        case randomCelebrities(count: Int, excluding: [String])

        /// The call's kind, without arguments.
        public var kind: CallKind {
            switch self {
            case .currentUserID: .currentUserID
            case .createRoom: .createRoom
            case .joinRoom: .joinRoom
            case .leaveRoom: .leaveRoom
            case .snapshot: .snapshot
            case .heartbeat: .heartbeat
            case .setTeams: .setTeams
            case .setTeamName: .setTeamName
            case .updateSettings: .updateSettings
            case .startGame: .startGame
            case .submitSlips: .submitSlips
            case .retractSlips: .retractSlips
            case .closeSubmissions: .closeSubmissions
            case .startTurn: .startTurn
            case .gotIt: .gotIt
            case .skip: .skip
            case .currentSlip: .currentSlip
            case .endTurn: .endTurn
            case .startNextRound: .startNextRound
            case .resetRoom: .resetRoom
            case .assignSpectator: .assignSpectator
            case .transferHost: .transferHost
            case .kickPlayer: .kickPlayer
            case .claimHost: .claimHost
            case .deleteMyData: .deleteMyData
            case .suggestCelebrities: .suggestCelebrities
            case .randomCelebrities: .randomCelebrities
            }
        }
    }

    // MARK: State

    private struct Failure {
        var error: BackendError
        var remaining: Int?
    }

    private struct State {
        var userID: UUID
        var snapshot: RoomSnapshot?
        var connection: ConnectionState
        var calls: [Call] = []
        var failures: [CallKind: Failure] = [:]
        var delays: [CallKind: Duration] = [:]
        var snapshotScripts: [CallKind: [RoomSnapshot]] = [:]
        var draws: [Draw?] = []
        var currentDraw: Draw?
        var suggestions: [CelebritySuggestion]
        var suggestionsByQuery: [String: [CelebritySuggestion]] = [:]
        var suggestionDelays: [String: Duration] = [:]
        var randomSuggestions: [CelebritySuggestion]
        var updateSubscribers: [UUID: (roomID: UUID, continuation: AsyncStream<RoomSnapshot>.Continuation)] = [:]
        var connectionSubscribers: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
        var lossSubscribers: [UUID: AsyncStream<RoomLoss>.Continuation] = [:]
    }

    private let lock = NSLock()
    private var state: State

    private func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    // MARK: Creating

    /// Creates a fake.
    /// - Parameters:
    ///   - userID: The signed-in user returned by ``currentUserID()``.
    ///   - snapshot: The room the user is in, or nil for none. Returned by the snapshot-returning calls and
    ///     replayed first on ``updates(roomID:)``.
    ///   - connection: The initial connection state.
    ///   - draw: The draw returned by ``currentSlip()`` until the draw script runs.
    ///   - suggestions: Rows returned by ``suggestCelebrities(query:limit:)``. Defaults to ``SampleSuggestions/all``.
    public init(
        userID: UUID = SampleCast.alex.id,
        snapshot: RoomSnapshot? = nil,
        connection: ConnectionState = .connected,
        draw: Draw? = nil,
        suggestions: [CelebritySuggestion] = SampleSuggestions.all
    ) {
        state = State(
            userID: userID,
            snapshot: snapshot,
            connection: connection,
            currentDraw: draw,
            suggestions: suggestions,
            randomSuggestions: SampleSuggestions.all
        )
    }

    /// Creates a fake showing a ready-made screen state: its viewer, snapshot and (for a clue-giver) draw.
    /// - Parameter scenario: The scenario, usually from ``SampleScenario/make(_:now:)``.
    public convenience init(scenario: SampleScenario) {
        self.init(userID: scenario.userID, snapshot: scenario.snapshot, draw: scenario.draw)
    }

    // MARK: Test controls: inspecting

    /// Every call received so far, oldest first, including calls that were made to fail.
    public var calls: [Call] { withState { $0.calls } }

    /// The calls of one kind, oldest first.
    /// - Parameter kind: The kind to keep.
    public func calls(of kind: CallKind) -> [Call] { withState { $0.calls.filter { $0.kind == kind } } }

    /// Forgets the recorded calls.
    public func resetCalls() { withState { $0.calls = [] } }

    /// The snapshot the fake currently considers the room's state, or nil if the user is in no room.
    public var currentSnapshot: RoomSnapshot? { withState { $0.snapshot } }

    // MARK: Test controls: scripting

    /// Makes calls of `kind` throw `error`.
    /// - Parameters:
    ///   - kind: The call to fail.
    ///   - error: The error to throw.
    ///   - times: How many calls fail before the call works again. Default 1.
    public func fail(_ kind: CallKind, with error: BackendError, times: Int = 1) {
        withState { $0.failures[kind] = Failure(error: error, remaining: times) }
    }

    /// Makes every call of `kind` throw `error` until ``clearFailures()``.
    /// - Parameters:
    ///   - kind: The call to fail.
    ///   - error: The error to throw.
    public func failAlways(_ kind: CallKind, with error: BackendError) {
        withState { $0.failures[kind] = Failure(error: error, remaining: nil) }
    }

    /// Removes every armed failure.
    public func clearFailures() { withState { $0.failures = [:] } }

    /// Scripts the snapshots a call produces, replayed one per successful call.
    ///
    /// For a call that returns a snapshot (``createRoom(name:)``, ``joinRoom(code:name:)``,
    /// ``snapshot(roomID:)``) the next scripted snapshot is returned. For any call, a successful call makes the
    /// next scripted snapshot current and publishes it on ``updates(roomID:)``, as if the server had changed.
    /// When the script is empty, snapshot-returning calls return the current snapshot and others change nothing.
    /// - Parameters:
    ///   - kind: The call to script.
    ///   - snapshots: The snapshots, in order.
    public func script(_ kind: CallKind, snapshots: [RoomSnapshot]) {
        withState { $0.snapshotScripts[kind] = snapshots }
    }

    /// Replaces the queue of draws returned by ``startTurn()``, ``gotIt(token:)`` and ``skip(token:)``, in order.
    ///
    /// Each of those calls takes the next element (nil means "pile empty") and makes it what ``currentSlip()``
    /// returns. Once the queue is empty they return nil. The fake never checks tokens, so script a stale-token
    /// reply by queuing the draw the server would return.
    /// - Parameter draws: The draws, oldest first.
    public func setDraws(_ draws: [Draw?]) { withState { $0.draws = draws } }

    /// Sets the rows ``suggestCelebrities(query:limit:)`` returns, truncated to `limit`.
    /// - Parameters:
    ///   - rows: The rows.
    ///   - query: When given, applies only to that query (case-insensitive, trimmed). Otherwise it is the default.
    public func setSuggestions(_ rows: [CelebritySuggestion], forQuery query: String? = nil) {
        withState {
            if let query {
                $0.suggestionsByQuery[Self.normalise(query)] = rows
            } else {
                $0.suggestions = rows
            }
        }
    }

    /// Sets the rows ``randomCelebrities(count:excluding:)`` returns, truncated to `count`. Exclusions are recorded but not applied.
    /// - Parameter rows: The rows.
    public func setRandomSuggestions(_ rows: [CelebritySuggestion]) { withState { $0.randomSuggestions = rows } }

    /// Delays every call of a kind by `duration` before it completes. The delay honours task cancellation by throwing `CancellationError`.
    /// - Parameters:
    ///   - duration: How long to wait.
    ///   - kind: The call to delay.
    public func setDelay(_ duration: Duration, for kind: CallKind) { withState { $0.delays[kind] = duration } }

    /// Delays ``suggestCelebrities(query:limit:)`` for one query, so a slow earlier query can finish after a newer one.
    /// - Parameters:
    ///   - duration: How long to wait.
    ///   - query: The query to delay (case-insensitive, trimmed).
    public func setSuggestionDelay(_ duration: Duration, forQuery query: String) {
        withState { $0.suggestionDelays[Self.normalise(query)] = duration }
    }

    // MARK: Test controls: pushing

    /// Makes `snapshot` the current state and yields it to ``updates(roomID:)`` subscribers of its room.
    /// - Parameter snapshot: The new state.
    public func push(_ snapshot: RoomSnapshot) {
        let targets: [AsyncStream<RoomSnapshot>.Continuation] = withState { state in
            state.snapshot = snapshot
            return state.updateSubscribers.values.filter { $0.roomID == snapshot.room.id }.map(\.continuation)
        }
        for target in targets { target.yield(snapshot) }
    }

    /// Publishes a new connection state on ``connection``.
    /// - Parameter newState: The state.
    public func setConnection(_ newState: ConnectionState) {
        let targets: [AsyncStream<ConnectionState>.Continuation] = withState { state in
            state.connection = newState
            return Array(state.connectionSubscribers.values)
        }
        for target in targets { target.yield(newState) }
    }

    /// Simulates losing the room, as the real backend does after a `not_member` refresh or a `room_deleted` event.
    ///
    /// Publishes a ``RoomLoss`` on ``roomLosses``, finishes that room's ``updates(roomID:)`` streams and clears
    /// ``currentSnapshot``. Does nothing if there is no room to lose.
    /// - Parameters:
    ///   - reason: Why the room was lost.
    ///   - roomID: The room. Defaults to the current snapshot's room.
    public func simulateRoomLoss(_ reason: RoomLoss.Reason, roomID: UUID? = nil) {
        let (loss, subscribers, finishing): (RoomLoss?, [AsyncStream<RoomLoss>.Continuation], [AsyncStream<RoomSnapshot>.Continuation]) = withState { state in
            guard let id = roomID ?? state.snapshot?.room.id else { return (nil, [], []) }
            if state.snapshot?.room.id == id { state.snapshot = nil }
            let matching = state.updateSubscribers.filter { $0.value.roomID == id }
            for key in matching.keys { state.updateSubscribers[key] = nil }
            return (RoomLoss(roomID: id, reason: reason), Array(state.lossSubscribers.values), matching.values.map(\.continuation))
        }
        guard let loss else { return }
        for subscriber in subscribers { subscriber.yield(loss) }
        for continuation in finishing { continuation.finish() }
    }

    /// Finishes every open stream (updates, connection, room losses), as when the app leaves a session.
    public func finishStreams() {
        let (updates, connections, losses) = withState { state in
            let result = (
                state.updateSubscribers.values.map(\.continuation),
                Array(state.connectionSubscribers.values),
                Array(state.lossSubscribers.values)
            )
            state.updateSubscribers = [:]
            state.connectionSubscribers = [:]
            state.lossSubscribers = [:]
            return result
        }
        updates.forEach { $0.finish() }
        connections.forEach { $0.finish() }
        losses.forEach { $0.finish() }
    }

    // MARK: Streams

    /// Yields the current snapshot if it belongs to `roomID`, then every pushed or scripted snapshot of that room.
    public func updates(roomID: UUID) -> AsyncStream<RoomSnapshot> {
        let (stream, continuation) = AsyncStream<RoomSnapshot>.makeStream()
        let key = UUID()
        let initial: RoomSnapshot? = withState { state in
            state.updateSubscribers[key] = (roomID, continuation)
            return state.snapshot?.room.id == roomID ? state.snapshot : nil
        }
        if let initial { continuation.yield(initial) }
        continuation.onTermination = { [weak self] _ in
            self?.withState { $0.updateSubscribers[key] = nil }
        }
        return stream
    }

    /// Yields the current connection state, then each change made with ``setConnection(_:)``.
    public var connection: AsyncStream<ConnectionState> {
        let (stream, continuation) = AsyncStream<ConnectionState>.makeStream()
        let key = UUID()
        let initial = withState { state in
            state.connectionSubscribers[key] = continuation
            return state.connection
        }
        continuation.yield(initial)
        continuation.onTermination = { [weak self] _ in
            self?.withState { $0.connectionSubscribers[key] = nil }
        }
        return stream
    }

    /// Yields each loss made with ``simulateRoomLoss(_:roomID:)``.
    public var roomLosses: AsyncStream<RoomLoss> {
        let (stream, continuation) = AsyncStream<RoomLoss>.makeStream()
        let key = UUID()
        withState { $0.lossSubscribers[key] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.withState { $0.lossSubscribers[key] = nil }
        }
        return stream
    }

    // MARK: Plumbing

    private static func normalise(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Records the call, waits out any delay, then throws an armed failure.
    private func enter(_ call: Call, extraDelay: Duration? = nil) async throws {
        let delay: Duration? = withState { state in
            state.calls.append(call)
            return extraDelay ?? state.delays[call.kind]
        }
        if let delay { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        let failure: BackendError? = withState { state in
            guard var failure = state.failures[call.kind] else { return nil }
            if let remaining = failure.remaining {
                if remaining <= 1 { state.failures[call.kind] = nil } else {
                    failure.remaining = remaining - 1
                    state.failures[call.kind] = failure
                }
            }
            return failure.error
        }
        if let failure { throw failure }
    }

    /// Pops the next scripted snapshot for `kind`, makes it current and publishes it.
    @discardableResult
    private func playScript(_ kind: CallKind) -> RoomSnapshot? {
        let next: RoomSnapshot? = withState { state in
            guard var queue = state.snapshotScripts[kind], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            state.snapshotScripts[kind] = queue
            return next
        }
        if let next { push(next) }
        return next
    }

    private func snapshotResult(_ kind: CallKind, roomID: UUID? = nil) throws -> RoomSnapshot {
        if let scripted = playScript(kind) { return scripted }
        guard let current = currentSnapshot else {
            if roomID != nil { throw BackendError.notMember }
            throw BackendError.unknown("FakeGameBackend has no snapshot: pass one to init or script(_:snapshots:)")
        }
        if let roomID, roomID != current.room.id { throw BackendError.notMember }
        return current
    }

    private func nextDraw() -> Draw? {
        withState { state in
            let draw = state.draws.isEmpty ? nil : state.draws.removeFirst()
            state.currentDraw = draw
            return draw
        }
    }

    // MARK: GameBackend

    /// Returns the `userID` given at init.
    public func currentUserID() async throws -> UUID {
        try await enter(.currentUserID)
        return withState { $0.userID }
    }

    /// Returns the next scripted snapshot, else the current one.
    public func createRoom(name: String) async throws -> RoomSnapshot {
        try await enter(.createRoom(name: name))
        return try snapshotResult(.createRoom)
    }

    /// Returns the next scripted snapshot, else the current one.
    public func joinRoom(code: String, name: String) async throws -> RoomSnapshot {
        try await enter(.joinRoom(code: code, name: name))
        return try snapshotResult(.joinRoom)
    }

    /// Records the call and plays any scripted snapshot. Does not clear the current room; push or script that.
    public func leaveRoom() async throws {
        try await enter(.leaveRoom)
        playScript(.leaveRoom)
    }

    /// Returns the next scripted snapshot, else the current one; `.notMember` if the id is not the current room's.
    public func snapshot(roomID: UUID) async throws -> RoomSnapshot {
        try await enter(.snapshot(roomID: roomID))
        return try snapshotResult(.snapshot, roomID: roomID)
    }

    /// Returns the current snapshot's `serverNow`, or the device time if there is none.
    public func heartbeat(roomID: UUID) async throws -> Date {
        try await enter(.heartbeat(roomID: roomID))
        playScript(.heartbeat)
        return currentSnapshot?.serverNow ?? Date()
    }

    /// Records the call and plays any scripted snapshot.
    public func setTeams(_ assignments: [UUID: Int?]) async throws {
        try await enter(.setTeams(assignments))
        playScript(.setTeams)
    }

    /// Records the call and plays any scripted snapshot.
    public func setTeamName(team: Int, name: String) async throws {
        try await enter(.setTeamName(team: team, name: name))
        playScript(.setTeamName)
    }

    /// Records the call and plays any scripted snapshot.
    public func updateSettings(_ update: SettingsUpdate) async throws {
        try await enter(.updateSettings(update))
        playScript(.updateSettings)
    }

    /// Records the call and plays any scripted snapshot. Applies no rules.
    public func startGame() async throws {
        try await enter(.startGame)
        playScript(.startGame)
    }

    /// Records the call and plays any scripted snapshot.
    public func submitSlips(_ names: [String]) async throws {
        try await enter(.submitSlips(names))
        playScript(.submitSlips)
    }

    /// Records the call and plays any scripted snapshot.
    public func retractSlips() async throws {
        try await enter(.retractSlips)
        playScript(.retractSlips)
    }

    /// Records the call and plays any scripted snapshot.
    public func closeSubmissions() async throws {
        try await enter(.closeSubmissions)
        playScript(.closeSubmissions)
    }

    /// Takes the next draw from ``setDraws(_:)``.
    public func startTurn() async throws -> Draw? {
        try await enter(.startTurn)
        playScript(.startTurn)
        return nextDraw()
    }

    /// Takes the next draw from ``setDraws(_:)``. The token is recorded, not checked.
    public func gotIt(token: UUID) async throws -> Draw? {
        try await enter(.gotIt(token: token))
        playScript(.gotIt)
        return nextDraw()
    }

    /// Takes the next draw from ``setDraws(_:)``. The token is recorded, not checked.
    public func skip(token: UUID) async throws -> Draw? {
        try await enter(.skip(token: token))
        playScript(.skip)
        return nextDraw()
    }

    /// Returns the last draw handed out (or the `draw` given at init).
    public func currentSlip() async throws -> Draw? {
        try await enter(.currentSlip)
        return withState { $0.currentDraw }
    }

    /// Records the call and plays any scripted snapshot.
    public func endTurn() async throws {
        try await enter(.endTurn)
        playScript(.endTurn)
    }

    /// Records the call and plays any scripted snapshot.
    public func startNextRound() async throws {
        try await enter(.startNextRound)
        playScript(.startNextRound)
    }

    /// Records the call and plays any scripted snapshot.
    public func resetRoom() async throws {
        try await enter(.resetRoom)
        playScript(.resetRoom)
    }

    /// Records the call and plays any scripted snapshot.
    public func assignSpectator(userID: UUID, team: Int) async throws {
        try await enter(.assignSpectator(userID: userID, team: team))
        playScript(.assignSpectator)
    }

    /// Records the call and plays any scripted snapshot.
    public func transferHost(to userID: UUID) async throws {
        try await enter(.transferHost(to: userID))
        playScript(.transferHost)
    }

    /// Records the call and plays any scripted snapshot.
    public func kickPlayer(userID: UUID) async throws {
        try await enter(.kickPlayer(userID: userID))
        playScript(.kickPlayer)
    }

    /// Records the call and plays any scripted snapshot.
    public func claimHost() async throws {
        try await enter(.claimHost)
        playScript(.claimHost)
    }

    /// Records the call and plays any scripted snapshot. Does not reset the user id.
    public func deleteMyData() async throws {
        try await enter(.deleteMyData)
        playScript(.deleteMyData)
    }

    /// Returns the rows set for this query with ``setSuggestions(_:forQuery:)``, else the default rows, truncated to `limit`.
    public func suggestCelebrities(query: String, limit: Int) async throws -> [CelebritySuggestion] {
        let key = Self.normalise(query)
        let delay = withState { $0.suggestionDelays[key] }
        try await enter(.suggestCelebrities(query: query, limit: limit), extraDelay: delay)
        return withState { state in
            Array((state.suggestionsByQuery[key] ?? state.suggestions).prefix(max(limit, 0)))
        }
    }

    /// Returns the rows from ``setRandomSuggestions(_:)``, truncated to `count`. The exclusions are recorded only.
    public func randomCelebrities(count: Int, excluding names: [String]) async throws -> [CelebritySuggestion] {
        try await enter(.randomCelebrities(count: count, excluding: names))
        return withState { Array($0.randomSuggestions.prefix(max(count, 0))) }
    }
}
