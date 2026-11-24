import CelebrityCore
import Foundation
import Testing
@testable import CelebrityBackend

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func scenario(_ id: SampleScenario.ID) -> SampleScenario { SampleScenario.make(id, now: now) }

@Suite struct SampleScenarioTests {
    @Test func everyScenarioBuildsAndViewerIsSeatedInTheRoom() {
        for id in SampleScenario.ID.allCases {
            let s = scenario(id)
            #expect(s.id == id)
            #expect(s.snapshot.me(userID: s.userID) != nil, "\(id): viewer has no seat")
            #expect(s.snapshot.serverNow == now)
            #expect(s.snapshot.players.allSatisfy { $0.roomID == s.snapshot.room.id })
            #expect(s.snapshot.players.map(\.seat) == Array(1...s.snapshot.players.count))
            #expect(!s.title.isEmpty)
        }
        #expect(SampleScenario.all(now: now).map(\.id) == SampleScenario.ID.allCases)
    }

    @Test func snapshotsSurviveTheWireRoundTrip() throws {
        for s in SampleScenario.all(now: now) {
            let data = try RoomSnapshot.makeEncoder().encode(s.snapshot)
            #expect(try RoomSnapshot.makeDecoder().decode(RoomSnapshot.self, from: data) == s.snapshot, "\(s.id)")
        }
    }

    @Test func lobbyAsHost() {
        let s = scenario(.lobbyHost)
        #expect(Screen.from(snapshot: s.snapshot) == .lobby)
        #expect(s.snapshot.isHost(userID: s.userID))
        #expect(s.snapshot.canStartGame(userID: s.userID).allowed)
        #expect(s.draw == nil)
    }

    @Test func lobbyAsGuest() {
        let s = scenario(.lobbyGuest)
        #expect(Screen.from(snapshot: s.snapshot) == .lobby)
        #expect(!s.snapshot.isHost(userID: s.userID))
        #expect(!s.snapshot.canStartGame(userID: s.userID).allowed)
    }

    @Test func lobbyWithUnevenTeamsCannotStart() {
        let s = scenario(.lobbyUnevenHost)
        #expect(s.snapshot.isHost(userID: s.userID))
        let check = s.snapshot.canStartGame(userID: s.userID)
        #expect(!check.allowed)
        #expect(check.reason != nil)
    }

    @Test(arguments: [SampleScenario.ID.submittingEditing, .submittingWaiting, .submittingSpectator])
    func submitting(id: SampleScenario.ID) {
        let s = scenario(id)
        #expect(Screen.from(snapshot: s.snapshot) == .submit)
        let deadline = s.snapshot.room.submissionDeadline
        #expect(deadline != nil)
        #expect((deadline ?? .distantPast) > now)
        let me = s.snapshot.me(userID: s.userID)
        switch id {
        case .submittingEditing: #expect(me?.role == .player && me?.submitted == false)
        case .submittingWaiting: #expect(me?.role == .player && me?.submitted == true)
        default: #expect(s.snapshot.isSpectator(userID: s.userID))
        }
        #expect(s.snapshot.players.contains { $0.role == .player && $0.submitted })
    }

    @Test func playingAsClueGiver() {
        let s = scenario(.playingClueGiver)
        #expect(Screen.from(snapshot: s.snapshot) == .game)
        #expect(s.snapshot.isClueGiver(userID: s.userID))
        #expect((s.snapshot.room.turnEndsAt ?? .distantPast) > now)
        #expect(s.snapshot.room.pileCount > 0)
        let draw = s.draw
        #expect(draw != nil)
        // The draw is private: it appears nowhere in the shared snapshot.
        let json = String(decoding: (try? RoomSnapshot.makeEncoder().encode(s.snapshot)) ?? Data(), as: UTF8.self)
        if let draw {
            #expect(!json.contains(draw.name))
            #expect(!json.localizedCaseInsensitiveContains(draw.token.uuidString))
        }
    }

    @Test func playingAsGuesserIsOnTheClueGiversTeam() throws {
        let s = scenario(.playingGuesser)
        #expect(s.draw == nil)
        #expect(!s.snapshot.isClueGiver(userID: s.userID))
        let giver = try #require(s.snapshot.nextUp)
        #expect(s.snapshot.me(userID: s.userID)?.team == giver.team)
        #expect(s.snapshot.me(userID: s.userID)?.role == .player)
    }

    @Test func playingAsOpponentIsOnTheOtherTeam() throws {
        let s = scenario(.playingOpponent)
        #expect(s.draw == nil)
        let giver = try #require(s.snapshot.nextUp)
        let me = try #require(s.snapshot.me(userID: s.userID))
        #expect(me.role == .player)
        #expect(me.team != nil && me.team != giver.team)
    }

