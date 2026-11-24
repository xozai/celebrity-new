import Foundation
import Testing
@testable import CelebrityBackend

@Suite struct TeamAssignmentsTests {
    private let a = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
    private let b = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
    private let c = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!

    @Test func encodesAnObjectWithAssignmentExplicitNullAndOmission() throws {
        var assignments = TeamAssignments()
        assignments.assign(.team(1), to: a)
        assignments.assign(.unassigned, to: b)
        let data = try assignments.wireJSON()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == [a.uuidString.lowercased(), b.uuidString.lowercased()])
        #expect(object[a.uuidString.lowercased()] as? Int == 1)
        #expect(object[b.uuidString.lowercased()] is NSNull)
        #expect(object[c.uuidString.lowercased()] == nil)
        // The server needs a top-level object, never a key/value array.
        #expect(String(decoding: data, as: UTF8.self).hasPrefix("{"))
    }

    @Test func team0IsEncodedAsZeroNotNull() throws {
        let data = try TeamAssignments([a: .team(0)]).wireJSON()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object[a.uuidString.lowercased()] as? Int == 0)
    }

    @Test func emptyEncodesAsEmptyObject() throws {
        #expect(String(decoding: try TeamAssignments().wireJSON(), as: UTF8.self) == "{}")
        #expect(TeamAssignments().isEmpty)
    }

    @Test func laterAssignmentReplacesEarlier() {
        var assignments = TeamAssignments([a: .team(0)])
        assignments.assign(.unassigned, to: a)
        #expect(assignments[a] == .unassigned)
        #expect(assignments[b] == nil)
        #expect(assignments.userIDs == [a])
    }

    @Test func dictionaryLiteralAndEquality() {
        let literal: TeamAssignments = [a: .team(0), b: .unassigned]
        #expect(literal == TeamAssignments([a: .team(0), b: .unassigned]))
        #expect(literal != TeamAssignments([a: .team(1), b: .unassigned]))
    }

    @Test func roundTripsThroughTheWireFormat() throws {
        let original: TeamAssignments = [a: .team(1), b: .unassigned, c: .team(0)]
        let decoded = try JSONDecoder().decode(TeamAssignments.self, from: original.wireJSON())
        #expect(decoded == original)
    }
}
