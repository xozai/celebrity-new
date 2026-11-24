import CelebrityCore
import Foundation
import Observation
import Testing
@testable import CelebrityBackend

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
private func lobby() -> SampleScenario { SampleScenario.make(.lobbyHost, now: now) }
private func lobbySnapshot() -> RoomSnapshot { lobby().snapshot }
private func submittingSnapshot() -> RoomSnapshot { SampleScenario.make(.submittingEditing, now: now).snapshot }

/// A snapshot distinguishable by `round` only.
private func tagged(_ base: RoomSnapshot, _ n: Int) -> RoomSnapshot {
    var copy = base
    copy.room.round = n
    return copy
}

/// Compile-time proof that a main-actor observable view model can drive any GameBackend under strict concurrency.
/// Subscriptions are installed synchronously (before the Task starts), so tests need no sleeps.
@MainActor @Observable
private final class ProbeViewModel {
    let backend: any GameBackend
    var snapshot: RoomSnapshot?
    var errorMessage: String?
    var draw: Draw?
    var lost: RoomLossReason?
    var state: ConnectionState = .disconnected
    var seen: [Int] = []

    init(backend: any GameBackend) { self.backend = backend }

    func create() async {
        do { snapshot = try await backend.createRoom(name: "Alex") } catch { errorMessage = BackendError.from(error).userMessage }
    }

    func observe(_ roomID: UUID) -> Task<Void, Never> {
        let stream = backend.observeRoom(roomID: roomID)
        return Task { @MainActor in
            for await update in stream {
                switch update {
                case .snapshot(let s): snapshot = s; seen.append(s.room.round)
                case .lost(let reason): lost = reason
                }
            }
        }
    }

    func watchConnection() -> Task<Void, Never> {
        let stream = backend.connection
        return Task { @MainActor in
            for await s in stream { state = s; if s == .reconnecting { break } }
        }
    }

    func start() async { draw = try? await backend.startTurn() }
}

@Suite struct FakeGameBackendTests {
    // MARK: Recording

    @Test func recordsCallsInOrderWithArguments() async throws {
        let s = lobby()
        let fake = FakeGameBackend(scenario: s)
        let token = UUID()
        let other = UUID()
        let assignments: TeamAssignments = [other: .team(1), s.userID: .unassigned]
        _ = try await fake.currentUserID()
        _ = try await fake.createRoom(name: "Alex")
        _ = try await fake.joinRoom(code: "K7Q2", name: "Blair")
        try await fake.setTeams(assignments)
        try await fake.setTeamName(team: 0, name: "Red")
        try await fake.updateSettings(SettingsUpdate(turnSeconds: 30))
        try await fake.startGame()
        try await fake.submitSlips(["A", "A", "B"])
        try await fake.retractSlips()
        try await fake.closeSubmissions()
        _ = try await fake.gotIt(token: token)
        _ = try await fake.skip(token: token)
        try await fake.assignSpectator(userID: other, team: 0)
        try await fake.transferHost(to: other)
        try await fake.kickPlayer(userID: other)
        _ = try await fake.suggestCelebrities(query: "tom")
        _ = try await fake.randomCelebrities(count: 5, excluding: ["Tom Hanks"])
        await fake.didEnterForeground()
        let calls = fake.calls
        #expect(calls.count == 18)
        #expect(calls[3] == .setTeams(assignments))
        #expect(calls[5] == .updateSettings(SettingsUpdate(turnSeconds: 30)))
        #expect(calls[7] == .submitSlips(["A", "A", "B"]))
        #expect(calls[10] == .gotIt(token: token))
        #expect(calls[15] == .suggestCelebrities(query: "tom", limit: 6))
        #expect(calls[16] == .randomCelebrities(count: 5, excluding: ["Tom Hanks"]))
        #expect(calls[17] == .didEnterForeground)
        #expect(calls.map(\.kind).prefix(3) == [.currentUserID, .createRoom, .joinRoom])
        #expect(fake.calls(of: .gotIt) == [.gotIt(token: token)])
        fake.resetCalls()
        #expect(fake.calls.isEmpty)
    }

