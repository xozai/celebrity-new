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

    @Test func roomLossIsValueType() {
        let id = UUID()
        #expect(RoomLoss(roomID: id, reason: .removed) == RoomLoss(roomID: id, reason: .removed))
        #expect(RoomLoss(roomID: id, reason: .removed) != RoomLoss(roomID: id, reason: .roomDeleted))
    }

    @Test func connectionStateFlags() {
        #expect(ConnectionState.connected.isConnected)
        #expect(!ConnectionState.reconnecting.isConnected)
        #expect(!ConnectionState.disconnected.isConnected)
    }
}
