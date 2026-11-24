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
/// ## Concurrency
/// Everything is thread-safe. Every state change and the publication it causes happen in one critical section, so
/// subscribers see snapshots in commit order, a new subscriber's initial value can never overwrite a newer push, and a
/// scripted snapshot is published together with the private draw it belongs to. Observation streams keep only the newest
/// element. Termination callbacks never take the state lock. Dropping the fake finishes every outstanding stream.
/// Configuration methods are synchronous so previews can set them up inline. No networking code, no Supabase.
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
        /// ``GameBackend/didEnterForeground()``
        case didEnterForeground
        /// ``GameBackend/snapshot(roomID:)``, and the implicit first refresh of ``GameBackend/observeRoom(roomID:)``
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
        /// ``GameBackend/didEnterForeground()``
        case didEnterForeground
        /// ``GameBackend/snapshot(roomID:)``, and the implicit first refresh of ``GameBackend/observeRoom(roomID:)``
        case snapshot(roomID: UUID)
        /// ``GameBackend/heartbeat(roomID:)``
        case heartbeat(roomID: UUID)
        /// ``GameBackend/setTeams(_:)``
        case setTeams(TeamAssignments)
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
            case .didEnterForeground: .didEnterForeground
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

    /// What ``deleteMyData()`` does to the fake's identity.
    public enum DeletionOutcome: Sendable, Equatable {
        /// The anonymous account is deleted, so the next ``currentUserID()`` returns a brand-new id. The default.
        case freshAnonymousIdentity
        /// The account survives (a non-anonymous login): the user id stays.
        case retainedIdentity
    }

    private struct Failure {
        var error: BackendError
        var remaining: Int?
    }

    private struct Observer {
        var roomID: UUID
        var continuation: AsyncStream<RoomUpdate>.Continuation
    }

    private enum Removal {
        case observer(UUID)
        case connection(UUID)
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
        var deletionOutcome = DeletionOutcome.freshAnonymousIdentity
        var suggestions: [CelebritySuggestion]
        var suggestionsByQuery: [String: [CelebritySuggestion]] = [:]
        var suggestionDelays: [String: Duration] = [:]
        var randomPool: [CelebritySuggestion]
        var randomSequence: [[CelebritySuggestion]] = []
        var randomCalls = 0
        var observers: [UUID: Observer] = [:]
        var connectionSubscribers: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
    }

    private let lock = NSLock()
    private var state: State
    /// Termination callbacks only touch this, never the state lock, so finishing a stream under the state lock cannot deadlock.
    private let removalLock = NSLock()
    private var pendingRemovals: [Removal] = []

    /// Runs `body` in the state's critical section, after applying stream removals queued by termination callbacks.
    private func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        removalLock.lock()
        let removals = pendingRemovals
        pendingRemovals = []
        removalLock.unlock()
        for removal in removals {
            switch removal {
            case .observer(let key): state.observers[key] = nil
            case .connection(let key): state.connectionSubscribers[key] = nil
            }
        }
        return body(&state)
    }

    private func queueRemoval(_ removal: Removal) {
        removalLock.lock()
        pendingRemovals.append(removal)
        removalLock.unlock()
    }

    deinit {
        for observer in state.observers.values { observer.continuation.finish() }
        for subscriber in state.connectionSubscribers.values { subscriber.finish() }
    }

    // MARK: Creating

    /// Creates a fake.
    /// - Parameters:
    ///   - userID: The signed-in user returned by ``currentUserID()``.
    ///   - snapshot: The room the user is in, or nil for none. Returned by the snapshot-returning calls and
    ///     delivered first by ``observeRoom(roomID:)``.
    ///   - connection: The initial connection state.
    ///   - draw: The draw returned by ``currentSlip()`` until the draw script runs.
    ///   - suggestions: The default pool for ``suggestCelebrities(query:limit:)``. Defaults to ``SampleSuggestions/all``.
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
            randomPool: SampleSuggestions.all
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

    /// The number of live ``observeRoom(roomID:)`` streams (cancelled and finished ones are not counted).
    public var observerCount: Int { withState { $0.observers.count } }

    /// The number of live ``connection`` streams.
    public var connectionObserverCount: Int { withState { $0.connectionSubscribers.count } }

    /// The clue-giver's private draw as ``currentSlip()`` would return it.
    public var currentDraw: Draw? { withState { $0.currentDraw } }

    // MARK: Test controls: scripting

    /// Makes calls of `kind` throw `error`.
    /// - Parameters:
    ///   - kind: The call to fail.
    ///   - error: The error to throw.
    ///   - times: How many calls fail before the call works again. Default 1.
    ///
    /// A `.notMember` failure of ``GameBackend/snapshot(roomID:)`` for the room being observed ends that observation
    /// with `lost(.removed)`, as the real backend does. Armed on `.snapshot`, it is also consumed by the first refresh
    /// of ``observeRoom(roomID:)``. On ``GameBackend/didEnterForeground()`` (which cannot throw) `.notMember`
    /// ends the observation and a network error publishes `.reconnecting`.
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
    /// For a call that returns a snapshot (``createRoom(name:)``, ``joinRoom(code:name:)``, ``snapshot(roomID:)``) the
    /// next scripted snapshot is returned. For any call except ``leaveRoom()`` and ``deleteMyData()`` (which always
    /// clear the room), a successful call makes the next scripted snapshot current and delivers it to observers, in the
    /// same critical section as the call's draw, as if the server had changed. When the script is empty,
    /// snapshot-returning calls return the current snapshot and others change nothing.
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

    /// Replaces what ``currentSlip()`` returns without touching the queue, as after a same-room reconnect where the
    /// server hands back the draw again.
    /// - Parameter draw: The draw, or nil.
    public func setCurrentDraw(_ draw: Draw?) { withState { $0.currentDraw = draw } }

    /// Sets what ``deleteMyData()`` does to the identity.
    /// - Parameter outcome: Fresh anonymous identity (default) or retained identity.
    public func setDeletionOutcome(_ outcome: DeletionOutcome) { withState { $0.deletionOutcome = outcome } }

    /// Sets the rows ``suggestCelebrities(query:limit:)`` returns for one query, or the default pool.
    ///
    /// An override is returned as given (still truncated to the server's 1-10 bound). The default pool is filtered
    /// like the server does: the normalised query must be at least 2 characters and match the start of the name or of
    /// any word in it; rows keep their given order (the server orders by fame).
    /// - Parameters:
    ///   - rows: The rows.
    ///   - query: When given, an override for that query (case- and accent-insensitive, trimmed). Otherwise the pool.
    public func setSuggestions(_ rows: [CelebritySuggestion], forQuery query: String? = nil) {
        withState {
            if let query {
                $0.suggestionsByQuery[Self.normalise(query)] = rows
            } else {
                $0.suggestions = rows
            }
        }
    }

    /// Sets the pool ``randomCelebrities(count:excluding:)`` draws from. Each call returns the next window of the pool
    /// (so a shuffle visibly changes), skipping excluded names, with no repeats within a call.
    /// - Parameter rows: The pool.
    public func setRandomSuggestions(_ rows: [CelebritySuggestion]) {
        withState { $0.randomPool = rows; $0.randomCalls = 0 }
    }

    /// Scripts a sequence of responses for successive ``randomCelebrities(count:excluding:)`` calls, cycling when
    /// exhausted. Exclusions and the count are still applied to each response.
    /// - Parameter responses: One array per call.
    public func setRandomSequence(_ responses: [[CelebritySuggestion]]) {
        withState { $0.randomSequence = responses; $0.randomCalls = 0 }
    }

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

    /// Makes `snapshot` the current state and delivers it to observers of its room.
    ///
    /// If it is a different room from the current one, observers of the old room get `lost(.left)` and the private draw
    /// is cleared, as after a room switch.
    /// - Parameter snapshot: The new state.
    public func push(_ snapshot: RoomSnapshot) { withState { Self.commit(snapshot, in: &$0) } }

    /// Publishes a new connection state on ``connection``.
    /// - Parameter newState: The state.
    public func setConnection(_ newState: ConnectionState) {
        withState { state in
            state.connection = newState
            for subscriber in state.connectionSubscribers.values { subscriber.yield(newState) }
        }
    }

    /// Simulates losing the room, as the real backend does after a `not_member` refresh or a `room_deleted` event.
    ///
    /// Delivers `lost(reason)` to the room's observers and finishes them, clears ``currentSnapshot`` if it is that room,
    /// and clears the private draw. Does nothing if there is no such room.
    /// - Parameters:
    ///   - reason: Why the room was lost.
    ///   - roomID: The room. Defaults to the current snapshot's room.
    public func simulateRoomLoss(_ reason: RoomLossReason, roomID: UUID? = nil) {
        withState { state in
            guard let id = roomID ?? state.snapshot?.room.id else { return }
            Self.lose(roomID: id, reason: reason, in: &state)
        }
    }

    /// Finishes every open stream without a loss, as when the consumers are torn down.
    public func finishStreams() {
        withState { state in
            for observer in state.observers.values { observer.continuation.finish() }
            for subscriber in state.connectionSubscribers.values { subscriber.finish() }
            state.observers = [:]
            state.connectionSubscribers = [:]
        }
    }

    // MARK: Streams

    /// Delivers the current snapshot of `roomID` (or a terminal loss), then every committed snapshot of that room.
    ///
    /// Registration, the initial element and the commit order are one critical section, so the initial value can never
    /// overwrite a newer push. The first refresh counts as a ``CallKind/snapshot`` call. If a `.notMember` failure is armed for
    /// `.snapshot`, or the fake holds no snapshot for `roomID`, the stream yields `lost(.removed)` and finishes
    /// (the stale-persisted-room case).
    public func observeRoom(roomID: UUID) -> AsyncStream<RoomUpdate> {
        let (stream, continuation) = AsyncStream<RoomUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let key = UUID()
        continuation.onTermination = { [weak self] _ in self?.queueRemoval(.observer(key)) }
        withState { state in
            state.calls.append(.snapshot(roomID: roomID))
            var failed = false
            if let failure = state.failures[.snapshot], failure.error == .notMember {
                failed = true
                Self.consume(.snapshot, in: &state)
            }
            if !failed, let current = state.snapshot, current.room.id == roomID {
                state.observers[key] = Observer(roomID: roomID, continuation: continuation)
                continuation.yield(.snapshot(current))
            } else {
                if state.snapshot?.room.id == roomID { state.snapshot = nil; state.currentDraw = nil }
                continuation.yield(.lost(.removed))
                continuation.finish()
            }
        }
        return stream
    }

    /// Yields the current connection state, then each change made with ``setConnection(_:)``.
    public var connection: AsyncStream<ConnectionState> {
        let (stream, continuation) = AsyncStream<ConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let key = UUID()
        continuation.onTermination = { [weak self] _ in self?.queueRemoval(.connection(key)) }
        withState { state in
            state.connectionSubscribers[key] = continuation
            continuation.yield(state.connection)
        }
        return stream
    }

    // MARK: Plumbing (all `in state` helpers run inside the critical section)

    private static func normalise(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func commit(_ snapshot: RoomSnapshot, in state: inout State) {
        if let previous = state.snapshot, previous.room.id != snapshot.room.id {
            endObservers(of: previous.room.id, reason: .left, in: &state)
            state.currentDraw = nil
        }
        state.snapshot = snapshot
        for observer in state.observers.values where observer.roomID == snapshot.room.id {
            observer.continuation.yield(.snapshot(snapshot))
        }
    }

    private static func endObservers(of roomID: UUID, reason: RoomLossReason, in state: inout State) {
        for (key, observer) in state.observers where observer.roomID == roomID {
            observer.continuation.yield(.lost(reason))
            observer.continuation.finish()
            state.observers[key] = nil
        }
    }

    private static func lose(roomID: UUID, reason: RoomLossReason, in state: inout State) {
        let hadObservers = state.observers.values.contains { $0.roomID == roomID }
        let isCurrent = state.snapshot?.room.id == roomID
        guard hadObservers || isCurrent else { return }
        endObservers(of: roomID, reason: reason, in: &state)
        if isCurrent { state.snapshot = nil }
        state.currentDraw = nil
    }

    private static func isActive(_ roomID: UUID, in state: State) -> Bool {
        state.snapshot?.room.id == roomID || state.observers.values.contains { $0.roomID == roomID }
    }

    private static func consume(_ kind: CallKind, in state: inout State) {
        guard var failure = state.failures[kind] else { return }
        if let remaining = failure.remaining {
            if remaining <= 1 { state.failures[kind] = nil } else {
                failure.remaining = remaining - 1
                state.failures[kind] = failure
            }
        }
    }

    /// Pops the next scripted snapshot for `kind` and commits it.
    @discardableResult
    private static func playScript(_ kind: CallKind, in state: inout State) -> RoomSnapshot? {
        guard var queue = state.snapshotScripts[kind], !queue.isEmpty else { return nil }
        let next = queue.removeFirst()
        state.snapshotScripts[kind] = queue
        commit(next, in: &state)
        return next
    }

    private static func takeDraw(in state: inout State) -> Draw? {
        let draw = state.draws.isEmpty ? nil : state.draws.removeFirst()
        state.currentDraw = draw
        return draw
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
            guard let failure = state.failures[call.kind] else { return nil }
            Self.consume(call.kind, in: &state)
            return failure.error
        }
        if let failure { throw failure }
    }

    /// After a successful call: plays the script, and when `drawing` hands out the next draw, atomically.
    @discardableResult
    private func complete(_ kind: CallKind, drawing: Bool = false) -> Draw? {
        withState { state in
            let draw = drawing ? Self.takeDraw(in: &state) : nil
            Self.playScript(kind, in: &state)
            return draw
        }
    }

    private func snapshotResult(_ kind: CallKind, roomID: UUID? = nil) throws -> RoomSnapshot {
        let result: Result<RoomSnapshot, BackendError> = withState { state in
            if let scripted = Self.playScript(kind, in: &state) { return .success(scripted) }
            guard let current = state.snapshot else {
                if roomID != nil { return .failure(.notMember) }
                return .failure(.unknown("FakeGameBackend has no snapshot: pass one to init or script(_:snapshots:)"))
            }
            if let roomID, roomID != current.room.id { return .failure(.notMember) }
            return .success(current)
        }
        return try result.get()
    }

    /// A `.notMember` for a room the app is in or observing means the seat is gone.
    private func reportMembershipLoss(_ roomID: UUID) {
        withState { state in
            if Self.isActive(roomID, in: state) { Self.lose(roomID: roomID, reason: .removed, in: &state) }
        }
    }

    // MARK: GameBackend

    /// Returns the current user id (changed by ``deleteMyData()`` unless the identity is retained).
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

    /// Clears the room: observers get `lost(.left)`, the current snapshot and the private draw are cleared.
    public func leaveRoom() async throws {
        try await enter(.leaveRoom)
        withState { state in
            if let id = state.snapshot?.room.id { Self.lose(roomID: id, reason: .left, in: &state) }
            for (key, observer) in state.observers {
                observer.continuation.yield(.lost(.left))
                observer.continuation.finish()
                state.observers[key] = nil
            }
            state.snapshot = nil
            state.currentDraw = nil
        }
    }

    /// Simulates the foreground refresh. Records the call, plays a scripted snapshot, and treats an armed `.notMember`
    /// failure as the refetch finding the seat gone and a network failure as `.reconnecting`.
    public func didEnterForeground() async {
        do {
            try await enter(.didEnterForeground)
            complete(.didEnterForeground)
        } catch let error as BackendError {
            if error == .notMember {
                withState { state in
                    if let id = state.snapshot?.room.id { Self.lose(roomID: id, reason: .removed, in: &state) }
                }
            } else if error.isNetwork {
                setConnection(.reconnecting)
            }
        } catch {}
    }

    /// Returns the next scripted snapshot, else the current one. `.notMember` (natural or armed) for the current or
    /// observed room ends that observation with `lost(.removed)`; for any other room it only throws.
    public func snapshot(roomID: UUID) async throws -> RoomSnapshot {
        do {
            try await enter(.snapshot(roomID: roomID))
            return try snapshotResult(.snapshot, roomID: roomID)
        } catch let error as BackendError where error == .notMember {
            reportMembershipLoss(roomID)
            throw error
        }
    }

    /// Returns the current snapshot's `serverNow`, or the device time if there is none.
    public func heartbeat(roomID: UUID) async throws -> Date {
        try await enter(.heartbeat(roomID: roomID))
        complete(.heartbeat)
        return currentSnapshot?.serverNow ?? Date()
    }

    /// Records the call and plays any scripted snapshot.
    public func setTeams(_ assignments: TeamAssignments) async throws {
        try await enter(.setTeams(assignments))
        complete(.setTeams)
    }

    /// Records the call and plays any scripted snapshot.
    public func setTeamName(team: Int, name: String) async throws {
        try await enter(.setTeamName(team: team, name: name))
        complete(.setTeamName)
    }

    /// Records the call and plays any scripted snapshot.
    public func updateSettings(_ update: SettingsUpdate) async throws {
        try await enter(.updateSettings(update))
        complete(.updateSettings)
    }

    /// Records the call and plays any scripted snapshot. Applies no rules.
    public func startGame() async throws {
        try await enter(.startGame)
        complete(.startGame)
    }

    /// Records the call and plays any scripted snapshot.
    public func submitSlips(_ names: [String]) async throws {
        try await enter(.submitSlips(names))
        complete(.submitSlips)
    }

    /// Records the call and plays any scripted snapshot.
    public func retractSlips() async throws {
        try await enter(.retractSlips)
        complete(.retractSlips)
    }

    /// Records the call and plays any scripted snapshot.
    public func closeSubmissions() async throws {
        try await enter(.closeSubmissions)
        complete(.closeSubmissions)
    }

    /// Takes the next draw from ``setDraws(_:)`` and plays any scripted snapshot, atomically.
    public func startTurn() async throws -> Draw? {
        try await enter(.startTurn)
        return complete(.startTurn, drawing: true)
    }

    /// Takes the next draw from ``setDraws(_:)`` and plays any scripted snapshot, atomically. The token is recorded, not checked.
    public func gotIt(token: UUID) async throws -> Draw? {
        try await enter(.gotIt(token: token))
        return complete(.gotIt, drawing: true)
    }

    /// Takes the next draw from ``setDraws(_:)`` and plays any scripted snapshot, atomically. The token is recorded, not checked.
    public func skip(token: UUID) async throws -> Draw? {
        try await enter(.skip(token: token))
        return complete(.skip, drawing: true)
    }

    /// Returns the last draw handed out (or the `draw` given at init, or ``setCurrentDraw(_:)``).
    public func currentSlip() async throws -> Draw? {
        try await enter(.currentSlip)
        return withState { $0.currentDraw }
    }

    /// Records the call and plays any scripted snapshot.
    public func endTurn() async throws {
        try await enter(.endTurn)
        complete(.endTurn)
    }

    /// Records the call and plays any scripted snapshot.
    public func startNextRound() async throws {
        try await enter(.startNextRound)
        complete(.startNextRound)
    }

    /// Records the call and plays any scripted snapshot.
    public func resetRoom() async throws {
        try await enter(.resetRoom)
        complete(.resetRoom)
    }

    /// Records the call and plays any scripted snapshot.
    public func assignSpectator(userID: UUID, team: Int) async throws {
        try await enter(.assignSpectator(userID: userID, team: team))
        complete(.assignSpectator)
    }

    /// Records the call and plays any scripted snapshot.
    public func transferHost(to userID: UUID) async throws {
        try await enter(.transferHost(to: userID))
        complete(.transferHost)
    }

    /// Records the call and plays any scripted snapshot.
    public func kickPlayer(userID: UUID) async throws {
        try await enter(.kickPlayer(userID: userID))
        complete(.kickPlayer)
    }

    /// Records the call and plays any scripted snapshot.
    public func claimHost() async throws {
        try await enter(.claimHost)
        complete(.claimHost)
    }

    /// Clears the room (observers get `lost(.sessionEnded)`, the private draw is cleared) and, unless
    /// ``setDeletionOutcome(_:)`` retains it, rotates the user id so the next ``currentUserID()`` is a fresh anonymous identity.
    public func deleteMyData() async throws {
        try await enter(.deleteMyData)
        withState { state in
            for (key, observer) in state.observers {
                observer.continuation.yield(.lost(.sessionEnded))
                observer.continuation.finish()
                state.observers[key] = nil
            }
            state.snapshot = nil
            state.currentDraw = nil
            if state.deletionOutcome == .freshAnonymousIdentity { state.userID = UUID() }
        }
    }

    /// Returns suggestions for the query: an override from ``setSuggestions(_:forQuery:)`` if set, else the default pool
    /// filtered like the server (at least 2 normalised characters; prefix of the name or of any word). The limit is clamped to 1-10.
    public func suggestCelebrities(query: String, limit: Int) async throws -> [CelebritySuggestion] {
        let key = Self.normalise(query)
        let delay = withState { $0.suggestionDelays[key] }
        try await enter(.suggestCelebrities(query: query, limit: limit), extraDelay: delay)
        let clamped = min(max(limit, 1), 10)
        return withState { state in
            if let override = state.suggestionsByQuery[key] { return Array(override.prefix(clamped)) }
            guard key.count >= 2 else { return [] }
            let matches = state.suggestions.filter { row in
                Self.normalise(row.name).split(separator: " ").contains { $0.hasPrefix(key) }
                    || Self.normalise(row.name).hasPrefix(key)
            }
            return Array(matches.prefix(clamped))
        }
    }

    /// Returns the next window of the pool (or scripted response), minus normalised exclusions, with no repeats.
    /// The count is clamped to 1-20.
    public func randomCelebrities(count: Int, excluding names: [String]) async throws -> [CelebritySuggestion] {
        try await enter(.randomCelebrities(count: count, excluding: names))
        let clamped = min(max(count, 1), 20)
        let excluded = Set(names.map(Self.normalise))
        return withState { state in
            let call = state.randomCalls
            state.randomCalls += 1
            let source: [CelebritySuggestion]
            if !state.randomSequence.isEmpty {
                source = state.randomSequence[call % state.randomSequence.count]
            } else if state.randomPool.isEmpty {
                source = []
            } else {
                let offset = (call * clamped) % state.randomPool.count
                source = Array(state.randomPool[offset...] + state.randomPool[..<offset])
            }
            var seen = Set<String>()
            var result: [CelebritySuggestion] = []
            for row in source {
                let key = Self.normalise(row.name)
                guard !excluded.contains(key), seen.insert(key).inserted else { continue }
                result.append(row)
                if result.count == clamped { break }
            }
            return result
        }
    }
}