    @Test func recordsFailedCallsToo() async {
        let fake = FakeGameBackend(scenario: lobby())
        fake.fail(.startGame, with: .notEnoughPlayers)
        _ = try? await fake.startGame()
        #expect(fake.calls == [.startGame])
    }

    // MARK: Failures

    @Test func failsTheNextCallThenRecovers() async throws {
        let fake = FakeGameBackend(scenario: lobby())
        fake.fail(.startGame, with: .notEnoughPlayers)
        await #expect(throws: BackendError.notEnoughPlayers) { try await fake.startGame() }
        try await fake.startGame()
    }

    @Test func failsTimesThenRecovers() async throws {
        let fake = FakeGameBackend(scenario: lobby())
        fake.fail(.heartbeat, with: .network("offline"), times: 2)
        let id = lobbySnapshot().room.id
        await #expect(throws: BackendError.network("offline")) { try await fake.heartbeat(roomID: id) }
        await #expect(throws: BackendError.network("offline")) { try await fake.heartbeat(roomID: id) }
        _ = try await fake.heartbeat(roomID: id)
    }

    @Test func failAlwaysUntilCleared() async throws {
        let fake = FakeGameBackend(scenario: lobby())
        fake.failAlways(.kickPlayer, with: .notHost)
        for _ in 0..<3 { await #expect(throws: BackendError.notHost) { try await fake.kickPlayer(userID: UUID()) } }
        try await fake.startGame()
        fake.clearFailures()
        try await fake.kickPlayer(userID: UUID())
    }

    // MARK: Snapshot-returning calls

    @Test func snapshotReturningCallsReplayTheCurrentSnapshot() async throws {
        let s = lobby()
        let fake = FakeGameBackend(scenario: s)
        #expect(try await fake.createRoom(name: "x") == s.snapshot)
        #expect(try await fake.joinRoom(code: "K7Q2", name: "x") == s.snapshot)
        #expect(try await fake.snapshot(roomID: s.snapshot.room.id) == s.snapshot)
    }

    @Test func noSnapshotMeansNotMemberAndFailedCreate() async {
        let fake = FakeGameBackend()
        await #expect(throws: BackendError.notMember) { try await fake.snapshot(roomID: UUID()) }
        await #expect(throws: BackendError.self) { try await fake.createRoom(name: "x") }
    }

    @Test func scriptedSnapshotsAreReturnedInOrderByThatCall() async throws {
        let a = lobbySnapshot(), b = submittingSnapshot()
        let fake = FakeGameBackend()
        fake.script(.joinRoom, snapshots: [a, b])
        #expect(try await fake.joinRoom(code: "K7Q2", name: "x") == a)
        #expect(try await fake.joinRoom(code: "K7Q2", name: "x") == b)
        #expect(try await fake.joinRoom(code: "K7Q2", name: "x") == b)
        #expect(fake.currentSnapshot == b)
    }

    @Test func voidCallPublishesItsScriptedSnapshotOnSuccessOnly() async throws {
        let a = lobbySnapshot(), b = submittingSnapshot()
        let fake = FakeGameBackend(snapshot: a)
        fake.script(.startGame, snapshots: [b])
        fake.fail(.startGame, with: .notEnoughPlayers)
        _ = try? await fake.startGame()
        #expect(fake.currentSnapshot == a)
        try await fake.startGame()
        #expect(fake.currentSnapshot == b)
    }

    @Test func voidCallsDoNotReimplementRules() async throws {
        let fake = FakeGameBackend(scenario: SampleScenario.make(.lobbyUnevenHost, now: now))
        try await fake.startGame()
        #expect(fake.currentSnapshot?.room.phase == .lobby)
    }

    // MARK: observeRoom: delivery

    @Test func observeYieldsCurrentThenPushes() async {
        let a = lobbySnapshot(), b = submittingSnapshot()
        let fake = FakeGameBackend(snapshot: a)
        var iterator = fake.observeRoom(roomID: a.room.id).makeAsyncIterator()
        #expect(await iterator.next() == .snapshot(a))
        fake.push(b)
        #expect(await iterator.next() == .snapshot(b))
        #expect(fake.currentSnapshot == b)
    }

    @Test func observersOfOtherRoomsAreLeftAlone() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        var one = fake.observeRoom(roomID: a.room.id).makeAsyncIterator()
        var two = fake.observeRoom(roomID: a.room.id).makeAsyncIterator()
        #expect(await one.next() == .snapshot(a))
        #expect(await two.next() == .snapshot(a))
        let b = tagged(a, 2)
        fake.push(b)
        #expect(await one.next() == .snapshot(b))
        #expect(await two.next() == .snapshot(b))
        #expect(fake.observerCount == 2)
    }

