import Foundation

public struct Turn: Codable, Sendable, Equatable {
    public var id: Int64
    public var roomID: UUID
    public var round: Int
    public var team: Int
    public var playerID: UUID?
    public var playerName: String
    public var guessed: [String]
    public var skipped: Int
    public var endedAt: Date

    public init(
        id: Int64,
        roomID: UUID,
        round: Int,
        team: Int,
        playerID: UUID?,
        playerName: String,
        guessed: [String],
        skipped: Int,
        endedAt: Date
    ) {
        self.id = id
        self.roomID = roomID
        self.round = round
        self.team = team
        self.playerID = playerID
        self.playerName = playerName
        self.guessed = guessed
        self.skipped = skipped
        self.endedAt = endedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case roomID = "room_id"
        case round
        case team
        case playerID = "player_id"
        case playerName = "player_name"
        case guessed
        case skipped
        case endedAt = "ended_at"
    }
}
