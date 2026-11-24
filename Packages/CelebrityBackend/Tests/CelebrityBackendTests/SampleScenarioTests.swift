import CelebrityCore
import Foundation
import Testing
@testable import CelebrityBackend

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func scenario(_ id: SampleScenario.ID) -> SampleScenario { SampleScenario.make(id, now: now) }

private let runningClueGiverIDs: [SampleScenario.ID] = [
    .playingClueGiver, .playingClueGiverSkipOff, .playingClueGiverSkipUsed, .playingClueGiverUnlimited,
]
private let playingIDs: [SampleScenario.ID] = [
    .playingClueGiverReady, .playingClueGiver, .playingClueGiverSkipOff, .playingClueGiverSkipUsed,
    .playingClueGiverUnlimited, .playingGuesser, .playingOpponent, .playingSpectator,
]

/// Every snapshot a scenario can show, including its follow-up.
private func allSnapshots() -> [(SampleScenario.ID, RoomSnapshot)] {
    SampleScenario.all(now: now).flatMap { s in [(s.id, s.snapshot)] + (s.followUp.map { [(s.id, $0)] } ?? []) }
}

@Suite struct SampleScenarioTests {
    @Test func everyScenarioBuildsAndViewerIsSeatedInTheRoom() {
        for id in SampleScenario.ID.allCases {
            let s = scenario(id)
            #expect(s.id == id)
            #expect(s.snapshot.me(userID: s.userID) != nil, "\(id): viewer has no seat")
            #expect(s.snapshot.serverNow == now)
            #expect(s.snapshot.players.allSatisfy { $0.roomID == s.snapshot.room.id })
            let seats = s.snapshot.players.map(\.seat)
            #expect(seats == seats.sorted() && Set(seats).count == seats.count, "\(id): seats")
            #expect(!s.title.isEmpty)
        }
        #expect(SampleScenario.all(now: now).map(\.id) == SampleScenario.ID.allCases)
    }

    @Test func snapshotsSurviveTheWireRoundTrip() throws {
        for (id, snapshot) in allSnapshots() {
            let data = try RoomSnapshot.makeEncoder().encode(snapshot)
            #expect(try RoomSnapshot.makeDecoder().decode(RoomSnapshot.self, from: data) == snapshot, "\(id)")
        }
    }

    // MARK: Screens

    @Test func lobbyAsHost() {
        let s = scenario(.lobbyHost)
        #expect(Screen.from(snapshot: s.snapshot) == .lobby)
        #expect(s.snapshot.isHost(userID: s.userID))
        #expect(s.snapshot.canStartGame(userID: s.userID).allowed)
        #expect(s.draw == nil)
    }

    @Test func lobbyAsGuest() {
        let s = scenario(.lobbyGuest)
        #expect(!s.snapshot.isHost(userID: s.userID))
        #expect(!s.snapshot.canStartGame(userID: s.userID).allowed)
    }

    @Test func lobbyWithUnevenTeamsCannotStart() {
        let s = scenario(.lobbyUnevenHost)
        let check = s.snapshot.canStartGame(userID: s.userID)
        #expect(!check.allowed)
        #expect(check.reason != nil)
    }

    @Test(arguments: [SampleScenario.ID.submittingEditing, .submittingWaiting, .submittingSpectator, .submittingRecommendationsOff])
    func submitting(id: SampleScenario.ID) {
        let s = scenario(id)
        #expect(Screen.from(snapshot: s.snapshot) == .submit)
        #expect((s.snapshot.room.submissionDeadline ?? .distantPast) > now)
        let me = s.snapshot.me(userID: s.userID)
        switch id {
        case .submittingWaiting: #expect(me?.role == .player && me?.submitted == true)
        case .submittingSpectator: #expect(s.snapshot.isSpectator(userID: s.userID))
        default: #expect(me?.role == .player && me?.submitted == false)
        }
        #expect(s.snapshot.room.settings.suggestionsEnabled == (id != .submittingRecommendationsOff))
        #expect(s.snapshot.players.contains { $0.role == .player && $0.submitted })
    }

    @Test func expiredEmptySubmissionReplaysBackToTheLobby() throws {
        let s = scenario(.submittingExpiredEmpty)
        #expect(Screen.from(snapshot: s.snapshot) == .submit)
        #expect((s.snapshot.room.submissionDeadline ?? .distantFuture) < now)
        #expect(s.snapshot.players.allSatisfy { !$0.submitted })
        let after = try #require(s.followUp)
        #expect(Screen.from(snapshot: after) == .lobby)
        #expect(after.room.submissionDeadline == nil)
        #expect(after.players.allSatisfy { !$0.submitted })
        #expect(after.players.map(\.userID) == s.snapshot.players.map(\.userID))
    }

