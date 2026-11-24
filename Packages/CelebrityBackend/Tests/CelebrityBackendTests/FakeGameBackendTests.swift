import CelebrityCore
import Foundation
import Observation
import Testing
@testable import CelebrityBackend

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
private func lobby() -> SampleScenario { SampleScenario.make(.lobbyHost, now: now) }

/// Compile-time proof that a main-actor observable view model can drive any GameBackend under strict concurrency.
@MainActor @Observable
private final class ProbeViewModel {
    let backend: any GameBackend
    var snapshot: RoomSnapshot?
    var errorMessage: String?
    var draw: Draw?
    var lost: RoomLoss?
    var state: ConnectionState = .disconnected

    init(backend: any GameBackend) { self.backend = backend }

    func create() async {
        do { snapshot = try await backend.createRoom(name: "Alex") } catch { errorMessage = BackendError.from(error).userMessage }
    }

    func follow(_ roomID: UUID) async {
        for await next in backend.updates(roomID: roomID) { snapshot = next; if next.room.round >= 2 { break } }
    }

    func watchLoss() async { for await loss in backend.roomLosses { lost = loss; break } }
    func watchConnection() async { for await s in backend.connection { state = s; if s == .reconnecting { break } } }
    func start() async { draw = try? await backend.startTurn() }
}

@Suite struct FakeGameBackendTests {
    // MARK: Recording

    @Test func recordsCallsInOrderWithArguments() async throws {
        let s = lobby()
        let fake = FakeGameBackend(scenario: s)
        let token = UUID()
        let other = UUID()
        _ = try await fake.currentUserID()
        _ = try await fake.createRoom(name: "Alex")
        _ = try await fake.joinRoom(code: "K7Q2", name: "Blair")
        try await fake.setTeams([other: 1, s.userID: nil])
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
        let calls = fake.calls
        #expect(calls.count == 17)
        #expect(calls[0] == .currentUserID)
        #expect(calls[1] == .createRoom(name: "Alex"))
        #expect(calls[2] == .joinRoom(code: "K7Q2", name: "Blair"))
        #expect(calls[3] == .setTeams([other: 1, s.userID: nil]))
        #expect(calls[5] == .updateSettings(SettingsUpdate(turnSeconds: 30)))
        #expect(calls[7] == .submitSlips(["A", "A", "B"]))
        #expect(calls[10] == .gotIt(token: token))
        #expect(calls[11] == .skip(token: token))
        #expect(calls[13] == .transferHost(to: other))
        #expect(calls[15] == .suggestCelebrities(query: "tom", limit: 6))
        #expect(calls[16] == .randomCelebrities(count: 5, excluding: ["Tom Hanks"]))
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
        let id = lobby().snapshot.room.id
        await #expect(throws: BackendError.network("offline")) { try await fake.heartbeat(roomID: id) }
        await #expect(throws: BackendError.network("offline")) { try await fake.heartbeat(roomID: id) }
        _ = try await fake.heartbeat(roomID: id)
    }

