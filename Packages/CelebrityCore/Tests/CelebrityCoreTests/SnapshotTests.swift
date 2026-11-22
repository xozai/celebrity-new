import Foundation
import Testing
import CelebrityCore

func fixture() throws -> RoomSnapshot {
    let url = try #require(Bundle.module.url(forResource: "snapshot", withExtension: "json", subdirectory: "Fixtures"))
    return try RoomSnapshot.makeDecoder().decode(RoomSnapshot.self, from: Data(contentsOf: url))
}

@Test func snapshotDecodesSnakeCaseFixture() throws {
    let snapshot = try fixture()
    #expect(snapshot.room.phase == .playing)
    #expect(snapshot.room.settings.skipMode == .onePerTurn)
    #expect(!snapshot.room.settings.suggestionsEnabled)
    #expect(snapshot.room.turnEndsAt == nil)
    #expect(snapshot.room.finishedAt == nil)
    #expect(snapshot.room.submissionDeadline != nil)
    #expect(snapshot.room.scores == [[2, 0], [0, 0], [0, 0]])
    #expect(snapshot.players.last?.role == .spectator)
    #expect(snapshot.players.last?.team == nil)
    #expect(snapshot.turns.first?.guessed == ["Beyoncé", "Beyoncé"])
    let turn = try #require(snapshot.turns.first)
    #expect(turn.playerID == nil)
    #expect(turn.playerName == "Former player")
    #expect(turn.skipped == 1)
    let end = turn.endedAt
    #expect(abs(snapshot.serverNow.timeIntervalSince(end) - 0.123456) < 0.000001)
}

@Test func snapshotRoundTripsWithWireTimestampCodec() throws {
    var snapshot = try fixture()
    snapshot.room.phase = .finished
    snapshot.room.finishedAt = snapshot.serverNow
    let data = try RoomSnapshot.makeEncoder().encode(snapshot)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(json.keys) == ["room", "players", "turns", "server_now"])
    #expect(json["server_now"] is String)
    let room = try #require(json["room"] as? [String: Any])
    #expect(room["suggestions_enabled"] as? Bool == false)
    #expect(room["finished_at"] is String)
    #expect(try RoomSnapshot.makeDecoder().decode(RoomSnapshot.self, from: data) == snapshot)
}

@Test func decodesCapturedPostgreSQLSnapshot() throws {
    let url = try #require(Bundle.module.url(forResource: "snapshot.example", withExtension: "json", subdirectory: "Fixtures"))
    let snapshot = try RoomSnapshot.makeDecoder().decode(RoomSnapshot.self, from: Data(contentsOf: url))
    let turn = try #require(snapshot.turns.first)
    #expect(turn.id == 36)
    #expect(turn.skipped == 1)
    #expect(turn.guessed == ["Sherlock Holmes", "Beyoncé"])
    #expect(snapshot.players.map(\.seat) == [1, 2, 3, 4])
    #expect(snapshot.room.settings.suggestionsEnabled)
    #expect(snapshot.room.phase == .playing)
    #expect(snapshot.room.submissionDeadline != nil)
    #expect(snapshot.nextUp?.name == "Cy")
    #expect(snapshot.teamTotals == [2, 1])
    #expect(abs(snapshot.serverNow.timeIntervalSince(turn.endedAt) - 0.005600) < 0.000001)
}

@Test func decodesSnapshotWithNoAssignedHost() throws {
    let url = try #require(Bundle.module.url(forResource: "snapshot.example", withExtension: "json", subdirectory: "Fixtures"))
    var wire = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var room = try #require(wire["room"] as? [String: Any])
    room["host_id"] = NSNull()
    wire["room"] = room

    let snapshot = try RoomSnapshot.makeDecoder().decode(RoomSnapshot.self, from: JSONSerialization.data(withJSONObject: wire))
    #expect(snapshot.room.hostID == nil)
    let player = try #require(snapshot.players.first)
    #expect(!snapshot.isHost(userID: player.userID))
}
