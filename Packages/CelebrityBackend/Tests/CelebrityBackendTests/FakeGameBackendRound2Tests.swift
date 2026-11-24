import CelebrityCore
import Foundation
import Testing
@testable import CelebrityBackend

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
private func lobbySnapshot() -> RoomSnapshot { SampleScenario.make(.lobbyHost, now: now).snapshot }
private func tagged(_ base: RoomSnapshot, _ n: Int) -> RoomSnapshot { var c = base; c.room.round = n; return c }
private func otherRoom(_ base: RoomSnapshot) -> RoomSnapshot { var c = base; c.room.id = UUID(); return c }

/// Waits (by yielding) until the fake has recorded a call of this kind, so a test can act while that call is suspended.
private func waitForCall(_ kind: FakeGameBackend.CallKind, on fake: FakeGameBackend) async {
    while fake.calls(of: kind).isEmpty { await Task.yield() }
}

/// Collects every remaining element of a stream that is known to end.
private func drain<T: Sendable>(_ stream: AsyncStream<T>) async -> [T] {
    var result: [T] = []
    for await element in stream { result.append(element) }
    return result
}

/// The terminal reasons in drained elements. Streams keep only the newest element, so an unread snapshot may have been
/// replaced by the loss; what matters is exactly one terminal event.
private func losses(_ elements: [RoomUpdate]) -> [RoomLossReason] {
    elements.compactMap { if case .lost(let reason) = $0 { reason } else { nil } }
}

@Suite struct FakeRound2Tests {
    // MARK: Finding 1: shared outcome, scoped failures