    @Test func failAlwaysUntilCleared() async throws {
        let fake = FakeGameBackend(scenario: lobby())
        fake.failAlways(.leaveRoom, with: .notMember)
        for _ in 0..<3 { await #expect(throws: BackendError.notMember) { try await fake.leaveRoom() } }
        fake.clearFailures()
        try await fake.leaveRoom()
    }

    @Test func failureOnOneKindLeavesOthersAlone() async throws {
        let fake = FakeGameBackend(scenario: lobby())
        fake.failAlways(.kickPlayer, with: .notHost)
        try await fake.startGame()
        await #expect(throws: BackendError.notHost) { try await fake.kickPlayer(userID: UUID()) }
    }

    @Test func nonBackendErrorsAreReportedAsBackendErrors() async {
        let fake = FakeGameBackend(scenario: lobby())
        fake.fail(.createRoom, with: .rateLimited)
        do { _ = try await fake.createRoom(name: "x"); Issue.record("should throw") } catch let e as BackendError { #expect(e == .rateLimited) } catch { Issue.record("wrong type") }
    }

    // MARK: Snapshots

    @Test func snapshotReturningCallsReplayTheCurrentSnapshot() async throws {
        let s = lobby()
        let fake = FakeGameBackend(scenario: s)
        #expect(try await fake.createRoom(name: "x") == s.snapshot)
        #expect(try await fake.joinRoom(code: "K7Q2", name: "x") == s.snapshot)
        #expect(try await fake.snapshot(roomID: s.snapshot.room.id) == s.snapshot)
    }

    @Test func snapshotOfAnotherRoomIsNotMember() async {
        let fake = FakeGameBackend(scenario: lobby())
        await #expect(throws: BackendError.notMember) { try await fake.snapshot(roomID: UUID()) }
    }

    @Test func noSnapshotMeansNotMemberAndFailedCreate() async {
        let fake = FakeGameBackend()
        await #expect(throws: BackendError.notMember) { try await fake.snapshot(roomID: UUID()) }
        await #expect(throws: BackendError.self) { try await fake.createRoom(name: "x") }
    }

    @Test func scriptedSnapshotsAreReturnedInOrderByThatCall() async throws {
        let a = SampleScenario.make(.lobbyHost, now: now).snapshot
        let b = SampleScenario.make(.submittingEditing, now: now).snapshot
        let fake = FakeGameBackend()
        fake.script(.joinRoom, snapshots: [a, b])
        #expect(try await fake.joinRoom(code: "K7Q2", name: "x") == a)
        #expect(try await fake.joinRoom(code: "K7Q2", name: "x") == b)
        // The queue is empty now, so the last snapshot stays current.
        #expect(try await fake.joinRoom(code: "K7Q2", name: "x") == b)
        #expect(fake.currentSnapshot == b)
    }

    @Test func voidCallPushesItsScriptedSnapshotOnSuccessOnly() async throws {
        let a = SampleScenario.make(.lobbyHost, now: now).snapshot
        let b = SampleScenario.make(.submittingEditing, now: now).snapshot
        let fake = FakeGameBackend(snapshot: a)
        fake.script(.startGame, snapshots: [b])
        fake.fail(.startGame, with: .notEnoughPlayers)
        _ = try? await fake.startGame()
        #expect(fake.currentSnapshot == a)
        try await fake.startGame()
        #expect(fake.currentSnapshot == b)
    }

    // MARK: Updates stream

    @Test func updatesYieldsCurrentThenPushes() async throws {
        let a = SampleScenario.make(.lobbyHost, now: now).snapshot
        let b = SampleScenario.make(.submittingEditing, now: now).snapshot
        let fake = FakeGameBackend(snapshot: a)
        var iterator = fake.updates(roomID: a.room.id).makeAsyncIterator()
        #expect(await iterator.next() == a)
        fake.push(b)
        #expect(await iterator.next() == b)
        #expect(fake.currentSnapshot == b)
    }

    @Test func updatesIgnoresOtherRoomsAndSupportsManySubscribers() async throws {
        let a = SampleScenario.make(.lobbyHost, now: now).snapshot
        let fake = FakeGameBackend(snapshot: a)
        var one = fake.updates(roomID: a.room.id).makeAsyncIterator()
        var two = fake.updates(roomID: a.room.id).makeAsyncIterator()
        var other = fake.updates(roomID: UUID()).makeAsyncIterator()
        #expect(await one.next() == a)
        #expect(await two.next() == a)
        var b = a
        b.room.round = 1
        fake.push(b)
        #expect(await one.next() == b)
        #expect(await two.next() == b)
        // The other room's subscriber saw nothing: finishing the backend's streams ends it with no values.
        fake.finishStreams()
        #expect(await other.next() == nil)
    }

    @Test func updatesFinishesWhenTheRoomIsLost() async {
        let a = SampleScenario.make(.lobbyHost, now: now).snapshot
        let fake = FakeGameBackend(snapshot: a)
        var iterator = fake.updates(roomID: a.room.id).makeAsyncIterator()
        _ = await iterator.next()
        fake.simulateRoomLoss(.removed)
        #expect(await iterator.next() == nil)
        #expect(fake.currentSnapshot == nil)
    }

    // MARK: Room loss and connection

    @Test func roomLossIsPublished() async {
        let a = SampleScenario.make(.lobbyHost, now: now).snapshot
        let fake = FakeGameBackend(snapshot: a)
        var iterator = fake.roomLosses.makeAsyncIterator()
        fake.simulateRoomLoss(.roomDeleted)
        #expect(await iterator.next() == RoomLoss(roomID: a.room.id, reason: .roomDeleted))
    }

    @Test func roomLossWithoutARoomIsIgnored() async {
        let fake = FakeGameBackend()
        fake.simulateRoomLoss(.removed, roomID: nil)
        #expect(fake.currentSnapshot == nil)
    }

    @Test func connectionYieldsCurrentThenChanges() async {
        let fake = FakeGameBackend(connection: .connecting)
        var iterator = fake.connection.makeAsyncIterator()
        #expect(await iterator.next() == .connecting)
        fake.setConnection(.connected)
        #expect(await iterator.next() == .connected)
        fake.setConnection(.reconnecting)
        #expect(await iterator.next() == .reconnecting)
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
        // Exhausted queue: no more draws.
        #expect(try await fake.startTurn() == nil)
    }

    @Test func staleTokenReplyCanBeScripted() async throws {
        let current = Draw(id: UUID(), name: "A", token: UUID())
        let fake = FakeGameBackend(scenario: lobby())
        fake.setDraws([current])
        #expect(try await fake.gotIt(token: UUID()) == current)
    }

    // MARK: Recommendations

    @Test func suggestionsAreCannedAndClamped() async throws {
        let rows = (0..<8).map { CelebritySuggestion(name: "N\($0)", description: "d", category: .music, sources: ["wikipedia"]) }
        let fake = FakeGameBackend(scenario: lobby())
        fake.setSuggestions(rows)
        #expect(try await fake.suggestCelebrities(query: "n").count == 6)
        #expect(try await fake.suggestCelebrities(query: "n", limit: 3).count == 3)
        fake.setSuggestions([rows[0]], forQuery: "zz")
        #expect(try await fake.suggestCelebrities(query: "ZZ") == [rows[0]])
        #expect(try await fake.suggestCelebrities(query: "other").count == 6)
    }

    @Test func randomSuggestionsAreCanned() async throws {
        let rows = (0..<12).map { CelebritySuggestion(name: "R\($0)", description: "", category: .other, sources: []) }
        let fake = FakeGameBackend(scenario: lobby())
        fake.setRandomSuggestions(rows)
        #expect(try await fake.randomCelebrities(count: 8, excluding: []) == Array(rows.prefix(8)))
    }

    @Test func defaultSuggestionsAreProvided() async throws {
        let fake = FakeGameBackend()
        #expect(!(try await fake.suggestCelebrities(query: "to")).isEmpty)
        #expect(!(try await fake.randomCelebrities(count: 8, excluding: [])).isEmpty)
    }

    @Test func slowQueryCanBeScriptedToFinishAfterAFastOne() async throws {
        let slow = CelebritySuggestion(name: "Slow", description: "", category: .other, sources: [])
        let fast = CelebritySuggestion(name: "Fast", description: "", category: .other, sources: [])
        let fake = FakeGameBackend()
        fake.setSuggestions([slow], forQuery: "to")
        fake.setSuggestions([fast], forQuery: "tom")
        fake.setSuggestionDelay(.milliseconds(150), forQuery: "to")
        async let first = fake.suggestCelebrities(query: "to")
        async let second = fake.suggestCelebrities(query: "tom")
        let (a, b) = try await (first, second)
        #expect(a == [slow] && b == [fast])
    }

    @Test func cancellingADelayedCallThrowsCancellation() async {
        let fake = FakeGameBackend()
        fake.setDelay(.seconds(30), for: .startGame)
        let task = Task { try await fake.startGame() }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: Identity and state helpers

    @Test func heartbeatReturnsServerTime() async throws {
        let s = lobby()
        let fake = FakeGameBackend(scenario: s)
        #expect(try await fake.heartbeat(roomID: s.snapshot.room.id) == s.snapshot.serverNow)
    }

    @Test func userIDComesFromInit() async throws {
        let id = UUID()
        #expect(try await FakeGameBackend(userID: id).currentUserID() == id)
    }

    @Test func voidCallsDoNotReimplementRules() async throws {
        // Starting a game with an empty lobby succeeds in the fake: the server owns the rules.
        let fake = FakeGameBackend(scenario: SampleScenario.make(.lobbyUnevenHost, now: now))
        try await fake.startGame()
        #expect(fake.currentSnapshot?.room.phase == .lobby)
    }

    // MARK: Strict concurrency

    @MainActor @Test func mainActorViewModelCanDriveIt() async throws {
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

        let watcher = Task { await model.watchLoss() }
        let conn = Task { await model.watchConnection() }
        try await Task.sleep(for: .milliseconds(50))
        fake.setConnection(.reconnecting)
        fake.simulateRoomLoss(.removed)
        await watcher.value
        await conn.value
        #expect(model.lost?.reason == .removed)
        #expect(model.state == .reconnecting)
    }
}
