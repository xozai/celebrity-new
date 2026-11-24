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
    /// `not_authenticated`: no session, or the account was deleted. Also produced for an expired or invalid
    /// JWT (`PGRST301`-`PGRST303`) and for HTTP 401.
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
    /// `invalid_token`: the token argument was null. (A stale but well-formed token is not an error: the server
    /// changes nothing and returns the current draw.)
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
    /// The signed-in user was refused by the database (SQLSTATE `42501` with HTTP 403). Not the same as signed out.
    case permissionDenied
    /// The call was cancelled (task cancellation or `URLError.cancelled`). **Never show this to a player**: ignore it.
    /// Check with ``isCancellation``.
    case cancelled
    /// A transport failure (offline, timeout, TLS, gateway down). The associated text is for logs only.
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
        case .permissionDenied, .cancelled, .network, .unknown: nil
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
        case .permissionDenied: "You don't have permission to do that."
        case .cancelled: "Cancelled."
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

    /// True for ``cancelled``. Cancellation is not a failure: do not alert.
    public var isCancellation: Bool { self == .cancelled }

    /// True if `error` is a cancellation in any form: `CancellationError`, `URLError.cancelled` or ``cancelled``.
    /// - Parameter error: Any thrown error.
    public static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return (error as? BackendError) == .cancelled
    }

    /// Maps a structured PostgREST error to a case.
    ///
    /// The migrations raise domain errors as `raise exception '<code>'`, which PostgREST reports with
    /// `code: "P0001"` and the code as the entire `message`. So:
    /// - `P0001` with a message equal to a domain code (surrounding whitespace ignored) maps to that case.
    ///   Any other `P0001` message, and a domain-looking message under any other code, is ``unknown(_:)``.
    /// - `PGRST301`, `PGRST302`, `PGRST303` (JWT problems) and any HTTP 401 map to ``notAuthenticated``.
    /// - `42501` (permission denied) maps to ``notAuthenticated`` when the status is 401 (the signed-out `anon`
    ///   role) and to ``permissionDenied`` otherwise, because an authenticated denial is not "signed out".
    /// - HTTP 502, 503 and 504 map to ``network(_:)``.
    /// - Anything else is ``unknown(_:)`` carrying the message (or code).
    /// - Parameters:
    ///   - code: The envelope's `code`.
    ///   - message: The envelope's `message`.
    ///   - httpStatus: The HTTP status of the response, if known.
    public static func from(code: String?, message: String?, httpStatus: Int?) -> BackendError {
        if code == "P0001", let message {
            let token = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = domainCases.first(where: { $0.code == token }) { return match }
            return .unknown(message)
        }
        if let code {
            if ["PGRST301", "PGRST302", "PGRST303"].contains(code) { return .notAuthenticated }
            if code == "42501" { return httpStatus == 401 ? .notAuthenticated : .permissionDenied }
        }
        if httpStatus == 401 { return .notAuthenticated }
        if let httpStatus, [502, 503, 504].contains(httpStatus) {
            return .network(message ?? "HTTP \(httpStatus)")
        }
        return .unknown(message ?? code ?? "")
    }

    /// Maps the raw body of a failed PostgREST response (`{"code":..,"details":..,"hint":..,"message":..}`).
    /// A body that is not that JSON object is treated as a message with no code. See
    /// ``from(code:message:httpStatus:)`` for the rules.
    /// - Parameters:
    ///   - postgrestBody: The response body.
    ///   - httpStatus: The HTTP status of the response, if known.
    public static func from(postgrestBody: Data, httpStatus: Int?) -> BackendError {
        struct Envelope: Decodable {
            var code: String?
            var message: String?
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: postgrestBody) {
            return from(code: envelope.code, message: envelope.message, httpStatus: httpStatus)
        }
        return from(code: nil, message: String(decoding: postgrestBody, as: UTF8.self), httpStatus: httpStatus)
    }

    /// Converts any thrown error into a ``BackendError``.
    ///
    /// A `BackendError` passes through. `CancellationError` and `URLError.cancelled` become ``cancelled``
    /// (never shown to players). Other `URLError`s become ``network(_:)``. Anything else becomes ``unknown(_:)``.
    /// - Parameter error: The error to convert.
    public static func from(_ error: any Error) -> BackendError {
        if let backend = error as? BackendError { return backend }
        if isCancellation(error) { return .cancelled }
        if let urlError = error as? URLError { return .network(urlError.localizedDescription) }
        return .unknown(String(describing: error))
    }
}
