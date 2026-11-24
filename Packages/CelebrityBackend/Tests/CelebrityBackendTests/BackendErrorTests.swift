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

@Suite struct BackendErrorTests {
    @Test(arguments: allCodes)
    func parsesEveryDomainCode(code: String, expected: BackendError) {
        #expect(BackendError.parse(message: code) == expected)
        #expect(expected.code == code)
    }

    @Test func allCasesCoverEveryCode() {
        #expect(BackendError.domainCases.count == allCodes.count)
        #expect(Set(BackendError.domainCases.compactMap(\.code)) == Set(allCodes.map(\.0)))
    }

    @Test(arguments: allCodes)
    func everyCodeHasShortUserMessage(code: String, expected: BackendError) {
        let message = expected.userMessage
        #expect(!message.isEmpty)
        #expect(message.count <= 90)
        // Never show the raw server code to a player.
        #expect(!message.contains(code))
        #expect(!message.contains("_"))
        #expect(expected.errorDescription == message)
    }

    @Test(arguments: ["wrong_phase: lobby", "P0001: wrong_phase", "  WRONG_PHASE\n", "ERROR: wrong_phase (SQLSTATE P0001)"])
    func toleratesDecoration(message: String) {
        #expect(BackendError.parse(message: message) == .wrongPhase)
    }

    @Test func doesNotMatchCodeInsideALongerWord() {
        #expect(BackendError.parse(message: "not_member_of_anything") == .unknown("not_member_of_anything"))
        #expect(BackendError.parse(message: "xwrong_phase") == .unknown("xwrong_phase"))
    }

    @Test func unknownMessageIsKept() {
        let error = BackendError.parse(message: "something odd happened")
        #expect(error == .unknown("something odd happened"))
        #expect(error.code == nil)
        #expect(!error.userMessage.contains("odd"))
    }

    @Test func permissionDeniedMapsToNotAuthenticated() {
        #expect(BackendError.parse(message: "permission denied for function create_room", sqlState: "42501") == .notAuthenticated)
        #expect(BackendError.parse(message: "wrong_phase", sqlState: "P0001") == .wrongPhase)
    }

    @Test func networkErrors() {
        let urlError = URLError(.notConnectedToInternet)
        #expect(BackendError.from(urlError) == .network(urlError.localizedDescription))
        #expect(BackendError.network("x").code == nil)
        #expect(BackendError.network("x").isNetwork)
        #expect(!BackendError.wrongPhase.isNetwork)
    }

    @Test func fromPassesBackendErrorThroughAndWrapsOthers() {
        #expect(BackendError.from(BackendError.notHost) == .notHost)
        struct Other: Error {}
        if case .unknown = BackendError.from(Other()) {} else { Issue.record("expected .unknown") }
    }

    @Test func membershipLossIsOnlyNotMember() {
        #expect(BackendError.notMember.isMembershipLoss)
        for (_, error) in allCodes where error != .notMember {
            #expect(!error.isMembershipLoss)
        }
    }
}
