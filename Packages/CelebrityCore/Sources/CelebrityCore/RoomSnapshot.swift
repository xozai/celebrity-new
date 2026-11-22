import Foundation

public struct RoomSnapshot: Codable, Sendable, Equatable {
    public var room: Room
    public var players: [Player]
    public var turns: [Turn]
    public var serverNow: Date

    public init(
        room: Room,
        players: [Player],
        turns: [Turn],
        serverNow: Date
    ) {
        self.room = room
        self.players = players
        self.turns = turns
        self.serverNow = serverNow
    }

    private enum CodingKeys: String, CodingKey {
        case room
        case players
        case turns
        case serverNow = "server_now"
    }

    /// Creates a decoder for PostgreSQL timestamps with or without fractional seconds.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            let timestamp = try value.decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(timestamp) {
                return date
            }
            if let date = try? Date.ISO8601FormatStyle().parse(timestamp) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid ISO 8601 timestamp")
        }
        return decoder
    }

    /// Creates an encoder that writes ISO 8601 timestamps with fractional seconds.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let interval = date.timeIntervalSinceReferenceDate
            guard interval.isFinite else {
                throw EncodingError.invalidValue(date, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Invalid ISO 8601 timestamp"
                ))
            }

            // Foundation's ISO 8601 formatter can truncate fractional seconds to milliseconds.
            let seconds = interval.rounded(.down)
            let nanosecondsPerSecond = 1_000_000_000
            let nanoseconds = Int(((interval - seconds) * Double(nanosecondsPerSecond)).rounded())
            let wholeDate = Date(timeIntervalSinceReferenceDate: seconds + Double(nanoseconds / nanosecondsPerSecond))
            let wholeTimestamp = Date.ISO8601FormatStyle().format(wholeDate)
            let fraction = String(format: "%09d", nanoseconds % nanosecondsPerSecond)
            var value = encoder.singleValueContainer()
            try value.encode("\(wholeTimestamp.dropLast()).\(fraction)Z")
        }
        return encoder
    }
}

extension RoomSnapshot {
    public func me(userID: UUID) -> Player? {
        players.first { $0.userID == userID }
    }

    public func isHost(userID: UUID) -> Bool {
        room.hostID == userID
    }

    public func isClueGiver(userID: UUID) -> Bool {
        nextUp?.userID == userID
    }

    public func isSpectator(userID: UUID) -> Bool {
        me(userID: userID)?.role == .spectator
    }

    public var teamTotals: [Int] {
        (0..<2).map { team in
            room.scores.reduce(0) { total, round in
                total + (round.indices.contains(team) ? round[team] : 0)
            }
        }
    }

    /// The winning team index once the game has finished, or nil for a tie.
    public var winner: Int? {
        guard room.phase == .finished else { return nil }
        let totals = teamTotals
        guard totals[0] != totals[1] else { return nil }
        return totals[0] > totals[1] ? 0 : 1
    }

    public func canStartGame(userID: UUID) -> (allowed: Bool, reason: String?) {
        guard isHost(userID: userID) else { return (false, "Only the host can start the game.") }
        guard room.phase == .lobby else { return (false, "The room must be in the lobby.") }
        let hasEnoughPlayers = (0..<2).allSatisfy { team in
            players.filter { $0.role == .player && $0.team == team }.count >= 2
        }
        guard hasEnoughPlayers else { return (false, "Each team needs at least two players.") }
        return (true, nil)
    }

    /// The clue-giver assigned by the server for the current or upcoming turn.
    /// Returns nil during play if neither team can field the minimum roster.
    public var nextUp: Player? {
        guard room.phase == .playing, let userID = room.turnPlayerID else { return nil }
        return me(userID: userID)
    }
}
