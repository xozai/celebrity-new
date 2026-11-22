import Foundation

public struct Room: Codable, Sendable, Equatable {
    public var id: UUID
    public var code: String
    public var hostID: UUID?
    public var phase: RoomPhase
    public var round: Int
    public var teamNames: [String]
    public var settings: Settings
    public var submissionDeadline: Date?
    public var currentTeam: Int?
    public var turnIdx: [Int]
    public var turnPlayerID: UUID?
    public var turnEndsAt: Date?
    public var turnGot: Int
    public var turnSkips: Int
    public var pileCount: Int
    public var scores: [[Int]]
    public var lastActivityAt: Date
    public var createdAt: Date
    public var finishedAt: Date?

    public init(
        id: UUID,
        code: String,
        hostID: UUID?,
        phase: RoomPhase,
        round: Int,
        teamNames: [String],
        settings: Settings,
        submissionDeadline: Date?,
        currentTeam: Int?,
        turnIdx: [Int],
        turnPlayerID: UUID?,
        turnEndsAt: Date?,
        turnGot: Int,
        turnSkips: Int,
        pileCount: Int,
        scores: [[Int]],
        lastActivityAt: Date,
        createdAt: Date,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.code = code
        self.hostID = hostID
        self.phase = phase
        self.round = round
        self.teamNames = teamNames
        self.settings = settings
        self.submissionDeadline = submissionDeadline
        self.currentTeam = currentTeam
        self.turnIdx = turnIdx
        self.turnPlayerID = turnPlayerID
        self.turnEndsAt = turnEndsAt
        self.turnGot = turnGot
        self.turnSkips = turnSkips
        self.pileCount = pileCount
        self.scores = scores
        self.lastActivityAt = lastActivityAt
        self.createdAt = createdAt
        self.finishedAt = finishedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case code
        case hostID = "host_id"
        case phase
        case round
        case teamNames = "team_names"
        case submissionDeadline = "submission_deadline"
        case currentTeam = "current_team"
        case turnIdx = "turn_idx"
        case turnPlayerID = "turn_player_id"
        case turnEndsAt = "turn_ends_at"
        case turnGot = "turn_got"
        case turnSkips = "turn_skips"
        case pileCount = "pile_count"
        case scores
        case lastActivityAt = "last_activity_at"
        case createdAt = "created_at"
        case finishedAt = "finished_at"
        case slipsPerPlayer = "slips_per_player"
        case turnSeconds = "turn_seconds"
        case submissionSeconds = "submission_seconds"
        case skipMode = "skip_mode"
        case suggestionsEnabled = "suggestions_enabled"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        code = try values.decode(String.self, forKey: .code)
        hostID = try values.decodeIfPresent(UUID.self, forKey: .hostID)
        phase = try values.decode(RoomPhase.self, forKey: .phase)
        round = try values.decode(Int.self, forKey: .round)
        teamNames = try values.decode([String].self, forKey: .teamNames)
        settings = Settings(
            slipsPerPlayer: try values.decode(Int.self, forKey: .slipsPerPlayer),
            turnSeconds: try values.decode(Int.self, forKey: .turnSeconds),
            submissionSeconds: try values.decode(Int.self, forKey: .submissionSeconds),
            skipMode: try values.decode(SkipMode.self, forKey: .skipMode),
            suggestionsEnabled: try values.decode(Bool.self, forKey: .suggestionsEnabled)
        )
        submissionDeadline = try values.decodeIfPresent(Date.self, forKey: .submissionDeadline)
        currentTeam = try values.decodeIfPresent(Int.self, forKey: .currentTeam)
        turnIdx = try values.decode([Int].self, forKey: .turnIdx)
        turnPlayerID = try values.decodeIfPresent(UUID.self, forKey: .turnPlayerID)
        turnEndsAt = try values.decodeIfPresent(Date.self, forKey: .turnEndsAt)
        turnGot = try values.decode(Int.self, forKey: .turnGot)
        turnSkips = try values.decode(Int.self, forKey: .turnSkips)
        pileCount = try values.decode(Int.self, forKey: .pileCount)
        scores = try values.decode([[Int]].self, forKey: .scores)
        lastActivityAt = try values.decode(Date.self, forKey: .lastActivityAt)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        finishedAt = try values.decodeIfPresent(Date.self, forKey: .finishedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(code, forKey: .code)
        try values.encode(hostID, forKey: .hostID)
        try values.encode(phase, forKey: .phase)
        try values.encode(round, forKey: .round)
        try values.encode(teamNames, forKey: .teamNames)
        try values.encode(submissionDeadline, forKey: .submissionDeadline)
        try values.encode(currentTeam, forKey: .currentTeam)
        try values.encode(turnIdx, forKey: .turnIdx)
        try values.encode(turnPlayerID, forKey: .turnPlayerID)
        try values.encode(turnEndsAt, forKey: .turnEndsAt)
        try values.encode(turnGot, forKey: .turnGot)
        try values.encode(turnSkips, forKey: .turnSkips)
        try values.encode(pileCount, forKey: .pileCount)
        try values.encode(scores, forKey: .scores)
        try values.encode(lastActivityAt, forKey: .lastActivityAt)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(finishedAt, forKey: .finishedAt)
        try values.encode(settings.slipsPerPlayer, forKey: .slipsPerPlayer)
        try values.encode(settings.turnSeconds, forKey: .turnSeconds)
        try values.encode(settings.submissionSeconds, forKey: .submissionSeconds)
        try values.encode(settings.skipMode, forKey: .skipMode)
        try values.encode(settings.suggestionsEnabled, forKey: .suggestionsEnabled)
    }
}

public enum RoomPhase: String, Codable, Sendable {
    case lobby
    case submitting
    case playing
    case roundEnd = "round_end"
    case finished
}
