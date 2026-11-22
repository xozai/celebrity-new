import Foundation

public struct Settings: Codable, Sendable, Equatable {
    public var slipsPerPlayer: Int
    public var turnSeconds: Int
    public var submissionSeconds: Int
    public var skipMode: SkipMode
    public var suggestionsEnabled: Bool

    public init(
        slipsPerPlayer: Int,
        turnSeconds: Int,
        submissionSeconds: Int,
        skipMode: SkipMode,
        suggestionsEnabled: Bool
    ) {
        self.slipsPerPlayer = slipsPerPlayer
        self.turnSeconds = turnSeconds
        self.submissionSeconds = submissionSeconds
        self.skipMode = skipMode
        self.suggestionsEnabled = suggestionsEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case slipsPerPlayer = "slips_per_player"
        case turnSeconds = "turn_seconds"
        case submissionSeconds = "submission_seconds"
        case skipMode = "skip_mode"
        case suggestionsEnabled = "suggestions_enabled"
    }
}

public enum SkipMode: String, Codable, Sendable {
    case off
    case onePerTurn = "one_per_turn"
    case unlimited
}
