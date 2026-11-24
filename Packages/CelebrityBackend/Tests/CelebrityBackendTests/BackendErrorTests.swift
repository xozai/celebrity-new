import Foundation
import Testing
@testable import CelebrityBackend

/// Every domain code in docs/PLAN.md section 6, paired with the case it must map to.
private let allCodes: [(String, BackendError)] = [
    ("not_authenticated", .notAuthenticated),
    ("invalid_name", .invalidName),
    ("rate_limited", .rateLimited),
    ("code_unavailable", .codeUnavailable),
    ("room_not_found", .roomNotFound),
    ("name_taken", .nameTaken),
    ("not_member", .notMember),
    ("not_host", .notHost),
    ("wrong_phase", .wrongPhase),
    ("invalid_team", .invalidTeam),
    ("player_not_found", .playerNotFound),
    ("invalid_setting", .invalidSetting),
    ("not_enough_players", .notEnoughPlayers),
    ("submissions_closed", .submissionsClosed),
    ("not_a_player", .notAPlayer),
    ("already_submitted", .alreadySubmitted),
    ("wrong_slip_count", .wrongSlipCount),
    ("invalid_slip", .invalidSlip),
    ("deadline_not_reached", .deadlineNotReached),
    ("not_your_turn", .notYourTurn),
    ("turn_already_started", .turnAlreadyStarted),
    ("turn_not_started", .turnNotStarted),
    ("turn_over", .turnOver),
    ("invalid_token", .invalidToken),
    ("skip_not_allowed", .skipNotAllowed),
    ("not_spectator", .notSpectator),
    ("turn_active", .turnActive),
    ("cannot_target_self", .cannotTargetSelf),
    ("already_host", .alreadyHost),
    ("host_still_active", .hostStillActive),
]

