import CelebrityCore
import Foundation

/// A person in the sample rooms. Their ids are fixed so previews and tests can name them.
public struct SampleCast: Sendable, Equatable {
    /// The player's user id.
    public let id: UUID
    /// The player's display name.
    public let name: String

    /// Host, team 0, seat 1.
    public static let alex = SampleCast(id: UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!, name: "Alex")
    /// Team 0, seat 2.
    public static let blair = SampleCast(id: UUID(uuidString: "A1000000-0000-4000-8000-000000000002")!, name: "Blair")
    /// Team 0, seat 3.
    public static let casey = SampleCast(id: UUID(uuidString: "A1000000-0000-4000-8000-000000000003")!, name: "Casey")
    /// Team 1, seat 4.
    public static let drew = SampleCast(id: UUID(uuidString: "A1000000-0000-4000-8000-000000000004")!, name: "Drew")
    /// Team 1, seat 5.
    public static let emery = SampleCast(id: UUID(uuidString: "A1000000-0000-4000-8000-000000000005")!, name: "Emery")
    /// Team 1, seat 6.
    public static let frankie = SampleCast(id: UUID(uuidString: "A1000000-0000-4000-8000-000000000006")!, name: "Frankie")
    /// Seat 7: unassigned in the lobby, a spectator once the game has started.
    public static let gray = SampleCast(id: UUID(uuidString: "A1000000-0000-4000-8000-000000000007")!, name: "Gray")
}

/// Ready-made recommendation rows used as the fake's defaults.
public enum SampleSuggestions {
    /// Twenty-four well-known names with descriptions, across categories, in rough order of fame.
    public static let all: [CelebritySuggestion] = [
        CelebritySuggestion(name: "Tom Hanks", description: "American actor", category: .filmTV, sources: ["wikipedia", "imdb"]),
        CelebritySuggestion(name: "Taylor Swift", description: "American singer-songwriter", category: .music, sources: ["wikipedia"]),
        CelebritySuggestion(name: "Serena Williams", description: "American tennis player", category: .sports, sources: ["wikipedia"]),
        CelebritySuggestion(name: "Sherlock Holmes", description: "Fictional detective", category: .fictional, sources: ["wikipedia"]),
        CelebritySuggestion(name: "Beyoncé", description: "American singer", category: .music, sources: ["wikipedia"]),
        CelebritySuggestion(name: "Lionel Messi", description: "Argentine footballer", category: .sports, sources: ["wikipedia"]),
        CelebritySuggestion(name: "Barack Obama", description: "44th president of the United States", category: .publicFigure, sources: ["wikipedia"]),
        CelebritySuggestion(name: "Meryl Streep", description: "American actress", category: .filmTV, sources: ["wikipedia", "imdb"]),
        CelebritySuggestion(name: "Cleopatra", description: "Queen of Egypt", category: .publicFigure, sources: ["wikipedia"]),
        CelebritySuggestion(name: "Harry Potter", description: "Fictional wizard", category: .fictional, sources: ["wikipedia"]),
        CelebritySuggestion(name: "Elvis Presley", description: "American singer", category: .music, sources: ["wikipedia"]),
        CelebritySuggestion(name: "Oprah Winfrey", description: "American talk show host", category: .filmTV, sources: ["wikipedia", "imdb"]),
        CelebritySuggestion(name: "Tom Cruise", description: "American actor", category: .filmTV, sources: ["wikipedia", "imdb"]),
        CelebritySuggestion(name: "Michael Jordan", description: "American basketball player", category: .sports, sources: ["wikipedia"]),
        CelebritySuggestion(name: "Albert Einstein", description: "German-born physicist", category: .publicFigure, sources: ["wikipedia"]),
        CelebritySuggestion(name: "Marilyn Monroe", description: "American actress", category: .filmTV, sources: ["wikipedia", "imdb"]),
        CelebritySuggestion(name: "Bruce Lee", description: "Hong Kong-American martial artist", category: .filmTV, sources: ["wikipedia", "imdb"]),
        CelebritySuggestion(name: "Frida Kahlo", description: "Mexican painter", category: .publicFigure, sources: ["wikipedia"]),
        CelebritySuggestion(name: "Dolly Parton", description: "American singer-songwriter", category: .music, sources: ["wikipedia"]),
        CelebritySuggestion(name: "Mister Rogers", description: "American television host", category: .filmTV, sources: ["wikipedia"]),
        CelebritySuggestion(name: "Darth Vader", description: "Fictional Star Wars villain", category: .fictional, sources: ["wikipedia"]),
        CelebritySuggestion(name: "Simone Biles", description: "American gymnast", category: .sports, sources: ["wikipedia"]),
        CelebritySuggestion(name: "David Bowie", description: "English singer", category: .music, sources: ["wikipedia"]),
        CelebritySuggestion(name: "Winston Churchill", description: "British prime minister", category: .publicFigure, sources: ["wikipedia"]),
    ]
}

