import CelebrityCore
import Foundation
import Testing
@testable import CelebrityBackend

@Suite struct GameBackendTypesTests {
    @Test func drawDecodesServerShape() throws {
        let json = #"{"id":"11111111-1111-1111-1111-111111111111","name":"Beyoncé","token":"22222222-2222-2222-2222-222222222222"}"#
        let draw = try JSONDecoder().decode(Draw.self, from: Data(json.utf8))
        #expect(draw.name == "Beyoncé")
        #expect(draw.id == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(draw.token == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let again = try JSONDecoder().decode(Draw.self, from: JSONEncoder().encode(draw))
        #expect(again == draw)
    }

    @Test func drawsFromTheSameSlipWithDifferentTokensDiffer() {
        let slip = UUID()
        #expect(Draw(id: slip, name: "A", token: UUID()) != Draw(id: slip, name: "A", token: UUID()))
    }

    @Test func suggestionDecodesRowShape() throws {
        let json = #"[{"name":"Tom Hanks","description":"American actor","category":"film_tv","sources":["wikipedia","imdb"]}]"#
        let rows = try JSONDecoder().decode([CelebritySuggestion].self, from: Data(json.utf8))
        #expect(rows == [CelebritySuggestion(name: "Tom Hanks", description: "American actor", category: .filmTV, sources: ["wikipedia", "imdb"])])
        #expect(rows[0].id == "Tom Hanks")
    }

    @Test func suggestionToleratesNullDescriptionAndUnknownCategory() throws {
        let json = #"{"name":"X","description":null,"category":"brand_new","sources":[]}"#
        let row = try JSONDecoder().decode(CelebritySuggestion.self, from: Data(json.utf8))
        #expect(row.description == "")
        #expect(row.category == .other)
    }

    @Test func categoriesMatchServerValues() {
        #expect(CelebrityCategory.allCases.map(\.rawValue) == ["film_tv", "music", "sports", "public_figure", "fictional", "other"])
    }

    @Test func settingsUpdateEncodesOnlyChangedKeys() throws {
        let update = SettingsUpdate(turnSeconds: 90, skipMode: .onePerTurn)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any])
        #expect(Set(object.keys) == ["turn_seconds", "skip_mode"])
        #expect(object["turn_seconds"] as? Int == 90)
        #expect(object["skip_mode"] as? String == "one_per_turn")
        #expect(!update.isEmpty)
        #expect(SettingsUpdate().isEmpty)
    }

    @Test func roomUpdateIsAValueType() {
        #expect(RoomUpdate.lost(.removed) == .lost(.removed))
        #expect(RoomUpdate.lost(.removed) != .lost(.roomDeleted))
        let snap = SampleScenario.make(.lobbyHost, now: Date(timeIntervalSinceReferenceDate: 1)).snapshot
        #expect(RoomUpdate.snapshot(snap) == .snapshot(snap))
        #expect(RoomUpdate.snapshot(snap) != .lost(.left))
    }

    @Test func nullDrawDecodesAsNil() throws {
        let draw = try JSONDecoder().decode(Draw?.self, from: Data("null".utf8))
        #expect(draw == nil)
        let present = try JSONDecoder().decode(Draw?.self, from: Data(#"{"id":"11111111-1111-1111-1111-111111111111","name":"X","token":"22222222-2222-2222-2222-222222222222"}"#.utf8))
        #expect(present?.name == "X")
    }

    @Test func heartbeatScalarDecodesWithTheSnapshotDateStrategy() throws {
        let decoder = RoomSnapshot.makeDecoder()
        let micro = try decoder.decode(Date.self, from: Data(#""2026-11-22T18:14:20.22535+00:00""#.utf8))
        let whole = try decoder.decode(Date.self, from: Data(#""2026-11-22T18:14:20+00:00""#.utf8))
        #expect(abs(micro.timeIntervalSince(whole) - 0.22535) < 0.0001)
    }

    @Test func connectionStateFlags() {
        #expect(ConnectionState.connected.isConnected)
        #expect(!ConnectionState.reconnecting.isConnected)
        #expect(!ConnectionState.disconnected.isConnected)
    }
}
