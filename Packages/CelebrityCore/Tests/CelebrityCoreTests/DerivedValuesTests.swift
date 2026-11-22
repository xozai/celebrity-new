import Testing
import CelebrityCore

@Test(arguments: [0, 1, 4, 5])
func derivesLocalPlayerRoles(index: Int) throws {
    let snapshot = try fixture()
    let player = snapshot.players.indices.contains(index) ? snapshot.players[index] : nil
    let id = player?.userID ?? snapshot.room.id
    #expect(snapshot.me(userID: id) == player)
    #expect(snapshot.isHost(userID: id) == (index == 0))
    #expect(snapshot.isClueGiver(userID: id) == (index == 1))
    #expect(snapshot.isSpectator(userID: id) == (index == 4))
}

@Test(arguments: [RoomPhase.lobby, .submitting, .playing, .roundEnd, .finished])
func nextUpUsesServerAssignment(phase: RoomPhase) throws {
    var snapshot = try fixture()
    snapshot.room.phase = phase
    #expect(snapshot.nextUp == (phase == .playing ? snapshot.players[1] : nil))
    snapshot.room.turnPlayerID = nil
    #expect(snapshot.nextUp == nil)
}

@Test(arguments: [([6, 4], 0), ([4, 6], 1), ([5, 5], nil)] as [([Int], Int?)])
func totalsAndWinner(totals: [Int], winner: Int?) throws {
    var snapshot = try fixture()
    snapshot.room.scores = [[2, 1], [1, 2], [totals[0] - 3, totals[1] - 3]]
    #expect(snapshot.teamTotals == totals)
    #expect(snapshot.winner == nil)
    snapshot.room.phase = .finished
    #expect(snapshot.winner == winner)
}

@Test(arguments: [
    (0, nil),
    (1, "The room must be in the lobby."),
    (2, "Each team needs at least two players."),
    (3, "Only the host can start the game."),
] as [(Int, String?)])
func hostStartEligibility(scenario: Int, reason: String?) throws {
    var snapshot = try fixture()
    snapshot.room.phase = scenario == 1 ? .playing : .lobby
    if scenario == 2 { snapshot.players[2].team = nil }
    let hostID = try #require(snapshot.room.hostID)
    let id = scenario == 3 ? snapshot.players[1].userID : hostID
    let eligibility = snapshot.canStartGame(userID: id)
    #expect(eligibility.allowed == (scenario == 0))
    #expect(eligibility.reason == reason)
}

@Test func unevenTeamsCanStartWithTwoPlayersOnEachTeam() throws {
    var snapshot = try fixture()
    snapshot.room.phase = .lobby
    snapshot.players[4].role = .player
    snapshot.players[4].team = 0
    #expect(snapshot.canStartGame(userID: try #require(snapshot.room.hostID)).allowed)
}
