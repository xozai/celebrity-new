import Foundation

public struct Player: Codable, Sendable, Equatable {
    public var roomID: UUID
    public var userID: UUID
    public var name: String
    public var team: Int?
    public var role: PlayerRole
    public var seat: Int
    public var submitted: Bool
    public var lastSeenAt: Date

    public init(
        roomID: UUID,
        userID: UUID,
        name: String,
        team: Int?,
        role: PlayerRole,
        seat: Int,
        submitted: Bool,
        lastSeenAt: Date
    ) {
        self.roomID = roomID
        self.userID = userID
        self.name = name
        self.team = team
        self.role = role
        self.seat = seat
        self.submitted = submitted
        self.lastSeenAt = lastSeenAt
    }

    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case userID = "user_id"
        case name
        case team
        case role
        case seat
        case submitted
        case lastSeenAt = "last_seen_at"
    }
}

public enum PlayerRole: String, Codable, Sendable {
    case player
    case spectator
}
