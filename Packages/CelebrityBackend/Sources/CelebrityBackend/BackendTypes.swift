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

/// The state of the live room channel, published on ``GameBackend/connection``.
///
/// It describes **the live channel of the room being observed**, not general reachability. Without an observed room the
/// state is ``idle``, whatever the network is doing. Screens show a "reconnecting" banner only when
/// ``showsReconnectingBanner`` is true (``reconnecting`` or ``disconnected``); ``idle`` and ``connecting`` show nothing.
public enum ConnectionState: Sendable, Equatable {
    /// No room is being observed. This is the state before any observation, after a loss, leave or delete, and after the
    /// last observer cancels.
    case idle
    /// The first join of an observed room's channel is in progress.
    case connecting
    /// The room's channel is joined and snapshots are flowing.
    case connected
    /// The channel dropped (or a refresh failed on the network) and the backend is retrying. Show a non-blocking banner.
    case reconnecting
    /// A room is observed but its channel is down and the backend is not currently retrying. Show the banner.
    case disconnected

    /// True only for ``connected``.
    public var isConnected: Bool { self == .connected }

    /// True for ``reconnecting`` and ``disconnected``: show the non-blocking reconnecting banner.
    public var showsReconnectingBanner: Bool { self == .reconnecting || self == .disconnected }
}

/// Why a room observation ended. Delivered as the last element of ``GameBackend/observeRoom(roomID:)``.
public enum RoomLossReason: Sendable, Equatable {
    /// A refresh of the room failed with `not_member`: the player was kicked or otherwise removed, or the room
    /// no longer exists and the server cannot tell the difference. This is also what a stale persisted room id
    /// produces on the first refresh. Alert the player and return Home.
    case removed
    /// A `room_deleted` event was seen first, so the room is known to be closed. Return Home.
    case roomDeleted
    /// The app itself left the room: ``GameBackend/leaveRoom()``, or ``GameBackend/createRoom(name:)`` /
    /// ``GameBackend/joinRoom(code:name:)`` moved the caller into another room. Expected; do not alert.
    case left
    /// The session ended under the observation: ``GameBackend/deleteMyData()`` or a sign-out or session replacement.
    /// Expected when the app caused it; otherwise treat like ``removed``.
    /// Also the outcome when the session is invalid or deleted and one recovery attempt (token refresh, then a fresh
    /// anonymous sign-in is the app's job) failed.
    case sessionEnded
    /// A refresh failed permanently and retrying cannot help (permission denied, an undecodable response, any other
    /// non-network error). The observation is over; show the error and leave the room's loading state.
    case failed(BackendError)
}

/// One element of a room observation (``GameBackend/observeRoom(roomID:)``).
public enum RoomUpdate: Sendable, Equatable {
    /// The room's latest state.
    case snapshot(RoomSnapshot)
    /// The observation is over for this reason. It is always the last element; the stream finishes after it.
    case lost(RoomLossReason)
}

/// How a scripted transition changes the clue-giver's private draw, in the same commit as its snapshot.
public enum DrawUpdate: Sendable, Equatable {
    /// Leave the draw as it is (for a drawing call, take the next one from the draw queue).
    case unchanged
    /// The private draw is gone (turn ended, role lost, round over).
    case clear
    /// This is now the private draw (and the result of a drawing call such as Start Turn).
    case set(Draw)
}

/// One scripted server step for ``FakeGameBackend/script(_:transitions:)``: a snapshot and what happens to the private draw.
public struct ScriptedTransition: Sendable, Equatable {
    /// The snapshot that becomes current.
    public var snapshot: RoomSnapshot
    /// The change to the private draw, committed together with the snapshot.
    public var draw: DrawUpdate

    /// Creates a transition.
    /// - Parameters:
    ///   - snapshot: The new state.
    ///   - draw: The draw change. Defaults to unchanged.
    public init(snapshot: RoomSnapshot, draw: DrawUpdate = .unchanged) {
        self.snapshot = snapshot
        self.draw = draw
    }
}

/// A partial update for ``GameBackend/updateSettings(_:)``. Only non-nil fields are sent.
///
/// The server accepts: slips per player 1-10; turn length 30, 60 or 90 seconds; submission window 30-600 seconds;
/// any ``SkipMode``; either value of the recommendations switch. Anything else fails with `invalid_setting`.
public struct SettingsUpdate: Codable, Sendable, Equatable {
    /// New slips per player (1-10), or nil to leave unchanged.
    public var slipsPerPlayer: Int?
    /// New turn length in seconds (30, 60 or 90), or nil to leave unchanged.
    public var turnSeconds: Int?
    /// New submission window in seconds (30-600), or nil to leave unchanged.
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