/// A ready-made screen state: one room snapshot, the user viewing it and, for a clue-giver, the private draw.
///
/// Use these for previews and UI tests: `FakeGameBackend(scenario: .make(.playingGuesser))`. Scenarios are plain
/// values built from fixed ids and the `now` you pass, so a preview can pass `Date()` for a running countdown
/// and a test can pass a fixed date for stable output. The same snapshot with another viewer is available
/// through ``viewing(as:)``.
public struct SampleScenario: Sendable, Equatable, Identifiable {
    /// A screen state from docs/PLAN.md Phase 4.
    public enum ID: String, Sendable, CaseIterable {
        /// Lobby, viewed by the host. Teams of three, one unassigned player. Start is allowed.
        case lobbyHost
        /// Lobby, viewed by a guest.
        case lobbyGuest
        /// Lobby with uneven teams (team 1 has one player), viewed by the host. Start is disabled with a reason.
        case lobbyUnevenHost
        /// Submitting, viewed by a player who has not submitted yet. Recommendations on.
        case submittingEditing
        /// Submitting, viewed by a player who already submitted.
        case submittingWaiting
        /// Submitting, viewed by a spectator.
        case submittingSpectator
        /// Submitting with the host's recommendations switch off, viewed by a player who has not submitted.
        case submittingRecommendationsOff
        /// The submission window has expired and nothing was submitted. ``SampleScenario/followUp`` is the lobby
        /// the server returns to after `close_submissions()`.
        case submittingExpiredEmpty
        /// Round 1: Blair is the assigned clue-giver but has not started the turn (`turn_ends_at` is nil). Viewed by
        /// Blair. ``SampleScenario/followUp`` is the running snapshot after `start_turn()`.
        case playingClueGiverReady
        /// Round 1, a turn running, viewed by the clue-giver (Blair). Skip mode one per turn, none used yet. Has a draw.
        case playingClueGiver
        /// As ``playingClueGiver`` with skipping off.
        case playingClueGiverSkipOff
        /// As ``playingClueGiver`` with the one skip already used (`turn_skips` 1).
        case playingClueGiverSkipUsed
        /// As ``playingClueGiver`` with unlimited skipping and three skips so far.
        case playingClueGiverUnlimited
        /// Round 1, a turn running, viewed by a guesser on the clue-giver's team (Casey).
        case playingGuesser
        /// Round 1, a turn running, viewed by a player on the other team (Drew).
        case playingOpponent
        /// Round 1, a turn running, viewed by a spectator (Gray).
        case playingSpectator
        /// Round 1 in `playing` but no player can be assigned (`nextUp` is nil), viewed by the host. The team whose turn
        /// it was is kept (`current_team`). ``SampleScenario/followUp`` is the snapshot after the host assigns the
        /// spectator to team 1, which makes the turn assignable again.
        case stalledHost
        /// The stalled room viewed by a non-host.
        case stalledGuest
        /// Round 1 over, viewed by the host (who sees Next Round).
        case roundEndHost
        /// Round 1 over, viewed by a guest.
        case roundEndGuest
        /// Game over, team 0 won 30-24. A departed player's turns are anonymised. Viewed by the host.
        case finishedWinner
        /// Game over, a 27-27 tie. Viewed by the host.
        case finishedTie
    }

    /// Which state this is.
    public var id: ID
    /// A short human-readable name, for preview titles.
    public var title: String
    /// The user viewing the room. Pass it to `RoomSnapshot` helpers and to ``FakeGameBackend/init(userID:snapshot:connection:draw:suggestions:)``.
    public var userID: UUID
    /// The room as that user would fetch it.
    public var snapshot: RoomSnapshot
    /// The clue-giver's private draw, or nil for every other viewer.
    public var draw: Draw?
    /// The snapshot the server publishes after this state's natural next step (host assigns the spectator, the empty
    /// window closes, the clue-giver starts the turn), or nil if the scenario has none. Script it with
    /// ``FakeGameBackend/script(_:snapshots:)`` to replay the transition.
    public var followUp: RoomSnapshot?