    @Test func clueGiverBeforeStartTurnThenRunning() throws {
        let s = scenario(.playingClueGiverReady)
        #expect(s.snapshot.isClueGiver(userID: s.userID))
        #expect(s.snapshot.room.turnEndsAt == nil)
        #expect(s.draw == nil)
        let running = try #require(s.followUp)
        #expect((running.room.turnEndsAt ?? .distantPast) > now)
        #expect(running.room.turnPlayerID == s.snapshot.room.turnPlayerID)
        #expect(running.room.turnGot > s.snapshot.room.turnGot)
    }

    @Test(arguments: runningClueGiverIDs)
    func runningClueGiverVariants(id: SampleScenario.ID) throws {
        let s = scenario(id)
        let room = s.snapshot.room
        #expect(Screen.from(snapshot: s.snapshot) == .game)
        #expect(s.snapshot.isClueGiver(userID: s.userID))
        #expect((room.turnEndsAt ?? .distantPast) > now)
        #expect(room.turnEndsAt! <= now.addingTimeInterval(Double(room.settings.turnSeconds)))
        #expect(room.pileCount > 0)
        let draw = try #require(s.draw)
        let json = String(decoding: try RoomSnapshot.makeEncoder().encode(s.snapshot), as: UTF8.self)
        #expect(!json.contains(draw.name))
        #expect(!json.localizedCaseInsensitiveContains(draw.token.uuidString))
        switch id {
        case .playingClueGiverSkipOff: #expect(room.settings.skipMode == .off && room.turnSkips == 0)
        case .playingClueGiverSkipUsed: #expect(room.settings.skipMode == .onePerTurn && room.turnSkips == 1)
        case .playingClueGiverUnlimited: #expect(room.settings.skipMode == .unlimited && room.turnSkips > 1)
        default: #expect(room.settings.skipMode == .onePerTurn && room.turnSkips == 0)
        }
    }

    @Test func guesserOpponentAndSpectatorViewTheSameRunningTurn() throws {
        let guesser = scenario(.playingGuesser), opponent = scenario(.playingOpponent), spectator = scenario(.playingSpectator)
        #expect(guesser.snapshot == opponent.snapshot && opponent.snapshot == spectator.snapshot)
        let giver = try #require(guesser.snapshot.nextUp)
        let g = try #require(guesser.snapshot.me(userID: guesser.userID))
        let o = try #require(opponent.snapshot.me(userID: opponent.userID))
        #expect(g.role == .player && g.team == giver.team && g.userID != giver.userID)
        #expect(o.role == .player && o.team != giver.team)
        #expect(spectator.snapshot.isSpectator(userID: spectator.userID))
        #expect([guesser.draw, opponent.draw, spectator.draw].allSatisfy { $0 == nil })
    }

    @Test(arguments: [SampleScenario.ID.stalledHost, .stalledGuest])
    func stalledRoomKeepsItsTeamAndRecoversWhenTheHostAssignsTheSpectator(id: SampleScenario.ID) throws {
        let s = scenario(id)
        let room = s.snapshot.room
        #expect(room.phase == .playing)
        #expect(room.turnPlayerID == nil && s.snapshot.nextUp == nil && room.turnEndsAt == nil)
        // The server keeps current_team while stalled (_set_turn_player only nulls turn_player_id).
        #expect(room.currentTeam != nil)
        #expect(s.snapshot.isHost(userID: s.userID) == (id == .stalledHost))
        let perTeam = (0..<2).map { team in s.snapshot.players.filter { $0.role == .player && $0.team == team }.count }
        #expect(perTeam.allSatisfy { $0 < 2 })
        let spectator = try #require(s.snapshot.players.first { $0.role == .spectator })

        let after = try #require(s.followUp)
        let promoted = try #require(after.me(userID: spectator.userID))
        #expect(promoted.role == .player && promoted.team == room.currentTeam)
        #expect(after.room.currentTeam == room.currentTeam)
        let giver = try #require(after.nextUp)
        #expect(giver.team == room.currentTeam)
        #expect(after.room.turnEndsAt == nil, "Start Turn is available, not yet running")
        #expect(after.room.turnIdx == room.turnIdx)
    }

    @Test(arguments: [SampleScenario.ID.roundEndHost, .roundEndGuest])
    func roundEnd(id: SampleScenario.ID) {
        let s = scenario(id)
        #expect(s.snapshot.room.phase == .roundEnd)
        #expect(Screen.from(snapshot: s.snapshot) == .game)
        #expect(s.snapshot.room.pileCount == 0)
        #expect(s.snapshot.room.currentTeam == nil && s.snapshot.room.turnPlayerID == nil)
        #expect(s.snapshot.isHost(userID: s.userID) == (id == .roundEndHost))
        #expect(s.snapshot.turns.allSatisfy { $0.round == s.snapshot.room.round })
        #expect(s.snapshot.teamTotals.reduce(0, +) == 18)
    }

