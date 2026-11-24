import CelebrityCore
import Foundation

/// A slip drawn from the pile. Only the clue-giver ever receives one.
///
/// Each draw has a fresh ``token``, even when skipping the last slip redraws the same slip.
/// Send the token of the draw currently on screen with ``GameBackend/gotIt(token:)`` and
/// ``GameBackend/skip(token:)``. Keep draws out of shared state such as snapshots and recaps.
public struct Draw: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// The slip's identifier. Stable across redraws of the same slip.
    public var id: UUID
    /// The celebrity name on the slip.
    public var name: String
    /// Identifies this particular draw. Required by Got It and Skip.
    public var token: UUID

    /// Creates a draw.
    /// - Parameters:
    ///   - id: The slip identifier.
    ///   - name: The celebrity name.
    ///   - token: The draw token.
    public init(id: UUID, name: String, token: UUID) {
        self.id = id
        self.name = name
        self.token = token
    }
}

/// The state of the backend's live connection, published on ``GameBackend/connection``.
public enum ConnectionState: Sendable, Equatable {
    /// The first connection is being made.
    case connecting
    /// The live channel is joined and snapshots are flowing.
    case connected
    /// The connection dropped and the backend is retrying. Show a non-blocking banner.
    case reconnecting
    /// No connection and none being attempted (for example before sign-in or after leaving).
    case disconnected

    /// True only for ``connected``.
    public var isConnected: Bool { self == .connected }
}

/// Reported on ``GameBackend/roomLosses`` when the current room is gone for the caller.
public struct RoomLoss: Sendable, Equatable {
    /// Why the room was lost.
    public enum Reason: Sendable, Equatable {
        /// A refresh of the room failed with `not_member`: the player was kicked or removed.
        case removed
        /// A `room_deleted` event was seen first, so the room no longer exists.
        case roomDeleted
    }

    /// The room that was lost.
    public var roomID: UUID
    /// Why it was lost.
    public var reason: Reason

    /// Creates a room-loss report.
    /// - Parameters:
    ///   - roomID: The room that was lost.
    ///   - reason: Why it was lost.
    public init(roomID: UUID, reason: Reason) {
        self.roomID = roomID
        self.reason = reason
    }
}

/// A partial update for ``GameBackend/updateSettings(_:)``. Only non-nil fields are sent.
public struct SettingsUpdate: Codable, Sendable, Equatable {
    /// New slips per player (1-10), or nil to leave unchanged.
    public var slipsPerPlayer: Int?
    /// New turn length in seconds, or nil to leave unchanged.
    public var turnSeconds: Int?
    /// New submission window in seconds, or nil to leave unchanged.
    public var submissionSeconds: Int?
    /// New skip mode, or nil to leave unchanged.
    public var skipMode: SkipMode?
    /// Whether recommendations are on, or nil to leave unchanged.
    public var suggestionsEnabled: Bool?

    /// Creates an update. Pass only the fields to change.
    /// - Parameters:
    ///   - slipsPerPlayer: New slips per player.
    ///   - turnSeconds: New turn length.
    ///   - submissionSeconds: New submission window.
    ///   - skipMode: New skip mode.
    ///   - suggestionsEnabled: New recommendations switch.
    public init(
        slipsPerPlayer: Int? = nil,
        turnSeconds: Int? = nil,
        submissionSeconds: Int? = nil,
        skipMode: SkipMode? = nil,
        suggestionsEnabled: Bool? = nil
    ) {
        self.slipsPerPlayer = slipsPerPlayer
        self.turnSeconds = turnSeconds
        self.submissionSeconds = submissionSeconds
        self.skipMode = skipMode
        self.suggestionsEnabled = suggestionsEnabled
    }

    /// True when no field is set.
    public var isEmpty: Bool {
        slipsPerPlayer == nil && turnSeconds == nil && submissionSeconds == nil
            && skipMode == nil && suggestionsEnabled == nil
    }

    private enum CodingKeys: String, CodingKey {
        case slipsPerPlayer = "slips_per_player"
        case turnSeconds = "turn_seconds"
        case submissionSeconds = "submission_seconds"
        case skipMode = "skip_mode"
        case suggestionsEnabled = "suggestions_enabled"
    }
}

/// A broad kind of celebrity, as classified by the recommendation list.
public enum CelebrityCategory: String, Codable, Sendable, CaseIterable {
    /// Film and TV people.
    case filmTV = "film_tv"
    /// Musicians.
    case music
    /// Athletes.
    case sports
    /// Politicians, historical figures and similar.
    case publicFigure = "public_figure"
    /// Fictional characters.
    case fictional
    /// Anything else, and any value this app version does not know.
    case other

    /// Decodes a category, mapping unknown server values to ``other``.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CelebrityCategory(rawValue: raw) ?? .other
    }
}

/// A recommended celebrity name from `suggest_celebrities` or `random_celebrities`.
public struct CelebritySuggestion: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// The display name. Also the identity: names are unique in the list.
    public var name: String
    /// A short description such as "American actor". Empty when the server has none.
    public var description: String
    /// The kind of celebrity.
    public var category: CelebrityCategory
    /// Where the name came from (`wikipedia`, `imdb`).
    public var sources: [String]

    /// Same as ``name``.
    public var id: String { name }

    /// Creates a suggestion.
    /// - Parameters:
    ///   - name: The display name.
    ///   - description: A short description.
    ///   - category: The kind of celebrity.
    ///   - sources: Source identifiers.
    public init(name: String, description: String, category: CelebrityCategory, sources: [String]) {
        self.name = name
        self.description = description
        self.category = category
        self.sources = sources
    }

    /// Decodes a server row, treating a null description or sources as empty.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        category = try values.decodeIfPresent(CelebrityCategory.self, forKey: .category) ?? .other
        sources = try values.decodeIfPresent([String].self, forKey: .sources) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, category, sources
    }
}