    @Test func slowConsumerSeesOnlyTheLatestSnapshot() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        var iterator = fake.observeRoom(roomID: a.room.id).makeAsyncIterator()
        for n in 1...50 { fake.push(tagged(a, n % 4)) }
        fake.push(tagged(a, 3))
        #expect(await iterator.next() == .snapshot(tagged(a, 3)))
    }

    @Test func pendingLossSurvivesCoalescing() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        var iterator = fake.observeRoom(roomID: a.room.id).makeAsyncIterator()
        for n in 1...20 { fake.push(tagged(a, n % 4)) }
        fake.simulateRoomLoss(.removed)
        #expect(await iterator.next() == .lost(.removed))
        #expect(await iterator.next() == nil)
    }

    // MARK: observeRoom: ordering under concurrency

    @Test func initialReplayNeverOverwritesANewerPush() async {
        let a = lobbySnapshot(), b = tagged(a, 3)
        for _ in 0..<300 {
            let fake = FakeGameBackend(snapshot: a)
            async let stream: AsyncStream<RoomUpdate> = { fake.observeRoom(roomID: a.room.id) }()
            async let pushed: Void = { fake.push(b) }()
            let (observed, _) = await (stream, pushed)
            fake.finishStreams()
            var rounds: [Int] = []
            for await update in observed { if case .snapshot(let s) = update { rounds.append(s.room.round) } }
            // Latest-value buffering: the newest commit is what is left, whichever order the two ran in.
            #expect(rounds == [3], "saw \(rounds)")
        }
    }

    @Test func overlappingPublicationsArriveInCommitOrder() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        let stream = fake.observeRoom(roomID: a.room.id)
        await withTaskGroup(of: Void.self) { group in
            for n in 1...200 { group.addTask { fake.push(tagged(a, n % 3 + 1)) } }
        }
        var iterator = stream.makeAsyncIterator()
        // Whatever the interleaving, the last delivered value is the last committed one.
        let committed = fake.currentSnapshot
        #expect(await iterator.next() == committed.map { .snapshot($0) })
    }

    @Test func scriptedSnapshotAndDrawAreCommittedTogether() async throws {
        let a = SampleScenario.make(.playingClueGiver, now: now)
        let ready = SampleScenario.make(.playingClueGiverReady, now: now)
        let draw = Draw(id: UUID(), name: "Beyoncé", token: UUID())
        let fake = FakeGameBackend(scenario: ready)
        fake.script(.startTurn, snapshots: [a.snapshot])
        fake.setDraws([draw])
        var iterator = fake.observeRoom(roomID: a.snapshot.room.id).makeAsyncIterator()
        #expect(await iterator.next() == .snapshot(ready.snapshot))
        _ = try await fake.startTurn()
        // As soon as the new snapshot is visible, so is the draw it belongs to.
        #expect(await iterator.next() == .snapshot(a.snapshot))
        #expect(fake.currentDraw == draw)
        #expect(try await fake.currentSlip() == draw)
    }

    // MARK: observeRoom: loss

    @Test func lossIsDeliveredThenTheStreamFinishes() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        var iterator = fake.observeRoom(roomID: a.room.id).makeAsyncIterator()
        _ = await iterator.next()
        fake.simulateRoomLoss(.roomDeleted)
        #expect(await iterator.next() == .lost(.roomDeleted))
        #expect(await iterator.next() == nil)
        #expect(fake.currentSnapshot == nil)
        #expect(fake.observerCount == 0)
    }

    @Test func initialRefreshLosesWhenNoSnapshotMatches() async {
        let fake = FakeGameBackend()
        var iterator = fake.observeRoom(roomID: UUID()).makeAsyncIterator()
        #expect(await iterator.next() == .lost(.removed))
        #expect(await iterator.next() == nil)
        #expect(fake.calls.map(\.kind) == [.snapshot])
    }

    @Test func armedNotMemberIsConsumedByTheInitialRefresh() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        fake.fail(.snapshot, with: .notMember)
        // The loss is waiting in the stream before the consumer ever iterates.
        let stream = fake.observeRoom(roomID: a.room.id)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .lost(.removed))
        // A later observation is a fresh attempt and succeeds.
        fake.push(a)
        var again = fake.observeRoom(roomID: a.room.id).makeAsyncIterator()
        #expect(await again.next() == .snapshot(a))
    }

    @Test func notMemberFromSnapshotEndsTheActiveObservation() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        var iterator = fake.observeRoom(roomID: a.room.id).makeAsyncIterator()
        _ = await iterator.next()
        fake.fail(.snapshot, with: .notMember)
        await #expect(throws: BackendError.notMember) { try await fake.snapshot(roomID: a.room.id) }
        #expect(await iterator.next() == .lost(.removed))
        #expect(await iterator.next() == nil)
    }

    @Test func naturalNotMemberForTheActiveRoomAlsoEndsIt() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        var iterator = fake.observeRoom(roomID: a.room.id).makeAsyncIterator()
        _ = await iterator.next()
        fake.simulateRoomLoss(.removed)
        _ = await iterator.next()
        await #expect(throws: BackendError.notMember) { try await fake.snapshot(roomID: a.room.id) }
    }

    @Test func probingAnUnrelatedRoomLeavesTheObservationAlone() async throws {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        var iterator = fake.observeRoom(roomID: a.room.id).makeAsyncIterator()
        _ = await iterator.next()
        fake.fail(.snapshot, with: .notMember)
        await #expect(throws: BackendError.notMember) { try await fake.snapshot(roomID: UUID()) }
        await #expect(throws: BackendError.notMember) { try await fake.snapshot(roomID: UUID()) }
        #expect(fake.observerCount == 1)
        #expect(fake.currentSnapshot == a)
        let b = tagged(a, 2)
        fake.push(b)
        #expect(await iterator.next() == .snapshot(b))
    }

    @Test func leaveEndsObserversWithLeftAndClearsRoomState() async throws {
        let s = SampleScenario.make(.playingClueGiver, now: now)
        let fake = FakeGameBackend(scenario: s)
        var iterator = fake.observeRoom(roomID: s.snapshot.room.id).makeAsyncIterator()
        _ = await iterator.next()
        #expect(fake.currentDraw != nil)
        try await fake.leaveRoom()
        #expect(await iterator.next() == .lost(.left))
        #expect(await iterator.next() == nil)
        #expect(fake.currentSnapshot == nil)
        #expect(try await fake.currentSlip() == nil)
    }

    @Test func leaveCannotBeScriptedBackIntoARoom() async throws {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        fake.script(.leaveRoom, snapshots: [tagged(a, 2)])
        try await fake.leaveRoom()
        #expect(fake.currentSnapshot == nil)
    }

    @Test func roomSwitchEndsOldObserversAndDropsTheDraw() async throws {
        let a = SampleScenario.make(.playingClueGiver, now: now)
        var other = lobbySnapshot()
        other.room.id = UUID()
        let fake = FakeGameBackend(scenario: a)
        var iterator = fake.observeRoom(roomID: a.snapshot.room.id).makeAsyncIterator()
        _ = await iterator.next()
        fake.script(.joinRoom, snapshots: [other])
        _ = try await fake.joinRoom(code: "ZZZZ", name: "x")
        #expect(await iterator.next() == .lost(.left))
        #expect(fake.currentDraw == nil)
        #expect(fake.currentSnapshot == other)
    }

    @Test func deleteMyDataRotatesIdentityAndEndsObservation() async throws {
        let s = lobby()
        let fake = FakeGameBackend(scenario: s)
        var iterator = fake.observeRoom(roomID: s.snapshot.room.id).makeAsyncIterator()
        _ = await iterator.next()
        try await fake.deleteMyData()
        #expect(await iterator.next() == .lost(.sessionEnded))
        #expect(fake.currentSnapshot == nil)
        let fresh = try await fake.currentUserID()
        #expect(fresh != s.userID)
        #expect(try await fake.currentUserID() == fresh)
    }

    @Test func deleteMyDataCanRetainIdentity() async throws {
        let s = lobby()
        let fake = FakeGameBackend(scenario: s)
        fake.setDeletionOutcome(.retainedIdentity)
        try await fake.deleteMyData()
        #expect(try await fake.currentUserID() == s.userID)
        #expect(fake.currentSnapshot == nil)
    }

    @Test func lossClearsThePrivateDrawButSameRoomReplacementIsSeparate() async throws {
        let s = SampleScenario.make(.playingClueGiver, now: now)
        let fake = FakeGameBackend(scenario: s)
        let replacement = Draw(id: UUID(), name: "New", token: UUID())
        fake.setCurrentDraw(replacement)
        #expect(try await fake.currentSlip() == replacement)
        fake.simulateRoomLoss(.removed)
        #expect(try await fake.currentSlip() == nil)
    }

    // MARK: Foreground

    @Test func foregroundIsRecordedAndScriptable() async {
        let a = lobbySnapshot(), b = tagged(a, 2)
        let fake = FakeGameBackend(snapshot: a)
        var iterator = fake.observeRoom(roomID: a.room.id).makeAsyncIterator()
        _ = await iterator.next()
        fake.script(.didEnterForeground, snapshots: [b])
        await fake.didEnterForeground()
        #expect(fake.calls(of: .didEnterForeground) == [.didEnterForeground])
        #expect(await iterator.next() == .snapshot(b))
    }

    @Test func foregroundRefetchFindingTheSeatGoneEndsTheObservation() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        var iterator = fake.observeRoom(roomID: a.room.id).makeAsyncIterator()
        _ = await iterator.next()
        fake.fail(.didEnterForeground, with: .notMember)
        await fake.didEnterForeground()
        #expect(await iterator.next() == .lost(.removed))
    }

    @Test func foregroundNetworkFailureShowsReconnecting() async {
        let fake = FakeGameBackend(snapshot: lobbySnapshot())
        fake.fail(.didEnterForeground, with: .network("offline"))
        var states = fake.connection.makeAsyncIterator()
        #expect(await states.next() == .connected)
        await fake.didEnterForeground()
        #expect(await states.next() == .reconnecting)
    }

    @Test func foregroundWithNoRoomIsHarmless() async {
        let fake = FakeGameBackend()
        await fake.didEnterForeground()
        #expect(fake.calls == [.didEnterForeground])
    }

    // MARK: Connection

    @Test func connectionYieldsCurrentThenChanges() async {
        let fake = FakeGameBackend(connection: .connecting)
        var iterator = fake.connection.makeAsyncIterator()
        #expect(await iterator.next() == .connecting)
        fake.setConnection(.connected)
        #expect(await iterator.next() == .connected)
        fake.setConnection(.reconnecting)
        #expect(await iterator.next() == .reconnecting)
    }

    @Test func connectionKeepsOnlyTheNewestState() async {
        let fake = FakeGameBackend(connection: .connecting)
        var iterator = fake.connection.makeAsyncIterator()
        fake.setConnection(.connected)
        fake.setConnection(.reconnecting)
        fake.setConnection(.disconnected)
        #expect(await iterator.next() == .disconnected)
    }

    @Test func initialConnectionValueNeverOverwritesANewerState() async {
        for _ in 0..<300 {
            let fake = FakeGameBackend(connection: .connecting)
            async let stream: AsyncStream<ConnectionState> = { fake.connection }()
            async let set: Void = { fake.setConnection(.connected) }()
            let (observed, _) = await (stream, set)
            fake.finishStreams()
            var seen: [ConnectionState] = []
            for await state in observed { seen.append(state) }
            #expect(seen == [.connected], "saw \(seen)")
        }
    }

    // MARK: Cancellation and teardown

    @Test func cancellingTheConsumerRemovesTheObserver() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        let stream = fake.observeRoom(roomID: a.room.id)
        let task = Task { for await _ in stream {} }
        #expect(fake.observerCount == 1)
        task.cancel()
        await task.value
        #expect(fake.observerCount == 0)
    }

    @Test func cancellingTheConsumerRemovesTheConnectionSubscriber() async {
        let fake = FakeGameBackend()
        let stream = fake.connection
        let task = Task { for await _ in stream {} }
        #expect(fake.connectionObserverCount == 1)
        task.cancel()
        await task.value
        #expect(fake.connectionObserverCount == 0)
    }

    @Test func cancellingOneObserverLeavesTheOthersRunning() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        let first = Task { for await _ in fake.observeRoom(roomID: a.room.id) {} }
        var second = fake.observeRoom(roomID: a.room.id).makeAsyncIterator()
        _ = await second.next()
        first.cancel()
        await first.value
        let b = tagged(a, 2)
        fake.push(b)
        #expect(await second.next() == .snapshot(b))
        #expect(fake.observerCount == 1)
    }

    @Test func droppingTheFakeFinishesOutstandingStreams() async {
        var fake: FakeGameBackend? = FakeGameBackend(snapshot: lobbySnapshot())
        let id = fake!.currentSnapshot!.room.id
        var updates = fake!.observeRoom(roomID: id).makeAsyncIterator()
        var states = fake!.connection.makeAsyncIterator()
        _ = await updates.next()
        _ = await states.next()
        fake = nil
        #expect(await updates.next() == nil)
        #expect(await states.next() == nil)
    }

    @Test func finishStreamsEndsEverythingWithoutALoss() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        var updates = fake.observeRoom(roomID: a.room.id).makeAsyncIterator()
        _ = await updates.next()
        fake.finishStreams()
        #expect(await updates.next() == nil)
    }

    @Test func cancellingADelayedCallThrowsCancellation() async {
        let fake = FakeGameBackend()
        fake.setDelay(.seconds(30), for: .startGame)
        let task = Task { try await fake.startGame() }
        while !fake.calls.contains(.startGame) { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: Draws

    @Test func drawsComeFromTheScriptedQueue() async throws {
        let first = Draw(id: UUID(), name: "Beyoncé", token: UUID())
        let second = Draw(id: UUID(), name: "Sherlock Holmes", token: UUID())
        let fake = FakeGameBackend(scenario: lobby())
        fake.setDraws([first, second, nil])
        #expect(try await fake.startTurn() == first)
        #expect(try await fake.currentSlip() == first)
        #expect(try await fake.gotIt(token: first.token) == second)
        #expect(try await fake.currentSlip() == second)
        #expect(try await fake.skip(token: second.token) == nil)
        #expect(try await fake.currentSlip() == nil)
        #expect(try await fake.startTurn() == nil)
    }

    @Test func staleTokenReplyCanBeScripted() async throws {
        let current = Draw(id: UUID(), name: "A", token: UUID())
        let fake = FakeGameBackend(scenario: lobby())
        fake.setDraws([current])
        #expect(try await fake.gotIt(token: UUID()) == current)
    }

    // MARK: Recommendations

    private func row(_ name: String) -> CelebritySuggestion {
        CelebritySuggestion(name: name, description: "d", category: .other, sources: ["wikipedia"])
    }

    @Test func defaultSuggestionsMatchPrefixesLikeTheServer() async throws {
        let fake = FakeGameBackend()
        let tom = try await fake.suggestCelebrities(query: "tom")
        #expect(tom.map(\.name) == ["Tom Hanks", "Tom Cruise"])
        // Any word start matches: "hanks" finds Tom Hanks; a middle-of-word fragment does not.
        #expect(try await fake.suggestCelebrities(query: "hanks").map(\.name) == ["Tom Hanks"])
        #expect(try await fake.suggestCelebrities(query: "anks").isEmpty)
        // Case and accents are ignored.
        #expect(try await fake.suggestCelebrities(query: "BEYONCE").map(\.name) == ["Beyoncé"])
        #expect(try await fake.suggestCelebrities(query: "  tom  hanks ").map(\.name) == ["Tom Hanks"])
        #expect(try await fake.suggestCelebrities(query: "zzzz").isEmpty)
    }

    @Test func shortQueriesReturnNothing() async throws {
        let fake = FakeGameBackend()
        #expect(try await fake.suggestCelebrities(query: "").isEmpty)
        #expect(try await fake.suggestCelebrities(query: "t").isEmpty)
        #expect(try await fake.suggestCelebrities(query: " t ").isEmpty)
    }

    @Test func suggestionLimitIsClampedLikeTheServer() async throws {
        let rows = (0..<15).map { row("Zed \($0)") }
        let fake = FakeGameBackend(suggestions: rows)
        #expect(try await fake.suggestCelebrities(query: "zed").count == 6)
        #expect(try await fake.suggestCelebrities(query: "zed", limit: 0).count == 1)
        #expect(try await fake.suggestCelebrities(query: "zed", limit: -5).count == 1)
        #expect(try await fake.suggestCelebrities(query: "zed", limit: 10).count == 10)
        #expect(try await fake.suggestCelebrities(query: "zed", limit: 99).count == 10)
    }

    @Test func explicitQueryOverridesAreKept() async throws {
        let fake = FakeGameBackend()
        fake.setSuggestions([row("Override")], forQuery: "zz")
        #expect(try await fake.suggestCelebrities(query: "ZZ") == [row("Override")])
        #expect(try await fake.suggestCelebrities(query: "t").isEmpty)
        fake.setSuggestions([row("Pool Name")])
        #expect(try await fake.suggestCelebrities(query: "pool").map(\.name) == ["Pool Name"])
    }

    @Test func randomHonoursNormalisedExclusionsAndHasNoRepeats() async throws {
        let fake = FakeGameBackend()
        let all = try await fake.randomCelebrities(count: 20, excluding: [])
        #expect(Set(all.map(\.name)).count == all.count)
        let kept = try await fake.randomCelebrities(count: 20, excluding: ["tom   HANKS", "BEYONCE"])
        #expect(!kept.contains { $0.name == "Tom Hanks" || $0.name == "Beyoncé" })
        #expect(Set(kept.map(\.name)).count == kept.count)
    }

    @Test func randomClampsCountLikeTheServer() async throws {
        let fake = FakeGameBackend()
        #expect(try await fake.randomCelebrities(count: 0, excluding: []).count == 1)
        #expect(try await fake.randomCelebrities(count: -3, excluding: []).count == 1)
        #expect(try await fake.randomCelebrities(count: 8, excluding: []).count == 8)
        #expect(try await fake.randomCelebrities(count: 500, excluding: []).count == 20)
    }

    @Test func shuffleChangesTheIdeasByDefault() async throws {
        let fake = FakeGameBackend()
        let first = try await fake.randomCelebrities(count: 8, excluding: [])
        let second = try await fake.randomCelebrities(count: 8, excluding: [])
        #expect(first != second)
        #expect(first.count == 8 && second.count == 8)
    }

    @Test func scriptedShuffleSequenceCycles() async throws {
        let one = [row("A1"), row("A2")], two = [row("B1")]
        let fake = FakeGameBackend()
        fake.setRandomSequence([one, two])
        #expect(try await fake.randomCelebrities(count: 8, excluding: []) == one)
        #expect(try await fake.randomCelebrities(count: 8, excluding: []) == two)
        #expect(try await fake.randomCelebrities(count: 8, excluding: ["a1"]) == [row("A2")])
    }

    @Test func slowQueryFinishesAfterAFastOneInControlledOrder() async throws {
        let slow = row("Slow"), fast = row("Fast")
        let fake = FakeGameBackend()
        fake.setSuggestions([slow], forQuery: "to")
        fake.setSuggestions([fast], forQuery: "tom")
        fake.setSuggestionDelay(.milliseconds(200), forQuery: "to")
        let order = Order()
        async let first: [CelebritySuggestion] = { let r = try await fake.suggestCelebrities(query: "to"); await order.add("to"); return r }()
        // Issue the second query only after the first is in flight.
        while fake.calls(of: .suggestCelebrities).isEmpty { await Task.yield() }
        async let second: [CelebritySuggestion] = { let r = try await fake.suggestCelebrities(query: "tom"); await order.add("tom"); return r }()
        let (a, b) = try await (first, second)
        #expect(a == [slow] && b == [fast])
        #expect(await order.items == ["tom", "to"])
    }

    // MARK: Identity and heartbeat

    @Test func heartbeatReturnsServerTime() async throws {
        let s = lobby()
        let fake = FakeGameBackend(scenario: s)
        #expect(try await fake.heartbeat(roomID: s.snapshot.room.id) == s.snapshot.serverNow)
    }

    @Test func userIDComesFromInit() async throws {
        let id = UUID()
        #expect(try await FakeGameBackend(userID: id).currentUserID() == id)
    }

    // MARK: Strict concurrency

    @MainActor @Test func mainActorViewModelObservesSnapshotsLossAndConnection() async throws {
        let s = SampleScenario.make(.playingClueGiver, now: now)
        let fake = FakeGameBackend(scenario: s)
        let model = ProbeViewModel(backend: fake)
        await model.create()
        #expect(model.snapshot == s.snapshot)
        fake.setDraws([s.draw])
        await model.start()
        #expect(model.draw == s.draw)

        fake.fail(.createRoom, with: .rateLimited)
        await model.create()
        #expect(model.errorMessage == BackendError.rateLimited.userMessage)

        // Subscriptions exist as soon as these calls return: no sleeping.
        let observing = model.observe(s.snapshot.room.id)
        let watching = model.watchConnection()
        fake.push(tagged(s.snapshot, 2))
        fake.setConnection(.reconnecting)
        await watching.value
        #expect(model.state == .reconnecting)
        fake.simulateRoomLoss(.removed)
        await observing.value
        #expect(model.lost == .removed)
        #expect(model.seen.last == 2 || model.seen.last == s.snapshot.room.round)
    }

    @MainActor @Test func mainActorViewModelGetsAnImmediateLossForAStaleRoom() async {
        let fake = FakeGameBackend()
        let model = ProbeViewModel(backend: fake)
        await model.observe(UUID()).value
        #expect(model.lost == .removed)
        #expect(model.snapshot == nil)
    }

    @MainActor @Test func mainActorCancellationUnsubscribes() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        let model = ProbeViewModel(backend: fake)
        let task = model.observe(a.room.id)
        #expect(fake.observerCount == 1)
        task.cancel()
        await task.value
        #expect(fake.observerCount == 0)
        #expect(model.lost == nil)
    }
}

private actor Order {
    var items: [String] = []
    func add(_ item: String) { items.append(item) }
}
