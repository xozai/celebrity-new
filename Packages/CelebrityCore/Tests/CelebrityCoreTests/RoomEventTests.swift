import Foundation
import Testing
import CelebrityCore

private enum Transition: CaseIterable {
    case firstRound, nextRound, turnStarts, turnEnds, roundEnds, gameEnds
    case kicked, hostChanged, timeout, identical, clockOnly, initial, differentRoom
}

@Test(arguments: Transition.allCases)
private func derivesEvents(transition: Transition) throws {
    var old = try fixture()
    var new = old
    let userID = try #require(old.room.hostID)
    let turn = try #require(old.turns.first)
    let expected: [RoomEvent]

    switch transition {
    case .firstRound:
        old.room.phase = .submitting
        old.room.round = 0
        old.room.submissionDeadline = old.serverNow.addingTimeInterval(10)
        expected = [.roundStarting]
    case .nextRound:
        old.room.phase = .roundEnd
        new.room.round = 2
        expected = [.roundStarting]
    case .turnStarts:
        new.room.turnEndsAt = new.serverNow.addingTimeInterval(60)
        expected = [.turnStarted]
    case .turnEnds:
        old.turns = []
        old.room.turnEndsAt = turn.endedAt
        expected = [.turnEnded(turn)]
    case .roundEnds:
        old.turns = []
        new.room.phase = .roundEnd
        expected = [.turnEnded(turn), .roundEnded]
    case .gameEnds:
        old.turns = []
        old.room.round = 3
        new.room.round = 3
        new.room.phase = .finished
        expected = [.turnEnded(turn), .gameEnded]
    case .kicked:
        new.players.removeAll { $0.userID == userID }
        new.room.hostID = new.players[0].userID
        expected = [.kicked]
    case .hostChanged:
        new.room.hostID = new.players[1].userID
        expected = [.hostChanged]
    case .timeout:
        old.room.phase = .submitting
        old.room.round = 0
        old.room.submissionDeadline = old.serverNow
        new.players[2].submitted = false
        expected = [.submissionsAutoClosed, .roundStarting]
    case .identical, .initial:
        expected = []
    case .clockOnly:
        new.serverNow = new.serverNow.addingTimeInterval(5)
        expected = []
    case .differentRoom:
        new.room.id = UUID()
        expected = []
    }

    #expect(RoomEventDeriver.events(old: transition == .initial ? nil : old, new: new, userID: userID) == expected)
}

@Test func coalescedTurnHistoryIsEmittedChronologicallyAndOnlyOnce() throws {
    let old = try fixture()
    var new = old
    var first = try #require(old.turns.first)
    first.id += 1
    first.endedAt = new.serverNow
    var second = first
    second.id += 1
    second.endedAt = first.endedAt.addingTimeInterval(1)
    new.turns = [second] + old.turns + [first]
    new.room.turnEndsAt = new.serverNow.addingTimeInterval(60)
    #expect(RoomEventDeriver.events(old: old, new: new, userID: try #require(old.room.hostID)) == [
        .turnEnded(first), .turnEnded(second), .turnStarted,
    ])
}

@Test func completeSubmissionsAtDeadlineDoNotImplyTimeout() throws {
    var old = try fixture()
    let new = old
    old.room.phase = .submitting
    old.room.round = 0
    old.room.submissionDeadline = new.serverNow
    #expect(RoomEventDeriver.events(old: old, new: new, userID: try #require(old.room.hostID)) == [.roundStarting])
}

@Test func stalledRoomDoesNotStartATurnUntilServerAssignsAClueGiver() throws {
    let old = try fixture()
    var stalled = old
    stalled.room.turnPlayerID = nil
    let userID = try #require(old.room.turnPlayerID)
    #expect(stalled.nextUp == nil)
    #expect(!stalled.isClueGiver(userID: userID))
    #expect(RoomEventDeriver.events(old: old, new: stalled, userID: userID) == [])

    var waiting = stalled
    waiting.room.turnPlayerID = userID
    #expect(RoomEventDeriver.events(old: stalled, new: waiting, userID: userID) == [])

    var playing = waiting
    playing.room.turnEndsAt = playing.serverNow.addingTimeInterval(60)
    #expect(RoomEventDeriver.events(old: waiting, new: playing, userID: userID) == [.turnStarted])
}

@Test func anonymizingAnExistingTurnDoesNotReplayItsRecap() throws {
    var old = try fixture()
    let userID = try #require(old.room.hostID)
    old.turns[0].playerID = userID
    old.turns[0].playerName = "Alex"
    let anonymized = try fixture()
    #expect(RoomEventDeriver.events(old: old, new: anonymized, userID: userID) == [])
}
