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
        var roomID: UUID?
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
        var scripts: [CallKind: [ScriptedTransition]] = [:]
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
        /// Bumped by every transition that ends a room or session; operations capture it when they start.
        var generation = 0
        /// Local membership changes (leave, create, join, delete) currently in flight.
        var localChangesInFlight = 0
        /// Remote losses that arrived while a local membership change was in flight.
        var deferredLosses: [(roomID: UUID, reason: RoomLossReason)] = []
        var channelJoinRefused = false
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
        var removedObserver = false
        for removal in removals {
            switch removal {
            case .observer(let key): if state.observers.removeValue(forKey: key) != nil { removedObserver = true }
            case .connection(let key): state.connectionSubscribers[key] = nil
            }
        }
        if removedObserver, state.observers.isEmpty { Self.setConnection(.idle, in: &state) }
        return body(&state)
    }

    private func queueRemoval(_ removal: Removal) {
        removalLock.lock()
        pendingRemovals.append(removal)
        removalLock.unlock()
        // Apply it soon even if nothing else touches the fake (so the connection returns to idle).
        Task.detached { [weak self] in _ = self?.withState { _ in } }
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
    ///   - connection: The initial connection state. Defaults to ``ConnectionState/idle``: nothing is observed yet.
    ///   - draw: The draw returned by ``currentSlip()`` until the draw script runs.
    ///   - suggestions: The default pool for ``suggestCelebrities(query:limit:)``. Defaults to ``SampleSuggestions/all``.
    public init(
        userID: UUID = SampleCast.alex.id,
        snapshot: RoomSnapshot? = nil,
        connection: ConnectionState = .idle,
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

    /// The connection state right now (what a new ``connection`` stream would yield first).
    public var currentConnection: ConnectionState { withState { $0.connection } }

    // MARK: Test controls: scripting

    /// Makes calls of `kind` throw `error`.
    /// - Parameters:
    ///   - kind: The call to fail.
    ///   - error: The error to throw.
    ///   - times: How many calls fail before the call works again. Default 1.
    ///   - roomID: Limits the failure to refreshes of that room. Without it, a `.snapshot` failure applies to explicit
    ///     ``GameBackend/snapshot(roomID:)`` calls and to the first refresh of ``observeRoom(roomID:)`` only when that
    ///     room is the current one, so an unrelated probe cannot consume it.
    ///
    /// Refresh failures are classified like the contract in ``GameBackend/observeRoom(roomID:)``: `.notMember` ends the
    /// observation with `removed`, `.notAuthenticated` with `sessionEnded`, a network error keeps it open and shows
    /// `.reconnecting`, anything else ends it with `failed(error)`. This applies to the first refresh of an observation
    /// (armed on `.snapshot`) and to ``GameBackend/didEnterForeground()`` (armed on `.didEnterForeground`, which ignores
    /// the failure and consumes nothing when there is no room). A `.notMember` failure of an explicit
    /// ``GameBackend/snapshot(roomID:)`` for the current or observed room also ends that observation.
    public func fail(_ kind: CallKind, with error: BackendError, times: Int = 1, forRoom roomID: UUID? = nil) {
        withState { $0.failures[kind] = Failure(error: error, remaining: times, roomID: roomID) }
    }

    /// Makes every call of `kind` throw `error` until ``clearFailures()``.
    /// - Parameters:
    ///   - kind: The call to fail.
    ///   - error: The error to throw.
    public func failAlways(_ kind: CallKind, with error: BackendError) {
        withState { $0.failures[kind] = Failure(error: error, remaining: nil, roomID: nil) }
    }

    /// Removes every armed failure.
    public func clearFailures() { withState { $0.failures = [:] } }

    /// Makes the private channel join refuse authorisation, as it does for a kicked client or a stale room.
    ///
    /// ``observeRoom(roomID:)`` must then still probe membership (the fake records a `.snapshot` call): a probe that
    /// finds no seat ends the observation with `lost(.removed)`; a probe that finds the seat delivers the snapshot and
    /// shows `.reconnecting` while the join is retried.
    /// - Parameter refused: Whether joins are refused. Default true.
    public func refuseChannelJoin(_ refused: Bool = true) { withState { $0.channelJoinRefused = refused } }

    /// Scripts the snapshots a call produces, replayed one per successful call. Shorthand for
    /// ``script(_:transitions:)`` with the draw unchanged.
    /// - Parameters:
    ///   - kind: The call to script.
    ///   - snapshots: The snapshots, in order.
    public func script(_ kind: CallKind, snapshots: [RoomSnapshot]) {
        script(kind, transitions: snapshots.map { ScriptedTransition(snapshot: $0) })
    }

    /// Scripts what a call does to the room and the private draw, one transition per successful call.
    ///
    /// For a call that returns a snapshot (``createRoom(name:)``, ``joinRoom(code:name:)``, ``snapshot(roomID:)``) the
    /// next transition's snapshot is returned (for ``snapshot(roomID:)`` only when it describes the requested room; a
    /// mismatching script is left in place and the call throws `.notMember`). For any call except ``leaveRoom()`` and
    /// ``deleteMyData()`` (which always clear the room), a successful call commits the next transition: its draw change
    /// and its snapshot are applied in one critical section, so an observer that reads ``currentDraw`` or
    /// ``currentSlip()`` as soon as the snapshot arrives sees the new draw. For a drawing call (Start Turn, Got It, Skip)
    /// a `.set`/`.clear` draw is also its result.
    ///
    /// Scripts and the draw queue are room-bound: leave, delete, loss and room switches discard them, except those for
    /// ``CallKind/createRoom`` and ``CallKind/joinRoom``. An operation that was suspended (by ``setDelay(_:for:)``) across
    /// such a transition drops its script, snapshot and loss instead of applying them.
    /// - Parameters:
    ///   - kind: The call to script.
    ///   - transitions: The steps, in order.
    public func script(_ kind: CallKind, transitions: [ScriptedTransition]) {
        withState { $0.scripts[kind] = transitions }
    }

    /// Scripts a call to play a scenario's ``SampleScenario/followUp`` together with its ``SampleScenario/followUpDraw``.
    /// - Parameters:
    ///   - kind: The call that causes the transition (Start Turn, assign spectator, close submissions, ...).
    ///   - scenario: The scenario whose follow-up to replay.
    public func script(_ kind: CallKind, followUpOf scenario: SampleScenario) {
        guard let snapshot = scenario.followUp else { return }
        script(kind, transitions: [ScriptedTransition(snapshot: snapshot, draw: scenario.followUpDraw.map { .set($0) } ?? .unchanged)])
    }

    /// Replaces the queue of draws returned by ``startTurn()``, ``gotIt(token:)`` and ``skip(token:)``, in order.
    ///
    /// Each of those calls takes the next element (nil means "pile empty") and makes it what ``currentSlip()``
    /// returns, unless a scripted transition decides the draw. Once the queue is empty they return nil. The fake never
    /// checks tokens, so script a stale-token reply by queuing the draw the server would return.
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
    /// If it is a different room from the current one, observers of the old room get `lost(.left)`, the private draw
    /// is cleared and room-bound scripts are discarded, as after a room switch.
    /// - Parameter snapshot: The new state.
    public func push(_ snapshot: RoomSnapshot) { withState { Self.commit(snapshot, draw: .unchanged, in: &$0) } }

    /// Publishes a new connection state on ``connection``.
    /// - Parameter newState: The state.
    public func setConnection(_ newState: ConnectionState) { withState { Self.setConnection(newState, in: &$0) } }

    /// Simulates a remote loss of the room, as the real backend reports after a `not_member` refresh or a `room_deleted` event.
    ///
    /// Delivers `lost(reason)` to the room's observers and finishes them, clears ``currentSnapshot`` if it is that room,
    /// clears the private draw and returns the connection to `.idle`. Does nothing if there is no such room. While a
    /// local membership change (leave, create, join, delete) is in flight, classification is deferred until its outcome is
    /// known: if the change succeeds the observers end with the local reason instead; if it fails the loss applies then.
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

    /// Delivers the first refresh's outcome, then every committed snapshot of the room.
    ///
    /// Registration, the initial element and the commit order are one critical section. The first refresh counts as a
    /// ``CallKind/snapshot`` call and honours armed failures (see ``fail(_:with:times:forRoom:)``), a room the fake does
    /// not hold (stale persisted id, `lost(.removed)`) and ``refuseChannelJoin(_:)``. A loss found by the first refresh ends
    /// every observer of that room, not just the new one.
    public func observeRoom(roomID: UUID) -> AsyncStream<RoomUpdate> {
        let (stream, continuation) = AsyncStream<RoomUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let key = UUID()
        continuation.onTermination = { [weak self] _ in self?.queueRemoval(.observer(key)) }
        withState { state in
            state.calls.append(.snapshot(roomID: roomID))
            switch Self.refreshOutcome(for: roomID, failureKind: .snapshot, in: &state) {
            case .snapshot(let current):
                state.observers[key] = Observer(roomID: roomID, continuation: continuation)
                continuation.yield(.snapshot(current))
                Self.setConnection(state.channelJoinRefused ? .reconnecting : .connected, in: &state)
            case .retry:
                state.observers[key] = Observer(roomID: roomID, continuation: continuation)
                Self.setConnection(.reconnecting, in: &state)
            case .lost(let reason):
                Self.forceLose(roomID: roomID, reason: reason, in: &state)
                continuation.yield(.lost(reason))
                continuation.finish()
            }
        }
        return stream
    }

    /// Yields the current connection state, then each change, keeping only the newest.
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

    private static func setConnection(_ newState: ConnectionState, in state: inout State) {
        guard state.connection != newState else { return }
        state.connection = newState
        for subscriber in state.connectionSubscribers.values { subscriber.yield(newState) }
    }

    /// Ends every room-bound thing: invalidates in-flight operations, the draw queue and in-room scripts.
    private static func invalidate(_ state: inout State) {
        state.generation += 1
        state.draws = []
        state.currentDraw = nil
        state.scripts = state.scripts.filter { $0.key == .createRoom || $0.key == .joinRoom }
    }

    private static func apply(_ update: DrawUpdate, in state: inout State) {
        switch update {
        case .unchanged: break
        case .clear: state.currentDraw = nil
        case .set(let draw): state.currentDraw = draw
        }
    }

    private static func commit(_ snapshot: RoomSnapshot, draw: DrawUpdate, in state: inout State) {
        if let previous = state.snapshot, previous.room.id != snapshot.room.id {
            endObservers(of: previous.room.id, reason: .left, in: &state)
            invalidate(&state)
        }
        apply(draw, in: &state)
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
        if state.observers.isEmpty { setConnection(.idle, in: &state) }
    }

    /// Applies a loss now (or defers it while a local membership change is in flight).
    private static func lose(roomID: UUID, reason: RoomLossReason, in state: inout State) {
        guard isActive(roomID, in: state) else { return }
        if state.localChangesInFlight > 0 {
            state.deferredLosses.append((roomID, reason))
            return
        }
        forceLose(roomID: roomID, reason: reason, in: &state)
    }

    private static func forceLose(roomID: UUID, reason: RoomLossReason, in state: inout State) {
        guard isActive(roomID, in: state) else { return }
        endObservers(of: roomID, reason: reason, in: &state)
        if state.snapshot?.room.id == roomID { state.snapshot = nil }
        invalidate(&state)
    }

    private static func isActive(_ roomID: UUID, in state: State) -> Bool {
        state.snapshot?.room.id == roomID || state.observers.values.contains { $0.roomID == roomID }
    }

    /// Ends a local membership change: the local effect has been applied (or not), so deferred remote losses now either
    /// found their room already gone (discarded) or still apply.
    private static func finishLocalChange(in state: inout State) {
        state.localChangesInFlight -= 1
        guard state.localChangesInFlight == 0 else { return }
        let pending = state.deferredLosses
        state.deferredLosses = []
        for loss in pending { forceLose(roomID: loss.roomID, reason: loss.reason, in: &state) }
    }

    /// The local effect of leave and delete: end observers with `reason`, clear the room and the private state.
    private static func endRoomLocally(reason: RoomLossReason, in state: inout State) {
        for (key, observer) in state.observers {
            observer.continuation.yield(.lost(reason))
            observer.continuation.finish()
            state.observers[key] = nil
        }
        state.snapshot = nil
        invalidate(&state)
        setConnection(.idle, in: &state)
    }

    private enum Refresh {
        case snapshot(RoomSnapshot)
        case retry
        case lost(RoomLossReason)
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

    /// An armed failure of `kind` that applies to refreshes of `roomID`.
    private static func applicableFailure(_ kind: CallKind, for roomID: UUID, in state: State) -> BackendError? {
        guard let failure = state.failures[kind] else { return nil }
        if let scoped = failure.roomID { return scoped == roomID ? failure.error : nil }
        return state.snapshot?.room.id == roomID ? failure.error : nil
    }

    private static func classify(_ error: BackendError) -> Refresh {
        switch error {
        case .notMember: .lost(.removed)
        case .notAuthenticated: .lost(.sessionEnded)
        case .network, .cancelled: .retry
        default: .lost(.failed(error))
        }
    }

    /// The outcome of the refresh an observation (or a foreground) performs for `roomID`.
    private static func refreshOutcome(for roomID: UUID, failureKind: CallKind, in state: inout State) -> Refresh {
        if let error = applicableFailure(failureKind, for: roomID, in: state) {
            consume(failureKind, in: &state)
            return classify(error)
        }
        if let current = state.snapshot, current.room.id == roomID { return .snapshot(current) }
        return .lost(.removed)
    }

    /// Takes the next transition for `kind`, if any.
    private static func nextTransition(_ kind: CallKind, in state: inout State) -> ScriptedTransition? {
        guard var queue = state.scripts[kind], !queue.isEmpty else { return nil }
        let next = queue.removeFirst()
        state.scripts[kind] = queue
        return next
    }

    private static func takeDraw(in state: inout State) -> Draw? {
        let draw = state.draws.isEmpty ? nil : state.draws.removeFirst()
        state.currentDraw = draw
        return draw
    }

    /// Records the call and captures the generation and delay. Cheap and non-suspending.
    private func begin(_ call: Call, extraDelay: Duration? = nil) -> (generation: Int, delay: Duration?) {
        withState { state in
            state.calls.append(call)
            if Self.changesMembership(call.kind) { state.localChangesInFlight += 1 }
            return (state.generation, extraDelay ?? state.delays[call.kind])
        }
    }

    private static func changesMembership(_ kind: CallKind) -> Bool {
        kind == .leaveRoom || kind == .createRoom || kind == .joinRoom || kind == .deleteMyData
    }

    /// Records the call, waits out any delay, then throws an armed failure. Returns the generation the call started in.
    /// A throwing local membership change ends its in-flight window here.
    private func enter(_ call: Call, extraDelay: Duration? = nil) async throws -> Int {
        let (generation, delay) = begin(call, extraDelay: extraDelay)
        do {
            if let delay { try await Task.sleep(for: delay) }
            try Task.checkCancellation()
            let failure: BackendError? = withState { state in
                guard let failure = state.failures[call.kind] else { return nil }
                if call.kind == .snapshot, case .snapshot(let id) = call, let scoped = failure.roomID, scoped != id { return nil }
                Self.consume(call.kind, in: &state)
                return failure.error
            }
            if let failure { throw failure }
        } catch {
            if Self.changesMembership(call.kind) { withState { Self.finishLocalChange(in: &$0) } }
            throw error
        }
        return generation
    }

    /// After a successful call: commits the next scripted transition (draw and snapshot atomically) and, for a drawing
    /// call, hands out the draw. An operation that started in an older generation applies nothing.
    @discardableResult
    private func complete(_ kind: CallKind, generation: Int, drawing: Bool = false) -> Draw? {
        withState { state in
            guard generation == state.generation else { return nil }
            let transition = Self.nextTransition(kind, in: &state)
            var result: Draw?
            if drawing {
                switch transition?.draw ?? .unchanged {
                case .set(let draw): result = draw
                case .clear: result = nil
                case .unchanged: result = Self.takeDraw(in: &state)
                }
            }
            if let transition {
                Self.commit(transition.snapshot, draw: transition.draw, in: &state)
            } else if drawing {
                state.currentDraw = result
            }
            return result
        }
    }

    /// Resolves a snapshot-returning call.
    private func snapshotResult(_ kind: CallKind, generation: Int, roomID: UUID? = nil) throws -> RoomSnapshot {
        let result: Result<RoomSnapshot, BackendError> = withState { state in
            let fresh = generation == state.generation
            if fresh, let head = state.scripts[kind]?.first, roomID == nil || head.snapshot.room.id == roomID {
                let transition = Self.nextTransition(kind, in: &state)!
                Self.commit(transition.snapshot, draw: transition.draw, in: &state)
                return .success(transition.snapshot)
            }
            guard let current = state.snapshot else {
                if roomID != nil { return .failure(.notMember) }
                return .failure(.unknown("FakeGameBackend has no snapshot: pass one to init or script(_:snapshots:)"))
            }
            if let roomID, roomID != current.room.id { return .failure(.notMember) }
            return .success(current)
        }
        return try result.get()
    }

    /// A `.notMember` for a room the app is in or observing means the seat is gone, unless the probe is from an old generation.
    private func reportMembershipLoss(_ roomID: UUID, generation: Int) {
        withState { state in
            guard generation == state.generation else { return }
            Self.lose(roomID: roomID, reason: .removed, in: &state)
        }
    }

    // MARK: GameBackend

    /// Returns the current user id (changed by ``deleteMyData()`` unless the identity is retained).
    public func currentUserID() async throws -> UUID {
        _ = try await enter(.currentUserID)
        return withState { $0.userID }
    }

    /// Returns the next scripted snapshot, else the current one.
    public func createRoom(name: String) async throws -> RoomSnapshot {
        let generation = try await enter(.createRoom(name: name))
        return try finishingLocalChange { try snapshotResult(.createRoom, generation: generation) }
    }

    /// Returns the next scripted snapshot, else the current one.
    public func joinRoom(code: String, name: String) async throws -> RoomSnapshot {
        let generation = try await enter(.joinRoom(code: code, name: name))
        return try finishingLocalChange { try snapshotResult(.joinRoom, generation: generation) }
    }

    /// Runs the local effect of a create/join, then ends its in-flight window (also when the effect throws).
    private func finishingLocalChange<T>(_ effect: () throws -> T) throws -> T {
        defer { withState { Self.finishLocalChange(in: &$0) } }
        return try effect()
    }

    /// Clears the room: observers get `lost(.left)`, the snapshot, private draw and room-bound scripts are cleared and
    /// the connection returns to `.idle`.
    public func leaveRoom() async throws {
        _ = try await enter(.leaveRoom)
        withState { state in
            Self.endRoomLocally(reason: .left, in: &state)
            Self.finishLocalChange(in: &state)
        }
    }

    /// Simulates the foreground refresh. Records the call. With no room it does nothing and consumes nothing. With a
    /// room it classifies an armed `.didEnterForeground` failure like a first refresh (`notMember` → `removed`,
    /// `notAuthenticated` → `sessionEnded`, network → `.reconnecting`, other → `failed`); otherwise it commits a scripted
    /// transition or republishes the current snapshot, and a recovering connection returns to `.connected`.
    /// A refresh suspended across a leave, delete, loss or room switch applies nothing.
    public func didEnterForeground() async {
        let (generation, delay) = begin(.didEnterForeground)
        if let delay { try? await Task.sleep(for: delay) }
        if Task.isCancelled { return }
        withState { state in
            guard generation == state.generation, let current = state.snapshot else { return }
            let roomID = current.room.id
            switch Self.refreshOutcome(for: roomID, failureKind: .didEnterForeground, in: &state) {
            case .lost(let reason):
                Self.lose(roomID: roomID, reason: reason, in: &state)
            case .retry:
                Self.setConnection(.reconnecting, in: &state)
            case .snapshot:
                if let transition = Self.nextTransition(.didEnterForeground, in: &state) {
                    Self.commit(transition.snapshot, draw: transition.draw, in: &state)
                } else {
                    for observer in state.observers.values where observer.roomID == roomID {
                        observer.continuation.yield(.snapshot(current))
                    }
                }
                if !state.observers.isEmpty, state.connection != .connected, !state.channelJoinRefused {
                    Self.setConnection(.connected, in: &state)
                }
            }
        }
    }

    /// Returns the next scripted snapshot (only if it describes `roomID`), else the current one; `.notMember` if the id
    /// is not the current room's. `.notMember` (natural or armed) for the current or observed room ends that observation
    /// with `lost(.removed)`; for any other room, or from an older generation, it only throws.
    public func snapshot(roomID: UUID) async throws -> RoomSnapshot {
        var generation = withState { $0.generation }
        do {
            generation = try await enter(.snapshot(roomID: roomID))
            return try snapshotResult(.snapshot, generation: generation, roomID: roomID)
        } catch let error as BackendError where error == .notMember {
            reportMembershipLoss(roomID, generation: generation)
            throw error
        }
    }

    /// Returns the current snapshot's `serverNow`, or the device time if there is none.
    public func heartbeat(roomID: UUID) async throws -> Date {
        let generation = try await enter(.heartbeat(roomID: roomID))
        complete(.heartbeat, generation: generation)
        return currentSnapshot?.serverNow ?? Date()
    }

    /// Records the call and plays any scripted transition.
    public func setTeams(_ assignments: TeamAssignments) async throws {
        let generation = try await enter(.setTeams(assignments))
        complete(.setTeams, generation: generation)
    }

    /// Records the call and plays any scripted transition.
    public func setTeamName(team: Int, name: String) async throws {
        let generation = try await enter(.setTeamName(team: team, name: name))
        complete(.setTeamName, generation: generation)
    }

    /// Records the call and plays any scripted transition.
    public func updateSettings(_ update: SettingsUpdate) async throws {
        let generation = try await enter(.updateSettings(update))
        complete(.updateSettings, generation: generation)
    }

    /// Records the call and plays any scripted transition. Applies no rules.
    public func startGame() async throws {
        let generation = try await enter(.startGame)
        complete(.startGame, generation: generation)
    }

    /// Records the call and plays any scripted transition.
    public func submitSlips(_ names: [String]) async throws {
        let generation = try await enter(.submitSlips(names))
        complete(.submitSlips, generation: generation)
    }

    /// Records the call and plays any scripted transition.
    public func retractSlips() async throws {
        let generation = try await enter(.retractSlips)
        complete(.retractSlips, generation: generation)
    }

    /// Records the call and plays any scripted transition.
    public func closeSubmissions() async throws {
        let generation = try await enter(.closeSubmissions)
        complete(.closeSubmissions, generation: generation)
    }

    /// Commits the next scripted transition and hands out its draw (or the next queued draw), atomically.
    public func startTurn() async throws -> Draw? {
        let generation = try await enter(.startTurn)
        return complete(.startTurn, generation: generation, drawing: true)
    }

    /// As ``startTurn()``. The token is recorded, not checked.
    public func gotIt(token: UUID) async throws -> Draw? {
        let generation = try await enter(.gotIt(token: token))
        return complete(.gotIt, generation: generation, drawing: true)
    }

    /// As ``startTurn()``. The token is recorded, not checked.
    public func skip(token: UUID) async throws -> Draw? {
        let generation = try await enter(.skip(token: token))
        return complete(.skip, generation: generation, drawing: true)
    }

    /// Returns the last draw handed out (or the `draw` given at init, or set by a transition or ``setCurrentDraw(_:)``).
    public func currentSlip() async throws -> Draw? {
        _ = try await enter(.currentSlip)
        return withState { $0.currentDraw }
    }

    /// Records the call and plays any scripted transition (which may clear the draw).
    public func endTurn() async throws {
        let generation = try await enter(.endTurn)
        complete(.endTurn, generation: generation)
    }

    /// Records the call and plays any scripted transition.
    public func startNextRound() async throws {
        let generation = try await enter(.startNextRound)
        complete(.startNextRound, generation: generation)
    }

    /// Records the call and plays any scripted transition.
    public func resetRoom() async throws {
        let generation = try await enter(.resetRoom)
        complete(.resetRoom, generation: generation)
    }

    /// Records the call and plays any scripted transition.
    public func assignSpectator(userID: UUID, team: Int) async throws {
        let generation = try await enter(.assignSpectator(userID: userID, team: team))
        complete(.assignSpectator, generation: generation)
    }

    /// Records the call and plays any scripted transition.
    public func transferHost(to userID: UUID) async throws {
        let generation = try await enter(.transferHost(to: userID))
        complete(.transferHost, generation: generation)
    }

    /// Records the call and plays any scripted transition.
    public func kickPlayer(userID: UUID) async throws {
        let generation = try await enter(.kickPlayer(userID: userID))
        complete(.kickPlayer, generation: generation)
    }

    /// Records the call and plays any scripted transition.
    public func claimHost() async throws {
        let generation = try await enter(.claimHost)
        complete(.claimHost, generation: generation)
    }

    /// Clears the room (observers get `lost(.sessionEnded)`, the private draw is cleared, the connection goes `.idle`) and,
    /// unless ``setDeletionOutcome(_:)`` retains it, rotates the user id so the next ``currentUserID()`` is a fresh anonymous identity.
    public func deleteMyData() async throws {
        _ = try await enter(.deleteMyData)
        withState { state in
            Self.endRoomLocally(reason: .sessionEnded, in: &state)
            if state.deletionOutcome == .freshAnonymousIdentity { state.userID = UUID() }
            Self.finishLocalChange(in: &state)
        }
    }

    /// Returns suggestions for the query: an override from ``setSuggestions(_:forQuery:)`` if set, else the default pool
    /// filtered like the server (at least 2 normalised characters; prefix of the name or of any word). The limit is clamped to 1-10.
    public func suggestCelebrities(query: String, limit: Int) async throws -> [CelebritySuggestion] {
        let key = Self.normalise(query)
        let delay = withState { $0.suggestionDelays[key] }
        _ = try await enter(.suggestCelebrities(query: query, limit: limit), extraDelay: delay)
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
        _ = try await enter(.randomCelebrities(count: count, excluding: names))
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