    /// Creates a scenario from parts.
    /// - Parameters:
    ///   - id: Which state this is.
    ///   - title: A short name.
    ///   - userID: The viewer.
    ///   - snapshot: The room.
    ///   - draw: The viewer's private draw, if any.
    ///   - followUp: The snapshot after the natural next step, if any.
    public init(id: ID, title: String, userID: UUID, snapshot: RoomSnapshot, draw: Draw? = nil, followUp: RoomSnapshot? = nil) {
        self.id = id
        self.title = title
        self.userID = userID
        self.snapshot = snapshot
        self.draw = draw
        self.followUp = followUp
    }

    /// The same room seen by another user. The draw is dropped, since only the clue-giver has one. The follow-up is kept.
    /// - Parameter userID: Any user in the snapshot's players.
    public func viewing(as userID: UUID) -> SampleScenario {
        var copy = self
        copy.userID = userID
        copy.draw = nil
        return copy
    }

    /// Builds one scenario.
    /// - Parameters:
    ///   - id: The state to build.
    ///   - now: The server time. Deadlines and turn ends are set relative to it. Defaults to the current time.
    public static func make(_ id: ID, now: Date = Date()) -> SampleScenario {
        SampleBuilder(now: now).scenario(id)
    }

    /// Builds every scenario, in ``ID`` order.
    /// - Parameter now: The server time.
    public static func all(now: Date = Date()) -> [SampleScenario] {
        ID.allCases.map { make($0, now: now) }
    }
}

// MARK: - Builder

/// Builds the scenarios from the rules in supabase/migrations: round starters (`_start_round`), rotation cursors
/// (`_finish_turn`), skip limits (`skip_slip`) and timestamps inside the room's lifetime.
private struct SampleBuilder {
    let now: Date

    static let roomID = UUID(uuidString: "B2000000-0000-4000-8000-000000000001")!
    static let teamNames = ["The Legends", "Night Owls"]
    static let names = [
        "Tom Hanks", "Taylor Swift", "Serena Williams", "Sherlock Holmes", "Beyoncé", "Lionel Messi",
        "Barack Obama", "Meryl Streep", "Cleopatra", "Harry Potter", "Elvis Presley", "Oprah Winfrey",
        "Albert Einstein", "Marilyn Monroe", "Bruce Lee", "Frida Kahlo", "Mister Rogers", "Dolly Parton",
    ]
    /// Original seating: team rosters in seat order.
    static let roster: [[SampleCast]] = [[.alex, .blair, .casey], [.drew, .emery, .frankie]]
    static let seats: [UUID: Int] = Dictionary(
        uniqueKeysWithValues: [SampleCast.alex, .blair, .casey, .drew, .emery, .frankie, .gray].enumerated().map { ($1.id, $0 + 1) }
    )
    static let turnLength: TimeInterval = 70
    static let blairDraw = Draw(
        id: UUID(uuidString: "C3000000-0000-4000-8000-000000000001")!,
        name: "Frida Kahlo",
        token: UUID(uuidString: "D4000000-0000-4000-8000-000000000001")!
    )

    // MARK: Scenarios

