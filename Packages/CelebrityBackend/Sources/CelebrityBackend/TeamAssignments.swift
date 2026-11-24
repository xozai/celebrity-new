import Foundation

/// Where one player goes in ``TeamAssignments``.
public enum TeamAssignment: Sendable, Equatable {
    /// Put the player on a team (0 or 1). Promotes a spectator to a player.
    case team(Int)
    /// Take the player off their team. On the wire this is an explicit JSON `null`.
    case unassigned
}

/// A partial team assignment for ``GameBackend/setTeams(_:)``: which players move, and where.
///
/// Players not listed stay where they are. Listing a player as ``TeamAssignment/unassigned`` is different from
/// not listing them, which a Swift dictionary with optional values cannot express. The wire form is the JSON object
/// `set_teams` expects: `{"<Player.userID>": 0 | 1 | null}`, keyed by lowercase UUID strings.
public struct TeamAssignments: Sendable, Equatable, Codable, ExpressibleByDictionaryLiteral {
    /// Player ids are the dictionary-literal keys.
    public typealias Key = UUID
    /// Destinations are the dictionary-literal values.
    public typealias Value = TeamAssignment

    private var entries: [UUID: TeamAssignment]

    /// Creates an assignment set.
    /// - Parameter entries: Player `userID` to destination.
    public init(_ entries: [UUID: TeamAssignment] = [:]) { self.entries = entries }

    /// Creates an assignment set from a dictionary literal, such as `[alex: .team(0), gray: .unassigned]`.
    public init(dictionaryLiteral elements: (UUID, TeamAssignment)...) {
        entries = Dictionary(elements, uniquingKeysWith: { _, last in last })
    }

    /// Sets where a player goes, replacing an earlier entry for the same player.
    /// - Parameters:
    ///   - assignment: The destination.
    ///   - userID: The player's `Player.userID`.
    public mutating func assign(_ assignment: TeamAssignment, to userID: UUID) { entries[userID] = assignment }

    /// The destination listed for a player, or nil if the player is not listed (and so stays put).
    public subscript(userID: UUID) -> TeamAssignment? { entries[userID] }

    /// The listed players.
    public var userIDs: Set<UUID> { Set(entries.keys) }

    /// True when no player is listed.
    public var isEmpty: Bool { entries.isEmpty }

    /// The JSON object to send as `p_assignments`.
    /// - Throws: An encoding error (not expected).
    public func wireJSON() throws -> Data { try JSONEncoder().encode(self) }

    private struct WireKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Encodes the wire object: lowercase UUID keys, `0`, `1` or `null` values.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        for (userID, assignment) in entries.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let key = WireKey(stringValue: userID.uuidString.lowercased())
            switch assignment {
            case .team(let team): try container.encode(team, forKey: key)
            case .unassigned: try container.encodeNil(forKey: key)
            }
        }
    }

    /// Decodes the wire object. Keys that are not UUIDs are an error.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        var result: [UUID: TeamAssignment] = [:]
        for key in container.allKeys {
            guard let userID = UUID(uuidString: key.stringValue) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Not a UUID")
            }
            result[userID] = try container.decodeNil(forKey: key) ? .unassigned : .team(container.decode(Int.self, forKey: key))
        }
        entries = result
    }
}