    @Test func finishedWithWinnerAndAnonymisedTurns() {
        let s = scenario(.finishedWinner)
        #expect(Screen.from(snapshot: s.snapshot) == .finished)
        #expect(s.snapshot.winner == 0)
        #expect(s.snapshot.room.finishedAt != nil)
        #expect(s.snapshot.room.round == CelebrityCore.roundCount)
        let former = s.snapshot.turns.filter { $0.playerID == nil }
        #expect(!former.isEmpty && former.allSatisfy { $0.playerName == "Former player" })
        #expect(!s.snapshot.players.contains { $0.name == "Frankie" })
        #expect(s.snapshot.turns.allSatisfy { t in t.playerID == nil || s.snapshot.players.contains { $0.userID == t.playerID } })
    }

    @Test func finishedWithTie() {
        let s = scenario(.finishedTie)
        #expect(Screen.from(snapshot: s.snapshot) == .finished)
        #expect(s.snapshot.winner == nil)
        let totals = s.snapshot.teamTotals
        #expect(totals[0] == totals[1] && totals[0] > 0)
    }

    // MARK: Server invariants (supabase/migrations)

    @Test func settingsAreWithinTheDatabaseChecks() {
        for (id, snap) in allSnapshots() {
            let s = snap.room.settings
            #expect((1...10).contains(s.slipsPerPlayer), "\(id)")
            #expect([30, 60, 90].contains(s.turnSeconds), "\(id)")
            #expect((30...600).contains(s.submissionSeconds), "\(id)")
            #expect(snap.room.teamNames.count == 2 && snap.room.turnIdx.count == 2, "\(id)")
            #expect(snap.players.allSatisfy { (1...20).contains($0.name.count) }, "\(id)")
        }
    }

    @Test func freshRoomsHaveFreshCursorsAndScores() {
        for id in [SampleScenario.ID.lobbyHost, .lobbyGuest, .lobbyUnevenHost, .submittingEditing, .submittingWaiting,
                   .submittingSpectator, .submittingRecommendationsOff, .submittingExpiredEmpty] {
            let r = scenario(id).snapshot.room
            #expect(r.turnIdx == [0, 0] && r.currentTeam == nil && r.turnPlayerID == nil, "\(id)")
            #expect(r.scores == [[0, 0], [0, 0], [0, 0]] && r.pileCount == 0 && r.turnEndsAt == nil, "\(id)")
            #expect(r.round == 0, "\(id)")
        }
    }

