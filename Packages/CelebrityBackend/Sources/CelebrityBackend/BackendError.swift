import Foundation

/// An error from a ``GameBackend`` call.
///
/// There is one case per domain error code that the database functions raise
/// (docs/PLAN.md section 6), plus ``network(_:)`` for transport failures and
/// ``unknown(_:)`` for anything unrecognised. Domain errors arrive from the server as
/// SQLSTATE `P0001` with the code in the message; use ``parse(message:sqlState:)`` to
/// turn that message into a case.
///
/// Show ``userMessage`` (or `localizedDescription`) to players. Never show ``code``.
public enum BackendError: Error, Sendable, Equatable, LocalizedError {
    /// `not_authenticated`: no session, or the account was deleted. Also used for SQLSTATE `42501`.
    case notAuthenticated
    /// `invalid_name`: a player, team or room name is empty or too long.
    case invalidName
    /// `rate_limited`: more than five rooms created in the last hour.
    case rateLimited
    /// `code_unavailable`: the server could not find a free room code.
    case codeUnavailable
    /// `room_not_found`: no room has that code.
    case roomNotFound
    /// `name_taken`: another player in the room already uses that name.
    case nameTaken
    /// `not_member`: the caller has no seat in the room. After a snapshot refresh of the
    /// current room this means the seat was lost; see ``isMembershipLoss``.
    case notMember
    /// `not_host`: only the host may do this.
    case notHost
    /// `wrong_phase`: the room is not in a phase that allows this action.
    case wrongPhase
    /// `invalid_team`: the team index is not 0 or 1.
    case invalidTeam
    /// `player_not_found`: the target is not in the room.
    case playerNotFound
    /// `invalid_setting`: a setting value is out of range.
    case invalidSetting
    /// `not_enough_players`: each team needs at least two players to start.
    case notEnoughPlayers
    /// `submissions_closed`: the submission window has ended.
    case submissionsClosed
    /// `not_a_player`: spectators and unassigned members cannot submit slips.
    case notAPlayer
    /// `already_submitted`: this player already submitted; retract first to change.
    case alreadySubmitted
    /// `wrong_slip_count`: the number of names differs from the slips-per-player setting.
    case wrongSlipCount
    /// `invalid_slip`: a slip name is empty or too long.
    case invalidSlip
    /// `deadline_not_reached`: `close_submissions` or `end_turn` was called too early.
    case deadlineNotReached
    /// `not_your_turn`: the caller is not the current clue-giver.
    case notYourTurn
    /// `turn_already_started`: the turn is already running.
    case turnAlreadyStarted
    /// `turn_not_started`: the clue-giver has not started the turn yet.
    case turnNotStarted
    /// `turn_over`: the turn timer has expired.
    case turnOver
    /// `invalid_token`: the draw token is missing or does not belong to the caller's draw.
    case invalidToken
    /// `skip_not_allowed`: skipping is off, or the one skip this turn is used.
    case skipNotAllowed
    /// `not_spectator`: the target of `assign_spectator` is not a spectator.
    case notSpectator
    /// `turn_active`: the action is not allowed while a turn is running.
    case turnActive
    /// `cannot_target_self`: the host cannot kick or transfer host to themselves.
    case cannotTargetSelf
    /// `already_host`: the caller already is the host.
    case alreadyHost
    /// `host_still_active`: the host was seen too recently to claim host.
    case hostStillActive
    /// A transport failure (offline, timeout, TLS). The associated text is for logs only.
    case network(String)
    /// Anything that is neither a known domain code nor a transport failure. The text is for logs only.
    case unknown(String)

    /// Every case that stands for a server domain code, in the order of docs/PLAN.md section 6.
    public static let domainCases: [BackendError] = [
        .notAuthenticated, .invalidName, .rateLimited, .codeUnavailable, .roomNotFound, .nameTaken,
        .notMember, .notHost, .wrongPhase, .invalidTeam, .playerNotFound, .invalidSetting,
        .notEnoughPlayers, .submissionsClosed, .notAPlayer, .alreadySubmitted, .wrongSlipCount,
        .invalidSlip, .deadlineNotReached, .notYourTurn, .turnAlreadyStarted, .turnNotStarted,
        .turnOver, .invalidToken, .skipNotAllowed, .notSpectator, .turnActive, .cannotTargetSelf,
        .alreadyHost, .hostStillActive,
    ]