    func scenario(_ id: SampleScenario.ID) -> SampleScenario {
        switch id {
        case .lobbyHost: make(id, "Lobby (host)", .alex, lobby())
        case .lobbyGuest: make(id, "Lobby (guest)", .blair, lobby())
        case .lobbyUnevenHost: make(id, "Lobby, uneven teams (host)", .alex, lobbyUneven())
        case .submittingEditing: make(id, "Submitting (editing)", .alex, submitting())
        case .submittingWaiting: make(id, "Submitting (waiting)", .blair, submitting())
        case .submittingSpectator: make(id, "Submitting (spectator)", .gray, submitting())
        case .submittingRecommendationsOff: make(id, "Submitting, recommendations off", .alex, submitting(suggestions: false))
        case .submittingExpiredEmpty:
            make(id, "Submitting, window expired empty", .alex, submittingExpiredEmpty(), followUp: lobbyAfterEmptyWindow())
        case .playingClueGiverReady:
            make(id, "Playing, ready to start (clue-giver)", .blair, playing(skip: .onePerTurn, running: false),
                 draw: nil, followUp: playing(skip: .onePerTurn, running: true))
        case .playingClueGiver:
            make(id, "Playing (clue-giver)", .blair, playing(skip: .onePerTurn, running: true), draw: Self.blairDraw)
        case .playingClueGiverSkipOff:
            make(id, "Playing, skipping off (clue-giver)", .blair, playing(skip: .off, running: true), draw: Self.blairDraw)
        case .playingClueGiverSkipUsed:
            make(id, "Playing, skip used (clue-giver)", .blair, playing(skip: .onePerTurn, running: true, turnSkips: 1), draw: Self.blairDraw)
        case .playingClueGiverUnlimited:
            make(id, "Playing, unlimited skips (clue-giver)", .blair, playing(skip: .unlimited, running: true, turnSkips: 3), draw: Self.blairDraw)
        case .playingGuesser: make(id, "Playing (guesser)", .casey, playing(skip: .onePerTurn, running: true))
        case .playingOpponent: make(id, "Playing (opponent)", .drew, playing(skip: .onePerTurn, running: true))
        case .playingSpectator: make(id, "Playing (spectator)", .gray, playing(skip: .onePerTurn, running: true))
        case .stalledHost: make(id, "Stalled, no clue-giver (host)", .alex, stalled(), followUp: stalledAfterAssignment())
        case .stalledGuest: make(id, "Stalled, no clue-giver (guest)", .blair, stalled(), followUp: stalledAfterAssignment())
        case .roundEndHost: make(id, "Round end (host)", .alex, roundEnd())
        case .roundEndGuest: make(id, "Round end (guest)", .blair, roundEnd())
        case .finishedWinner:
            make(id, "Finished, winner (host)", .alex, finished(rounds: [[10, 8], [9, 9], [11, 7]], frankieLeft: true))
        case .finishedTie:
            make(id, "Finished, tie (host)", .alex, finished(rounds: [[10, 8], [8, 10], [9, 9]], frankieLeft: false))
        }
    }

    private func make(
        _ id: SampleScenario.ID, _ title: String, _ viewer: SampleCast, _ snapshot: RoomSnapshot,
        draw: Draw? = nil, followUp: RoomSnapshot? = nil
    ) -> SampleScenario {
        SampleScenario(id: id, title: title, userID: viewer.id, snapshot: snapshot, draw: draw, followUp: followUp)
    }

    // MARK: Pieces

    private func settings(skip: SkipMode = .off, suggestions: Bool = true) -> Settings {
        Settings(slipsPerPlayer: 3, turnSeconds: 60, submissionSeconds: 120, skipMode: skip, suggestionsEnabled: suggestions)
    }

    private func player(_ who: SampleCast, team: Int?, role: PlayerRole = .player, submitted: Bool = false) -> Player {
        Player(
            roomID: Self.roomID, userID: who.id, name: who.name, team: team, role: role,
            seat: Self.seats[who.id]!, submitted: submitted, lastSeenAt: now
        )
    }

    private func room(
        phase: RoomPhase,
        round: Int,
        createdAt: Date,
        settings: Settings,
        deadline: Date? = nil,
        currentTeam: Int? = nil,
        turnIdx: [Int] = [0, 0],
        turnPlayer: SampleCast? = nil,
        turnEndsAt: Date? = nil,
        turnGot: Int = 0,
        turnSkips: Int = 0,
        pile: Int = 0,
        scores: [[Int]] = [[0, 0], [0, 0], [0, 0]],
        finishedAt: Date? = nil
    ) -> Room {
        Room(
            id: Self.roomID, code: "K7Q2", hostID: SampleCast.alex.id, phase: phase, round: round,
            teamNames: Self.teamNames, settings: settings, submissionDeadline: deadline, currentTeam: currentTeam,
            turnIdx: turnIdx, turnPlayerID: turnPlayer?.id, turnEndsAt: turnEndsAt, turnGot: turnGot,
            turnSkips: turnSkips, pileCount: pile, scores: scores, lastActivityAt: finishedAt ?? now,
            createdAt: createdAt, finishedAt: finishedAt
        )
    }