    /// Replays each fixture's history with the server's rules and compares.
    @Test func historyFollowsRoundStartersAlternationAndRotation() {
        let rosters: [[UUID]] = [
            [SampleCast.alex.id, SampleCast.blair.id, SampleCast.casey.id],
            [SampleCast.drew.id, SampleCast.emery.id, SampleCast.frankie.id],
        ]
        for (id, snap) in allSnapshots() {
            let turns = snap.turns
            // Round starters alternate: round 1 team 0, round 2 team 1, round 3 team 0.
            for round in 1...3 {
                let inRound = turns.filter { $0.round == round }
                guard let first = inRound.first else { continue }
                #expect(first.team == (round - 1) % 2, "\(id) round \(round) starter")
                // Teams alternate within a round.
                for (a, b) in zip(inRound, inRound.dropFirst()) { #expect(a.team != b.team, "\(id) alternation") }
            }
            // Ids ascend, rounds never go back.
            #expect(turns.map(\.id) == turns.map(\.id).sorted(), "\(id)")
            #expect(turns.map(\.round) == turns.map(\.round).sorted(), "\(id)")
            // Rotation: each team's n-th turn is its roster member n mod 3 (anonymised turns are skipped).
            var counts = [0, 0]
            for t in turns {
                if let who = t.playerID { #expect(who == rosters[t.team][counts[t.team] % 3], "\(id) rotation") }
                counts[t.team] += 1
            }
            // The cursor equals each team's turn count, except where a player left after the game.
            let left = snap.players.count < 7 && snap.room.phase == .finished
            if snap.room.phase != .lobby && snap.room.phase != .submitting && !left {
                #expect(snap.room.turnIdx == counts, "\(id) cursor \(snap.room.turnIdx) vs \(counts)")
            }
            // Mid-round, the team to move is the one that did not take the last turn of the round.
            if snap.room.phase == .playing, let last = turns.last, last.round == snap.room.round {
                #expect(snap.room.currentTeam == 1 - last.team, "\(id) current team")
            }
            if snap.room.phase == .playing, turns.isEmpty || turns.last?.round != snap.room.round {
                #expect(snap.room.currentTeam == (snap.room.round - 1) % 2, "\(id) starter")
            }
        }
    }

    @Test func runningTurnPlayerIsTheCursorHolder() throws {
        let rosters: [[UUID]] = [
            [SampleCast.alex.id, SampleCast.blair.id, SampleCast.casey.id],
            [SampleCast.drew.id, SampleCast.emery.id, SampleCast.frankie.id],
        ]
        for id in playingIDs {
            let r = scenario(id).snapshot.room
            let team = try #require(r.currentTeam)
            #expect(r.turnPlayerID == rosters[team][r.turnIdx[team] % 3], "\(id)")
        }
    }

    @Test func skipCountsRespectTheSkipMode() {
        for (id, snap) in allSnapshots() {
            let limit: Int
            switch snap.room.settings.skipMode {
            case .off: limit = 0
            case .onePerTurn: limit = 1
            case .unlimited: limit = .max
            }
            #expect(snap.turns.allSatisfy { $0.skipped <= limit }, "\(id) history skips")
            #expect(snap.room.turnSkips <= limit, "\(id) turn skips")
        }
    }

    @Test func timestampsFitInsideTheRoomLifetime() {
        for (id, snap) in allSnapshots() {
            let room = snap.room
            #expect(room.createdAt <= room.lastActivityAt && room.lastActivityAt <= snap.serverNow, "\(id) activity")
            let ends = snap.turns.map(\.endedAt)
            #expect(ends == ends.sorted(), "\(id) ordering")
            for end in ends { #expect(end >= room.createdAt && end <= snap.serverNow, "\(id) turn time") }
            if let finished = room.finishedAt {
                #expect(finished >= (ends.last ?? room.createdAt) && finished <= snap.serverNow, "\(id) finished")
            }
            for player in snap.players { #expect(player.lastSeenAt >= room.createdAt && player.lastSeenAt <= snap.serverNow, "\(id)") }
            if let running = room.turnEndsAt, let last = ends.last {
                #expect(running.addingTimeInterval(-Double(room.settings.turnSeconds)) >= last, "\(id) turn starts after history")
            }
        }
    }

    @Test func scoresAndPileMatchTurnHistory() {
        for (id, snap) in allSnapshots() where snap.room.phase != .lobby && snap.room.phase != .submitting {
            let room = snap.room
            for round in 1...3 {
                for team in 0..<2 {
                    var guessed = snap.turns.filter { $0.round == round && $0.team == team }.reduce(0) { $0 + $1.guessed.count }
                    // Scores include the active turn.
                    if round == room.round, room.currentTeam == team, room.turnEndsAt != nil { guessed += room.turnGot }
                    #expect(room.scores[round - 1][team] == guessed, "\(id) round \(round) team \(team)")
                }
            }
            if room.phase == .playing {
                let slips = 18
                let guessedThisRound = snap.turns.filter { $0.round == room.round }.reduce(0) { $0 + $1.guessed.count } + (room.turnEndsAt != nil ? room.turnGot : 0)
                // Stalled: only 16 of the original 18 slips are in play after earlier turns; pile is slips minus guessed.
                #expect(room.pileCount == slips - guessedThisRound, "\(id) pile")
            }
        }
    }

    @Test func completedRoundsScoreTheSlipTotal() {
        for id in [SampleScenario.ID.roundEndHost, .finishedWinner, .finishedTie] {
            let snap = scenario(id).snapshot
            for round in 1...snap.room.round { #expect(snap.room.scores[round - 1].reduce(0, +) == 18, "\(id) round \(round)") }
        }
    }

    // MARK: Helpers

    @Test func viewingAsAnotherUserDropsTheDrawAndKeepsTheFollowUp() {
        let s = scenario(.playingClueGiverReady)
        let other = s.viewing(as: SampleCast.casey.id)
        #expect(other.userID == SampleCast.casey.id)
        #expect(other.draw == nil)
        #expect(other.snapshot == s.snapshot && other.followUp == s.followUp)
        #expect(scenario(.playingClueGiver).viewing(as: SampleCast.alex.id).draw == nil)
    }

    @Test func scenarioFeedsAFakeBackendAndFollowUpReplays() async throws {
        let s = scenario(.stalledHost)
        let backend = FakeGameBackend(scenario: s)
        #expect(try await backend.currentUserID() == s.userID)
        #expect(try await backend.snapshot(roomID: s.snapshot.room.id) == s.snapshot)
        backend.script(.assignSpectator, snapshots: [try #require(s.followUp)])
        try await backend.assignSpectator(userID: SampleCast.gray.id, team: 1)
        #expect(backend.currentSnapshot?.nextUp != nil)
        let clue = scenario(.playingClueGiver)
        #expect(try await FakeGameBackend(scenario: clue).currentSlip() == clue.draw)
    }
}