private func envelope(_ code: String, _ message: String, details: String? = nil, hint: String? = nil) -> Data {
    func json(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }
    return Data(#"{"code":"\#(code)","details":\#(json(details)),"hint":\#(json(hint)),"message":"\#(message)"}"#.utf8)
}

@Suite struct BackendErrorTests {
    @Test(arguments: allCodes)
    func mapsEveryDomainCodeFromTheStructuredError(code: String, expected: BackendError) {
        #expect(BackendError.from(code: "P0001", message: code, httpStatus: 400) == expected)
        #expect(BackendError.from(postgrestBody: envelope("P0001", code), httpStatus: 400) == expected)
        #expect(expected.code == code)
    }

    @Test func domainCasesCoverEveryCode() {
        #expect(BackendError.domainCases.count == allCodes.count)
        #expect(Set(BackendError.domainCases.compactMap(\.code)) == Set(allCodes.map(\.0)))
        #expect(Set(BackendError.domainCases.map(\.code)).count == allCodes.count)
    }

    @Test(arguments: allCodes)
    func everyCodeHasShortUserMessage(code: String, expected: BackendError) {
        let message = expected.userMessage
        #expect(!message.isEmpty)
        #expect(message.count <= 90)
        #expect(!message.contains(code))
        #expect(!message.contains("_"))
        #expect(expected.errorDescription == message)
    }

    @Test func nonDomainCasesHaveMessagesAndNoCode() {
        for error in [BackendError.permissionDenied, .cancelled, .network("x"), .unknown("x")] {
            #expect(!error.userMessage.isEmpty)
            #expect(error.code == nil)
        }
    }

    // MARK: Exact tokens only

    @Test(arguments: ["wrong_phase: lobby", "P0001: wrong_phase", "WRONG_PHASE", "ERROR: wrong_phase", "not_member_of_anything", " wrong_phase "])
    func p0001RequiresTheExactToken(message: String) {
        let parsed = BackendError.from(code: "P0001", message: message, httpStatus: 400)
        if message == " wrong_phase " {
            // Surrounding whitespace is the only decoration tolerated.
            #expect(parsed == .wrongPhase)
        } else {
            #expect(parsed == .unknown(message))
        }
    }

    @Test func domainLookingTextUnderAnotherCodeIsNotADomainError() {
        #expect(BackendError.from(code: "23505", message: "not_member", httpStatus: 409) == .unknown("not_member"))
        #expect(BackendError.from(code: "PGRST116", message: "wrong_phase", httpStatus: 406) == .unknown("wrong_phase"))
        #expect(BackendError.from(code: nil, message: "not_member", httpStatus: 400) == .unknown("not_member"))
    }

    @Test func unknownKeepsMessageForLogsOnly() {
        let error = BackendError.from(code: "P0001", message: "something odd", httpStatus: 400)
        #expect(error == .unknown("something odd"))
        #expect(!error.userMessage.contains("odd"))
        #expect(BackendError.from(code: "XX000", message: nil, httpStatus: 500) == .unknown("XX000"))
    }

    // MARK: Authentication

    @Test func expiredJWTIsNotAuthenticated() {
        let body = envelope("PGRST301", "JWT expired")
        #expect(BackendError.from(postgrestBody: body, httpStatus: 401) == .notAuthenticated)
        #expect(BackendError.from(code: "PGRST303", message: "JWT claims invalid", httpStatus: 401) == .notAuthenticated)
        #expect(BackendError.from(code: "PGRST302", message: "Anonymous access is disabled", httpStatus: 401) == .notAuthenticated)
    }

    @Test func signedOutAnonRoleDenialIsNotAuthenticated() {
        let body = envelope("42501", "permission denied for function create_room")
        #expect(BackendError.from(postgrestBody: body, httpStatus: 401) == .notAuthenticated)
    }

    @Test func authenticatedPermissionDenialIsNotSignedOut() {
        let body = envelope("42501", "permission denied for table slips", details: "d", hint: "h")
        #expect(BackendError.from(postgrestBody: body, httpStatus: 403) == .permissionDenied)
        // Without a status we cannot tell, so do not claim the player is signed out.
        #expect(BackendError.from(code: "42501", message: "permission denied", httpStatus: nil) == .permissionDenied)
    }

    @Test func any401WithoutAUsableBodyIsNotAuthenticated() {
        #expect(BackendError.from(postgrestBody: Data("Unauthorized".utf8), httpStatus: 401) == .notAuthenticated)
    }

    // MARK: Envelopes

    @Test func envelopeWithNullDetailsAndHintDecodes() {
        let body = Data(#"{"code":"P0001","details":null,"hint":null,"message":"not_member"}"#.utf8)
        #expect(BackendError.from(postgrestBody: body, httpStatus: 400) == .notMember)
    }

    @Test func envelopeWithDetailsAndHintDecodes() {
        let body = envelope("P0001", "name_taken", details: "x", hint: "y")
        #expect(BackendError.from(postgrestBody: body, httpStatus: 400) == .nameTaken)
    }

    @Test func nonJSONBodyBecomesUnknown() {
        #expect(BackendError.from(postgrestBody: Data("<html>oops</html>".utf8), httpStatus: 400) == .unknown("<html>oops</html>"))
        #expect(BackendError.from(postgrestBody: Data(), httpStatus: 400) == .unknown(""))
    }

    @Test(arguments: [502, 503, 504])
    func gatewayFailuresAreNetwork(status: Int) {
        #expect(BackendError.from(postgrestBody: Data("bad gateway".utf8), httpStatus: status).isNetwork)
    }

    // MARK: Transport and cancellation

    @Test func urlErrorsAreNetworkExceptCancellation() {
        let offline = URLError(.notConnectedToInternet)
        #expect(BackendError.from(offline) == .network(offline.localizedDescription))
        #expect(BackendError.from(URLError(.cancelled)) == .cancelled)
        #expect(BackendError.from(CancellationError()) == .cancelled)
    }

    @Test func cancellationIsRecognisedInAnyForm() {
        #expect(BackendError.isCancellation(CancellationError()))
        #expect(BackendError.isCancellation(URLError(.cancelled)))
        #expect(BackendError.isCancellation(BackendError.cancelled))
        #expect(!BackendError.isCancellation(URLError(.timedOut)))
        #expect(!BackendError.isCancellation(BackendError.wrongPhase))
        #expect(BackendError.cancelled.isCancellation)
        #expect(!BackendError.network("x").isCancellation)
    }

    @Test func fromPassesBackendErrorThroughAndWrapsOthers() {
        #expect(BackendError.from(BackendError.notHost) == .notHost)
        struct Other: Error {}
        if case .unknown = BackendError.from(Other()) {} else { Issue.record("expected .unknown") }
    }

    @Test func networkFlags() {
        #expect(BackendError.network("x").isNetwork)
        #expect(!BackendError.wrongPhase.isNetwork)
    }

    @Test func membershipLossIsOnlyNotMember() {
        #expect(BackendError.notMember.isMembershipLoss)
        for (_, error) in allCodes where error != .notMember {
            #expect(!error.isMembershipLoss)
        }
    }
}