    @Test func aSecondObserversLostRefreshEndsTheFirstObserverToo() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        let first = fake.observeRoom(roomID: a.room.id)
        fake.fail(.snapshot, with: .notMember, forRoom: a.room.id)
        let second = fake.observeRoom(roomID: a.room.id)
        fake.push(a)   // a later push must reach neither
        let firstElements = await drain(first)
        let secondElements = await drain(second)
        #expect(losses(firstElements) == [.removed])
        #expect(losses(secondElements) == [.removed])
        #expect(firstElements.last == .lost(.removed) && secondElements.last == .lost(.removed))
        #expect(fake.observerCount == 0)
    }

    @Test func anUnrelatedObservationDoesNotConsumeTheActiveRoomsArmedFailure() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        fake.fail(.snapshot, with: .notMember, forRoom: a.room.id)
        #expect(await drain(fake.observeRoom(roomID: UUID())) == [.lost(.removed)])
        #expect(fake.currentSnapshot == a)
        #expect(await drain(fake.observeRoom(roomID: a.room.id)) == [.lost(.removed)])
        #expect(fake.currentSnapshot == nil)
    }

    @Test func anUnscopedFailureIsNotConsumedByAnotherRoomsObservation() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        fake.fail(.snapshot, with: .notMember)
        _ = await drain(fake.observeRoom(roomID: UUID()))
        #expect(fake.currentSnapshot == a)
        #expect(await drain(fake.observeRoom(roomID: a.room.id)) == [.lost(.removed)])
    }

    // MARK: Finding 2: generations

    @Test func aDelayedForegroundCannotResurrectARoomAfterLeave() async throws {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        fake.script(.didEnterForeground, snapshots: [tagged(a, 2)])
        fake.setDelay(.milliseconds(50), for: .didEnterForeground)
        let refresh = Task { await fake.didEnterForeground() }
        await waitForCall(.didEnterForeground, on: fake)
        try await fake.leaveRoom()
        await refresh.value
        #expect(fake.currentSnapshot == nil)
    }

    @Test func aDelayedForegroundFailureDoesNotHitAFreshRoom() async throws {
        let a = lobbySnapshot(), c = otherRoom(a)
        let fake = FakeGameBackend(snapshot: a)
        fake.fail(.didEnterForeground, with: .notMember)
        fake.setDelay(.milliseconds(50), for: .didEnterForeground)
        let refresh = Task { await fake.didEnterForeground() }
        await waitForCall(.didEnterForeground, on: fake)
        try await fake.leaveRoom()
        fake.push(c)
        let stream = fake.observeRoom(roomID: c.room.id)
        await refresh.value
        #expect(fake.observerCount == 1)
        #expect(fake.currentSnapshot == c)
        fake.finishStreams()
        #expect(await drain(stream) == [.snapshot(c)])
    }

    @Test func aDelayedSnapshotCannotTerminateAFreshObservationOfTheSameRoom() async throws {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        fake.setDelay(.milliseconds(50), for: .snapshot)
        let probe = Task { try? await fake.snapshot(roomID: a.room.id) }
        await waitForCall(.snapshot, on: fake)
        try await fake.leaveRoom()
        fake.push(a)                                   // same id, fresh membership
        var fresh = fake.observeRoom(roomID: a.room.id).makeAsyncIterator()
        #expect(await fresh.next() == .snapshot(a))
        fake.fail(.snapshot, with: .notMember)         // armed after the probe started; the probe consumes it when it resumes
        _ = await probe.value
        #expect(fake.observerCount == 1)
        let b = tagged(a, 2)
        fake.push(b)
        #expect(await fresh.next() == .snapshot(b))
    }

    @Test func probingAnotherRoomDoesNotConsumeOrCommitAScriptedSnapshot() async throws {
        let a = lobbySnapshot(), c = otherRoom(a)
        let fake = FakeGameBackend(snapshot: a)
        fake.script(.snapshot, snapshots: [c])
        await #expect(throws: BackendError.notMember) { try await fake.snapshot(roomID: UUID()) }
        #expect(fake.currentSnapshot == a)
        // The script was kept for the room it describes.
        #expect(try await fake.snapshot(roomID: c.room.id) == c)
    }

    @Test func roomBoundScriptsAndDrawsDoNotSurviveALeave() async throws {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        fake.script(.endTurn, snapshots: [tagged(a, 3)])
        fake.setDraws([Draw(id: UUID(), name: "Old", token: UUID())])
        try await fake.leaveRoom()
        fake.push(a)
        try await fake.endTurn()
        #expect(fake.currentSnapshot == a)
        #expect(try await fake.startTurn() == nil)
    }

    // MARK: Finding 3: join refusal and local membership changes

    @Test func aRefusedChannelJoinStillProbesMembership() async {
        let fake = FakeGameBackend()
        fake.refuseChannelJoin()
        let stale = UUID()
        #expect(await drain(fake.observeRoom(roomID: stale)) == [.lost(.removed)])
        #expect(fake.calls == [.snapshot(roomID: stale)])
    }

    @Test func aRefusedJoinForAMemberKeepsObservingAndShowsReconnecting() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        fake.refuseChannelJoin()
        var updates = fake.observeRoom(roomID: a.room.id).makeAsyncIterator()
        #expect(await updates.next() == .snapshot(a))
        var states = fake.connection.makeAsyncIterator()
        #expect(await states.next() == .reconnecting)
    }

    @Test(arguments: [RoomLossReason.removed, .roomDeleted])
    func anInvalidationBeforeALocalLeaveReturnsEndsWithLeft(remote: RoomLossReason) async throws {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        let stream = fake.observeRoom(roomID: a.room.id)
        fake.setDelay(.milliseconds(50), for: .leaveRoom)
        let leaving = Task { try await fake.leaveRoom() }
        await waitForCall(.leaveRoom, on: fake)
        fake.simulateRoomLoss(remote)
        #expect(fake.observerCount == 1, "classification is deferred while the leave is in flight")
        try await leaving.value
        #expect(losses(await drain(stream)) == [.left])
    }

    @Test func aFailedLeaveThenAppliesTheDeferredLoss() async throws {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        let stream = fake.observeRoom(roomID: a.room.id)
        fake.setDelay(.milliseconds(50), for: .leaveRoom)
        fake.fail(.leaveRoom, with: .network("offline"))
        let leaving = Task { try await fake.leaveRoom() }
        await waitForCall(.leaveRoom, on: fake)
        fake.simulateRoomLoss(.removed)
        await #expect(throws: BackendError.network("offline")) { try await leaving.value }
        #expect(losses(await drain(stream)) == [.removed])
    }

    @Test func anInvalidationBeforeARoomSwitchReturnsEndsWithLeft() async throws {
        let a = lobbySnapshot(), c = otherRoom(a)
        let fake = FakeGameBackend(snapshot: a)
        let stream = fake.observeRoom(roomID: a.room.id)
        fake.script(.joinRoom, snapshots: [c])
        fake.setDelay(.milliseconds(50), for: .joinRoom)
        let joining = Task { try await fake.joinRoom(code: "ZZZZ", name: "x") }
        await waitForCall(.joinRoom, on: fake)
        fake.simulateRoomLoss(.roomDeleted, roomID: a.room.id)
        _ = try await joining.value
        #expect(losses(await drain(stream)) == [.left])
        #expect(fake.currentSnapshot == c)
    }

    @Test func anInvalidationBeforeDeleteMyDataReturnsEndsWithSessionEnded() async throws {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        let stream = fake.observeRoom(roomID: a.room.id)
        fake.setDelay(.milliseconds(50), for: .deleteMyData)
        let deleting = Task { try await fake.deleteMyData() }
        await waitForCall(.deleteMyData, on: fake)
        fake.simulateRoomLoss(.removed)
        try await deleting.value
        #expect(losses(await drain(stream)) == [.sessionEnded])
    }

    // MARK: Finding 4: refresh failure classes

    @Test func aNetworkFailureOnTheInitialRefreshKeepsTheObservationOpenAndRetriesOnForeground() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        fake.fail(.snapshot, with: .network("offline"), forRoom: a.room.id)
        var updates = fake.observeRoom(roomID: a.room.id).makeAsyncIterator()
        var states = fake.connection.makeAsyncIterator()
        #expect(await states.next() == .reconnecting)
        await fake.didEnterForeground()              // the retry
        #expect(await updates.next() == .snapshot(a))
        #expect(await states.next() == .connected)
    }

    @Test func anInvalidSessionEndsTheObservationWithSessionEnded() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        fake.fail(.snapshot, with: .notAuthenticated, forRoom: a.room.id)
        #expect(await drain(fake.observeRoom(roomID: a.room.id)) == [.lost(.sessionEnded)])
    }

    @Test(arguments: [BackendError.permissionDenied, .unknown("undecodable")])
    func aPermanentFailureEndsTheObservationWithTheError(error: BackendError) async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        fake.fail(.snapshot, with: error, forRoom: a.room.id)
        #expect(await drain(fake.observeRoom(roomID: a.room.id)) == [.lost(.failed(error))])
    }

    @Test func foregroundWithNoRoomDoesNothingAndConsumesNothing() async {
        let fake = FakeGameBackend()
        fake.fail(.didEnterForeground, with: .notMember)
        fake.script(.didEnterForeground, snapshots: [lobbySnapshot()])
        await fake.didEnterForeground()
        #expect(fake.currentSnapshot == nil)
        #expect(fake.calls == [.didEnterForeground])
        // Both are still armed: with a room they apply.
        let a = lobbySnapshot()
        fake.push(a)
        let stream = fake.observeRoom(roomID: a.room.id)
        await fake.didEnterForeground()
        #expect(losses(await drain(stream)) == [.removed])
    }

    @Test(arguments: [(BackendError.notAuthenticated, RoomLossReason.sessionEnded), (.permissionDenied, .failed(.permissionDenied))])
    func foregroundFailuresAreClassifiedLikeTheInitialRefresh(error: BackendError, reason: RoomLossReason) async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        let stream = fake.observeRoom(roomID: a.room.id)
        fake.fail(.didEnterForeground, with: error)
        await fake.didEnterForeground()
        #expect(losses(await drain(stream)) == [reason])
    }

    // MARK: Finding 6: connection semantics

    @Test func connectionIsIdleBeforeAnyObservation() async {
        let fake = FakeGameBackend(snapshot: lobbySnapshot())
        var states = fake.connection.makeAsyncIterator()
        #expect(await states.next() == .idle)
    }

    @Test func connectionIsConnectedWhileObservingAndIdleAfterTheLastObserverCancels() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        var states = fake.connection.makeAsyncIterator()
        #expect(await states.next() == .idle)
        let one = Task { for await _ in fake.observeRoom(roomID: a.room.id) {} }
        let two = Task { for await _ in fake.observeRoom(roomID: a.room.id) {} }
        #expect(await states.next() == .connected)
        one.cancel(); await one.value
        #expect(fake.observerCount == 1)
        #expect(fake.currentConnection == .connected, "one observer is still joined")
        two.cancel(); await two.value
        #expect(fake.observerCount == 0)
        #expect(await states.next() == .idle)
    }

    @Test(arguments: ["loss", "leave", "delete"])
    func connectionReturnsToIdleWhenTheRoomEnds(how: String) async throws {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        let stream = fake.observeRoom(roomID: a.room.id)
        #expect(fake.currentConnection == .connected)
        switch how {
        case "loss": fake.simulateRoomLoss(.removed)
        case "leave": try await fake.leaveRoom()
        default: try await fake.deleteMyData()
        }
        _ = await drain(stream)
        #expect(fake.currentConnection == .idle)
    }

    @Test func foregroundRetryRecoversTheConnection() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        let stream = fake.observeRoom(roomID: a.room.id)
        defer { fake.finishStreams(); _ = stream }
        fake.fail(.didEnterForeground, with: .network("offline"))
        await fake.didEnterForeground()
        #expect(fake.currentConnection == .reconnecting)
        await fake.didEnterForeground()
        #expect(fake.currentConnection == .connected)
    }

    @Test func onlyReconnectingAndDisconnectedShowTheBanner() {
        #expect(ConnectionState.reconnecting.showsReconnectingBanner)
        #expect(ConnectionState.disconnected.showsReconnectingBanner)
        for s in [ConnectionState.idle, .connecting, .connected] { #expect(!s.showsReconnectingBanner) }
        #expect(!ConnectionState.idle.isConnected)
    }

    // MARK: Findings 7 and 8: Start Turn pair and private-draw transitions

    @Test func startTurnFollowUpScoresNothingAndPairsTheDraw() async throws {
        let ready = SampleScenario.make(.playingClueGiverReady, now: now)
        let started = try #require(ready.followUp)
        let draw = try #require(ready.followUpDraw)
        #expect(started.room.turnGot == 0 && started.room.turnSkips == 0)
        #expect(started.room.scores == ready.snapshot.room.scores)
        #expect(started.room.pileCount == ready.snapshot.room.pileCount)
        #expect(started.room.turnEndsAt == now.addingTimeInterval(Double(started.room.settings.turnSeconds)))
        #expect(started.turns == ready.snapshot.turns)

        let fake = FakeGameBackend(scenario: ready)
        fake.script(.startTurn, followUpOf: ready)
        var updates = fake.observeRoom(roomID: started.room.id).makeAsyncIterator()
        #expect(await updates.next() == .snapshot(ready.snapshot))
        #expect(try await fake.startTurn() == draw)
        #expect(await updates.next() == .snapshot(started))
        #expect(try await fake.currentSlip() == draw)
        #expect(fake.currentSnapshot == started)
    }

    @Test func scoredInProgressFixtureStillExists() {
        let running = SampleScenario.make(.playingClueGiver, now: now).snapshot.room
        #expect(running.turnGot == 2 && running.pileCount == 11)
    }

    @Test func aScriptedTransitionCanClearThePrivateDrawInTheSameCommit() async throws {
        let s = SampleScenario.make(.playingClueGiver, now: now)
        var ended = s.snapshot
        ended.room.round = 2   // marker: the turn ended
        ended.room.turnEndsAt = nil
        ended.room.turnPlayerID = SampleCast.drew.id
        let fake = FakeGameBackend(scenario: s)
        fake.script(.endTurn, transitions: [ScriptedTransition(snapshot: ended, draw: .clear)])
        let stream = fake.observeRoom(roomID: s.snapshot.room.id)
        let seen = Task { () -> [Draw?] in
            var draws: [Draw?] = []
            for await update in stream {
                if case .snapshot(let snap) = update {
                    draws.append(fake.currentDraw)       // read as soon as the snapshot arrives
                    if snap.room.round == 2 { break }
                }
            }
            return draws
        }
        try await fake.endTurn()
        let draws = await seen.value
        #expect(draws.last == .some(nil), "the card is already cleared when the ended-turn snapshot is visible")
        #expect(try await fake.currentSlip() == nil)
    }

    @Test func foregroundRefreshCanSetOrClearTheDrawWithItsSnapshot() async throws {
        let s = SampleScenario.make(.playingClueGiver, now: now)
        var next = s.snapshot
        next.room.round = 2
        let replacement = Draw(id: UUID(), name: "Fresh", token: UUID())
        let fake = FakeGameBackend(scenario: s)
        fake.script(.didEnterForeground, transitions: [ScriptedTransition(snapshot: next, draw: .set(replacement))])
        await fake.didEnterForeground()
        #expect(try await fake.currentSlip() == replacement)
        var later = next
        later.room.round = 3
        fake.script(.didEnterForeground, transitions: [ScriptedTransition(snapshot: later, draw: .clear)])
        await fake.didEnterForeground()
        #expect(try await fake.currentSlip() == nil)
    }

    // MARK: Finding 10

    @Test func aRefreshAfterTheLossDoesNotProduceASecondTerminalEvent() async {
        let a = lobbySnapshot()
        let fake = FakeGameBackend(snapshot: a)
        let stream = fake.observeRoom(roomID: a.room.id)
        fake.fail(.snapshot, with: .notMember)
        await #expect(throws: BackendError.notMember) { try await fake.snapshot(roomID: a.room.id) }
        // The room is already lost: probing it again changes nothing for the finished stream.
        await #expect(throws: BackendError.notMember) { try await fake.snapshot(roomID: a.room.id) }
        #expect(losses(await drain(stream)) == [.removed])
        // A new observation is a new attempt with its own single terminal event.
        #expect(await drain(fake.observeRoom(roomID: a.room.id)) == [.lost(.removed)])
    }
}