    /// The server's error code (for example `"wrong_phase"`), or nil for ``network(_:)`` and ``unknown(_:)``.
    public var code: String? {
        switch self {
        case .notAuthenticated: "not_authenticated"
        case .invalidName: "invalid_name"
        case .rateLimited: "rate_limited"
        case .codeUnavailable: "code_unavailable"
        case .roomNotFound: "room_not_found"
        case .nameTaken: "name_taken"
        case .notMember: "not_member"
        case .notHost: "not_host"
        case .wrongPhase: "wrong_phase"
        case .invalidTeam: "invalid_team"
        case .playerNotFound: "player_not_found"
        case .invalidSetting: "invalid_setting"
        case .notEnoughPlayers: "not_enough_players"
        case .submissionsClosed: "submissions_closed"
        case .notAPlayer: "not_a_player"
        case .alreadySubmitted: "already_submitted"
        case .wrongSlipCount: "wrong_slip_count"
        case .invalidSlip: "invalid_slip"
        case .deadlineNotReached: "deadline_not_reached"
        case .notYourTurn: "not_your_turn"
        case .turnAlreadyStarted: "turn_already_started"
        case .turnNotStarted: "turn_not_started"
        case .turnOver: "turn_over"
        case .invalidToken: "invalid_token"
        case .skipNotAllowed: "skip_not_allowed"
        case .notSpectator: "not_spectator"
        case .turnActive: "turn_active"
        case .cannotTargetSelf: "cannot_target_self"
        case .alreadyHost: "already_host"
        case .hostStillActive: "host_still_active"
        case .network, .unknown: nil
        }
    }

    /// A short, player-facing sentence. Safe to show in an alert or banner.
    public var userMessage: String {
        switch self {
        case .notAuthenticated: "You're signed out. Please try again."
        case .invalidName: "That name isn't allowed. Try a different one."
        case .rateLimited: "You've created too many rooms. Try again later."
        case .codeUnavailable: "Couldn't make a room code. Please try again."
        case .roomNotFound: "No room has that code. Check it and try again."
        case .nameTaken: "Someone in that room already has that name."
        case .notMember: "You're no longer in this room."
        case .notHost: "Only the host can do that."
        case .wrongPhase: "That isn't possible at this point in the game."
        case .invalidTeam: "Choose team 1 or team 2."
        case .playerNotFound: "That player isn't in the room."
        case .invalidSetting: "That setting isn't allowed."
        case .notEnoughPlayers: "Each team needs at least two players."
        case .submissionsClosed: "Time's up for adding names."
        case .notAPlayer: "Only players on a team can add names."
        case .alreadySubmitted: "You've already submitted your names."
        case .wrongSlipCount: "Enter the full number of names."
        case .invalidSlip: "A name is empty or too long."
        case .deadlineNotReached: "It's too early for that."
        case .notYourTurn: "It's not your turn."
        case .turnAlreadyStarted: "Your turn has already started."
        case .turnNotStarted: "The turn hasn't started yet."
        case .turnOver: "Time's up for this turn."
        case .invalidToken: "That name has already changed."
        case .skipNotAllowed: "You can't skip right now."
        case .notSpectator: "That player isn't a spectator."
        case .turnActive: "Wait until the current turn ends."
        case .cannotTargetSelf: "You can't do that to yourself."
        case .alreadyHost: "You're already the host."
        case .hostStillActive: "The host is still here."
        case .network: "Can't reach the server. Check your connection."
        case .unknown: "Something went wrong. Please try again."
        }
    }

    /// Same text as ``userMessage``, so `error.localizedDescription` is safe to show.
    public var errorDescription: String? { userMessage }

    /// True for ``network(_:)``, so callers can offer retry or show a reconnecting banner.
    public var isNetwork: Bool {
        if case .network = self { return true }
        return false
    }

    /// True for ``notMember``. When a refresh of the room the app is currently in fails with
    /// this, the seat is gone (kicked, or the room was deleted). See ``GameBackend/roomLosses``.
    public var isMembershipLoss: Bool { self == .notMember }

    /// Maps a server error message to a case.
    ///
    /// Domain errors carry the code as a whole word in the message (possibly with decoration such as
    /// `P0001:` or trailing detail). The first whole word that is a known code wins; matching is case
    /// insensitive. A code embedded in a longer word does not match.
    /// - Parameters:
    ///   - message: The PostgREST or database error message.
    ///   - sqlState: The SQLSTATE if known. `42501` (no execute grant, the signed-out `anon` role)
    ///     maps to ``notAuthenticated``.
    /// - Returns: The matching case, or ``unknown(_:)`` carrying the message.
    public static func parse(message: String, sqlState: String? = nil) -> BackendError {
        let words = message.lowercased().split { !($0.isLetter || $0 == "_") }
        for word in words {
            if let match = domainCases.first(where: { $0.code == String(word) }) {
                return match
            }
        }
        if sqlState == "42501" { return .notAuthenticated }
        return .unknown(message)
    }

    /// Converts any thrown error into a ``BackendError``.
    ///
    /// A `BackendError` passes through, `URLError` becomes ``network(_:)``, and anything else
    /// becomes ``unknown(_:)``.
    public static func from(_ error: any Error) -> BackendError {
        if let backend = error as? BackendError { return backend }
        if let urlError = error as? URLError { return .network(urlError.localizedDescription) }
        return .unknown(String(describing: error))
    }
}