    private func snapshot(_ room: Room, _ players: [Player], _ turns: [Turn] = []) -> RoomSnapshot {
        RoomSnapshot(room: room, players: players.sorted { $0.seat < $1.seat }, turns: turns, serverNow: now)
    }

    private func teamed(submitted: Set<UUID> = []) -> [Player] {
        var result: [Player] = []
        for (team, members) in Self.roster.enumerated() {
            for who in members { result.append(player(who, team: team, submitted: submitted.contains(who.id))) }
        }
        return result
    }

    // MARK: Lobby and submission

    private func lobby() -> RoomSnapshot {
        snapshot(room(phase: .lobby, round: 0, createdAt: now - 300, settings: settings()), teamed() + [player(.gray, team: nil)])
    }

    /// Team 1 has one player (Drew); Emery and Gray have no team. Frankie never joined.
    private func lobbyUneven() -> RoomSnapshot {
        let players = [
            player(.alex, team: 0), player(.blair, team: 0), player(.casey, team: 0),
            player(.drew, team: 1), player(.emery, team: nil), player(.gray, team: nil),
        ]
        return snapshot(room(phase: .lobby, round: 0, createdAt: now - 300, settings: settings()), players)
    }

    private func submitting(suggestions: Bool = true) -> RoomSnapshot {
        let submitted: Set<UUID> = [SampleCast.blair.id, SampleCast.drew.id, SampleCast.emery.id]
        return snapshot(
            room(phase: .submitting, round: 0, createdAt: now - 300, settings: settings(suggestions: suggestions), deadline: now + 90),
            teamed(submitted: submitted) + [player(.gray, team: nil, role: .spectator)]
        )
    }

    private func submittingExpiredEmpty() -> RoomSnapshot {
        snapshot(
            room(phase: .submitting, round: 0, createdAt: now - 300, settings: settings(), deadline: now - 2),
            teamed() + [player(.gray, team: nil, role: .spectator)]
        )
    }

    /// `close_submissions` with no slips: back to the lobby, deadline cleared, submitted flags cleared. Players who were
    /// made spectators by `start_game` stay spectators.
    private func lobbyAfterEmptyWindow() -> RoomSnapshot {
        snapshot(
            room(phase: .lobby, round: 0, createdAt: now - 300, settings: settings()),
            teamed() + [player(.gray, team: nil, role: .spectator)]
        )
    }

    // MARK: History

    private struct TurnPlan {
        var round: Int
        var team: Int
        var count: Int
    }

    /// Plans every turn of the given completed rounds. The round starter is team `(round - 1) % 2`, teams alternate,
    /// each team takes three turns, and the guessed total of each team is split as evenly as possible.
    private func plans(rounds scores: [[Int]]) -> [TurnPlan] {
        var result: [TurnPlan] = []
        for (index, pair) in scores.enumerated() {
            let starter = index % 2
            for slot in 0..<6 {
                let team = (starter + slot) % 2
                let turn = slot / 2
                let total = pair[team]
                result.append(TurnPlan(round: index + 1, team: team, count: total / 3 + (turn < total % 3 ? 1 : 0)))
            }
        }
        return result
    }

    /// Writes the history for `plans`, rotating clue-givers from cursor `[0, 0]` and ending the last turn at `anchor`.
    /// Returns the turns and the rotation cursors after them. `skipMode` bounds the skip counts.
    private func history(_ plans: [TurnPlan], endingAt anchor: Date, skip: SkipMode, left: Set<UUID> = []) -> (turns: [Turn], idx: [Int]) {
        var idx = [0, 0]
        var nextName = 0
        var turns: [Turn] = []
        for (i, plan) in plans.enumerated() {
            let who = Self.roster[plan.team][idx[plan.team] % 3]
            idx[plan.team] += 1
            let guessed = (0..<plan.count).map { _ -> String in
                defer { nextName += 1 }
                return Self.names[nextName % Self.names.count]
            }
            let gone = left.contains(who.id)
            turns.append(Turn(
                id: Int64(i + 1), roomID: Self.roomID, round: plan.round, team: plan.team,
                playerID: gone ? nil : who.id, playerName: gone ? "Former player" : who.name,
                guessed: guessed, skipped: skip == .off ? 0 : i % 2,
                endedAt: anchor - Self.turnLength * Double(plans.count - 1 - i)
            ))
        }
        return (turns, idx)
    }

    // MARK: Playing