    @Test func playingAsSpectator() {
        let s = scenario(.playingSpectator)
        #expect(s.snapshot.isSpectator(userID: s.userID))
        #expect(s.snapshot.nextUp != nil)
        #expect(s.draw == nil)
    }

    @Test(arguments: [SampleScenario.ID.stalledHost, .stalledGuest])
    func stalledRoomHasNoClueGiver(id: SampleScenario.ID) {
        let s = scenario(id)
        #expect(s.snapshot.room.phase == .playing)
        #expect(Screen.from(snapshot: s.snapshot) == .game)
        #expect(s.snapshot.room.turnPlayerID == nil)
        #expect(s.snapshot.nextUp == nil)
        #expect(s.snapshot.room.turnEndsAt == nil)
        #expect(s.snapshot.isHost(userID: s.userID) == (id == .stalledHost))
        // Neither team has two players, so nobody can be assigned.
        let perTeam = (0..<2).map { team in s.snapshot.players.filter { $0.role == .player && $0.team == team }.count }
        #expect(perTeam.allSatisfy { $0 < 2 })
        #expect(s.snapshot.players.contains { $0.role == .spectator })
    }

    @Test(arguments: [SampleScenario.ID.roundEndHost, .roundEndGuest])
    func roundEnd(id: SampleScenario.ID) {
        let s = scenario(id)
        #expect(s.snapshot.room.phase == .roundEnd)
        #expect(Screen.from(snapshot: s.snapshot) == .game)
        #expect(s.snapshot.room.pileCount == 0)
        #expect(s.snapshot.isHost(userID: s.userID) == (id == .roundEndHost))
        #expect(!s.snapshot.turns.isEmpty)
        #expect(s.snapshot.turns.allSatisfy { $0.round == s.snapshot.room.round })
        #expect(s.snapshot.teamTotals.reduce(0, +) > 0)
    }

    @Test func finishedWithWinner() {
        let s = scenario(.finishedWinner)
        #expect(Screen.from(snapshot: s.snapshot) == .finished)
        #expect(s.snapshot.winner != nil)
        #expect(s.snapshot.room.finishedAt != nil)
        #expect(s.snapshot.room.round == CelebrityCore.roundCount)
        // History includes a turn whose player was anonymised.
        let former = s.snapshot.turns.filter { $0.playerID == nil }
        #expect(!former.isEmpty && former.allSatisfy { $0.playerName == "Former player" })
        #expect(!s.snapshot.players.contains { $0.name == "Frankie" })
        #expect(s.snapshot.turns.allSatisfy { turn in turn.playerID == nil || s.snapshot.players.contains { $0.userID == turn.playerID } })
        #expect(s.snapshot.turns.contains { $0.skipped > 0 })
    }

    @Test func finishedWithTie() {
        let s = scenario(.finishedTie)
        #expect(Screen.from(snapshot: s.snapshot) == .finished)
        #expect(s.snapshot.winner == nil)
        let totals = s.snapshot.teamTotals
        #expect(totals[0] == totals[1] && totals[0] > 0)
    }

    @Test func scoresMatchTurnHistory() {
        // For rounds that are over, each team's round score equals the names guessed in its turns.
        for id in [SampleScenario.ID.finishedWinner, .finishedTie] {
            let s = scenario(id)
            for round in 1...CelebrityCore.roundCount {
                for team in 0..<2 {
                    let guessed = s.snapshot.turns.filter { $0.round == round && $0.team == team }.reduce(0) { $0 + $1.guessed.count }
                    #expect(s.snapshot.room.scores[round - 1][team] == guessed, "\(id) round \(round) team \(team)")
                }
            }
        }
    }

    @Test func viewingAsAnotherUserDropsTheDraw() {
        let s = scenario(.playingClueGiver)
        #expect(s.draw != nil)
        let other = s.viewing(as: SampleCast.blair.id)
        #expect(other.userID == SampleCast.blair.id)
        #expect(other.draw == nil)
        #expect(other.snapshot == s.snapshot)
    }

    @Test func scenarioFeedsAFakeBackend() async throws {
        let s = scenario(.playingClueGiver)
        let backend = FakeGameBackend(scenario: s)
        #expect(try await backend.currentUserID() == s.userID)
        #expect(try await backend.snapshot(roomID: s.snapshot.room.id) == s.snapshot)
        #expect(try await backend.currentSlip() == s.draw)
    }
}