    /// Round 1. Alex (team 0) guessed 3, Drew (team 1) guessed 2, now Blair (team 0, cursor 1) is up.
    /// `running` false is the moment before Start Turn.
    private func playing(skip: SkipMode, running: Bool, turnSkips: Int = 0) -> RoomSnapshot {
        let (turns, idx) = history([TurnPlan(round: 1, team: 0, count: 3), TurnPlan(round: 1, team: 1, count: 2)], endingAt: now - 90, skip: skip)
        let got = running ? 2 : 0
        let created = now - 600
        return snapshot(
            room(
                phase: .playing, round: 1, createdAt: created, settings: settings(skip: skip),
                deadline: created + 60 + 120, currentTeam: 0, turnIdx: idx, turnPlayer: .blair,
                turnEndsAt: running ? now + 38 : nil, turnGot: got, turnSkips: running ? turnSkips : 0,
                pile: 18 - 5 - got, scores: [[3 + got, 2], [0, 0], [0, 0]]
            ),
            teamed(submitted: Set(Self.seats.keys)) + [player(.gray, team: nil, role: .spectator)],
            turns
        )
    }

    /// Alex (team 0) and Blair (team 1) are left, plus spectator Gray. Alex took the first turn, so it is team 1's turn,
    /// but a team needs two players and neither has them: `current_team` stays 1, `turn_player_id` is null.
    private func stalled() -> RoomSnapshot {
        let (turns, idx) = history([TurnPlan(round: 1, team: 0, count: 2)], endingAt: now - 40, skip: .off)
        let created = now - 600
        return snapshot(
            room(
                phase: .playing, round: 1, createdAt: created, settings: settings(), deadline: created + 180,
                currentTeam: 1, turnIdx: idx, pile: 16, scores: [[2, 0], [0, 0], [0, 0]]
            ),
            [player(.alex, team: 0, submitted: true), player(.blair, team: 1, submitted: true), player(.gray, team: nil, role: .spectator)],
            turns
        )
    }

    /// `assign_spectator(gray, 1)`: Gray becomes a team 1 player (not yet submitted), team 1 can play again, and the
    /// rotation points at Blair, the first of team 1 by seat. The cursor is unchanged because Gray sits after it.
    private func stalledAfterAssignment() -> RoomSnapshot {
        var snap = stalled()
        snap.players = snap.players.map { p in
            guard p.userID == SampleCast.gray.id else { return p }
            var moved = p
            moved.role = .player
            moved.team = 1
            moved.submitted = false
            return moved
        }
        snap.room.turnPlayerID = SampleCast.blair.id
        return snap
    }

    // MARK: Round end and finished

    private func roundEnd() -> RoomSnapshot {
        let (turns, idx) = history(plans(rounds: [[10, 8]]), endingAt: now - 30, skip: .onePerTurn)
        return snapshot(
            room(
                phase: .roundEnd, round: 1, createdAt: now - 1500, settings: settings(skip: .onePerTurn),
                deadline: now - 1500 + 180, turnIdx: idx, scores: [[10, 8], [0, 0], [0, 0]]
            ),
            teamed(submitted: Set(Self.seats.keys)) + [player(.gray, team: nil, role: .spectator)],
            turns
        )
    }

    /// Three full rounds. With `frankieLeft`, Frankie left after the game and deleted their data: their turns show as
    /// "Former player" with no player id, they are gone from `players` (other seats keep their numbers), and team 1's
    /// cursor was reduced modulo the smaller roster as `kick_player` does.
    private func finished(rounds: [[Int]], frankieLeft: Bool) -> RoomSnapshot {
        let gone: Set<UUID> = frankieLeft ? [SampleCast.frankie.id] : []
        let (turns, idx) = history(plans(rounds: rounds), endingAt: now - 30, skip: .onePerTurn, left: gone)
        var players = teamed(submitted: Set(Self.seats.keys)) + [player(.gray, team: nil, role: .spectator)]
        var cursor = idx
        if frankieLeft {
            players.removeAll { gone.contains($0.userID) }
            cursor[1] = (idx[1] % 3) % 2
        }
        return snapshot(
            room(
                phase: .finished, round: 3, createdAt: now - 3000, settings: settings(skip: .onePerTurn),
                deadline: now - 3000 + 180, turnIdx: cursor, scores: rounds, finishedAt: now - 30
            ),
            players,
            turns
        )
    }
}
