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
    /// Twelve well-known names with descriptions, across categories.
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
        /// Submitting, viewed by a player who has not submitted yet.
        case submittingEditing
        /// Submitting, viewed by a player who already submitted.
        case submittingWaiting
        /// Submitting, viewed by a spectator.
        case submittingSpectator
        /// Round 1, a turn running, viewed by the clue-giver (host). Includes the draw. Skip mode is one per turn.
        case playingClueGiver
        /// Round 1, a turn running, viewed by a guesser on the clue-giver's team.
        case playingGuesser
        /// Round 1, a turn running, viewed by a player on the other team.
        case playingOpponent
        /// Round 1, a turn running, viewed by a spectator.
        case playingSpectator
        /// Round 1 in `playing` but no player can be assigned (`nextUp` is nil), viewed by the host.
        case stalledHost
        /// The stalled room viewed by a non-host.
        case stalledGuest
        /// Round 1 over, viewed by the host (who sees Next Round).
        case roundEndHost
        /// Round 1 over, viewed by a guest.
        case roundEndGuest
        /// Game over, team 0 won 30-24. History includes an anonymised turn. Viewed by the host.
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

    /// Creates a scenario from parts.
    /// - Parameters:
    ///   - id: Which state this is.
    ///   - title: A short name.
    ///   - userID: The viewer.
    ///   - snapshot: The room.
    ///   - draw: The viewer's private draw, if any.
    public init(id: ID, title: String, userID: UUID, snapshot: RoomSnapshot, draw: Draw? = nil) {
        self.id = id
        self.title = title
        self.userID = userID
        self.snapshot = snapshot
        self.draw = draw
    }

    /// The same room seen by another user. The draw is dropped, since only the clue-giver has one.
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

private struct SampleBuilder {
    let now: Date

    static let roomID = UUID(uuidString: "B2000000-0000-4000-8000-000000000001")!
    static let teamNames = ["The Legends", "Night Owls"]
    static let names = [
        "Tom Hanks", "Taylor Swift", "Serena Williams", "Sherlock Holmes", "Beyoncé", "Lionel Messi",
        "Barack Obama", "Meryl Streep", "Cleopatra", "Harry Potter", "Elvis Presley", "Oprah Winfrey",
        "Albert Einstein", "Marilyn Monroe", "Bruce Lee", "Frida Kahlo", "Mister Rogers", "Dolly Parton",
    ]

    func scenario(_ id: SampleScenario.ID) -> SampleScenario {
        switch id {
        case .lobbyHost:
            make(id, "Lobby (host)", .alex, lobby(unassigned: [.gray]))
        case .lobbyGuest:
            make(id, "Lobby (guest)", .blair, lobby(unassigned: [.gray]))
        case .lobbyUnevenHost:
            make(id, "Lobby, uneven teams (host)", .alex, lobby(unassigned: [.emery, .gray], dropFromTeams: [.frankie]))
        case .submittingEditing:
            make(id, "Submitting (editing)", .alex, submitting())
        case .submittingWaiting:
            make(id, "Submitting (waiting)", .blair, submitting())
        case .submittingSpectator:
            make(id, "Submitting (spectator)", .gray, submitting())
        case .playingClueGiver:
            make(id, "Playing (clue-giver)", .alex, playing(), draw: Draw(
                id: UUID(uuidString: "C3000000-0000-4000-8000-000000000001")!,
                name: "Beyoncé",
                token: UUID(uuidString: "D4000000-0000-4000-8000-000000000001")!
            ))
        case .playingGuesser:
            make(id, "Playing (guesser)", .blair, playing())
        case .playingOpponent:
            make(id, "Playing (opponent)", .drew, playing())
        case .playingSpectator:
            make(id, "Playing (spectator)", .gray, playing())
        case .stalledHost:
            make(id, "Stalled, no clue-giver (host)", .alex, stalled())
        case .stalledGuest:
            make(id, "Stalled, no clue-giver (guest)", .blair, stalled())
        case .roundEndHost:
            make(id, "Round end (host)", .alex, roundEnd())
        case .roundEndGuest:
            make(id, "Round end (guest)", .blair, roundEnd())
        case .finishedWinner:
            make(id, "Finished, winner (host)", .alex, finished(rounds: [[10, 8], [9, 9], [11, 7]], anonymiseFormerPlayer: true))
        case .finishedTie:
            make(id, "Finished, tie (host)", .alex, finished(rounds: [[10, 8], [8, 10], [9, 9]], anonymiseFormerPlayer: false))
        }
    }

    private func make(_ id: SampleScenario.ID, _ title: String, _ viewer: SampleCast, _ snapshot: RoomSnapshot, draw: Draw? = nil) -> SampleScenario {
        SampleScenario(id: id, title: title, userID: viewer.id, snapshot: snapshot, draw: draw)
    }

    // MARK: Pieces

    private func settings(skip: SkipMode = .off) -> Settings {
        Settings(slipsPerPlayer: 3, turnSeconds: 60, submissionSeconds: 120, skipMode: skip, suggestionsEnabled: true)
    }

    private func player(_ who: SampleCast, seat: Int, team: Int?, role: PlayerRole = .player, submitted: Bool = false) -> Player {
        Player(roomID: Self.roomID, userID: who.id, name: who.name, team: team, role: role, seat: seat, submitted: submitted, lastSeenAt: now)
    }

    private func room(
        phase: RoomPhase,
        round: Int,
        host: SampleCast?,
        settings: Settings,
        deadline: Date? = nil,
        currentTeam: Int? = nil,
        turnPlayer: SampleCast? = nil,
        turnEndsAt: Date? = nil,
        turnGot: Int = 0,
        pile: Int = 0,
        scores: [[Int]] = [[0, 0], [0, 0], [0, 0]],
        finishedAt: Date? = nil
    ) -> Room {
        Room(
            id: Self.roomID,
            code: "K7Q2",
            hostID: host?.id,
            phase: phase,
            round: round,
            teamNames: Self.teamNames,
            settings: settings,
            submissionDeadline: deadline,
            currentTeam: currentTeam,
            turnIdx: [0, 1],
            turnPlayerID: turnPlayer?.id,
            turnEndsAt: turnEndsAt,
            turnGot: turnGot,
            turnSkips: 0,
            pileCount: pile,
            scores: scores,
            lastActivityAt: now,
            createdAt: now.addingTimeInterval(-600),
            finishedAt: finishedAt
        )
    }

    private func snapshot(_ room: Room, _ players: [Player], _ turns: [Turn] = []) -> RoomSnapshot {
        RoomSnapshot(room: room, players: players, turns: turns, serverNow: now)
    }

    /// Alex, Blair, Casey on team 0 and Drew, Emery, Frankie on team 1, with the given submitted flags.
    private func sixPlayers(submitted: Set<UUID> = []) -> [Player] {
        let cast: [(SampleCast, Int)] = [
            (.alex, 0), (.blair, 0), (.casey, 0), (.drew, 1), (.emery, 1), (.frankie, 1),
        ]
        return cast.enumerated().map { index, entry in
            player(entry.0, seat: index + 1, team: entry.1, submitted: submitted.contains(entry.0.id))
        }
    }

    // MARK: Phases

    private func lobby(unassigned: [SampleCast], dropFromTeams: [SampleCast] = []) -> RoomSnapshot {
        var players = sixPlayers().filter { who in !dropFromTeams.contains { $0.id == who.userID } && !unassigned.contains { $0.id == who.userID } }
        // Unassigned players keep their seat but have no team.
        let seats = Dictionary(uniqueKeysWithValues: ([SampleCast.alex, .blair, .casey, .drew, .emery, .frankie, .gray]).enumerated().map { ($1.id, $0 + 1) })
        for who in unassigned { players.append(player(who, seat: seats[who.id]!, team: nil)) }
        // A player dropped from the teams (uneven lobby) is simply not in the room.
        players.sort { $0.seat < $1.seat }
        players = players.enumerated().map { index, p in var p = p; p.seat = index + 1; return p }
        return snapshot(room(phase: .lobby, round: 0, host: .alex, settings: settings()), players)
    }

    private func submitting() -> RoomSnapshot {
        var players = sixPlayers(submitted: [SampleCast.blair.id, SampleCast.drew.id, SampleCast.emery.id])
        players.append(player(.gray, seat: 7, team: nil, role: .spectator))
        return snapshot(
            room(phase: .submitting, round: 0, host: .alex, settings: settings(), deadline: now.addingTimeInterval(90)),
            players
        )
    }

    private func allSubmittedPlayers() -> [Player] {
        var players = sixPlayers(submitted: Set(sixPlayers().map(\.userID)))
        players.append(player(.gray, seat: 7, team: nil, role: .spectator))
        return players
    }

    private func playing() -> RoomSnapshot {
        let earlier = Turn(
            id: 1, roomID: Self.roomID, round: 1, team: 1, playerID: SampleCast.drew.id, playerName: "Drew",
            guessed: ["Sherlock Holmes"], skipped: 0, endedAt: now.addingTimeInterval(-70)
        )
        return snapshot(
            room(
                phase: .playing, round: 1, host: .alex, settings: settings(skip: .onePerTurn),
                currentTeam: 0, turnPlayer: .alex, turnEndsAt: now.addingTimeInterval(38), turnGot: 2,
                pile: 15, scores: [[2, 1], [0, 0], [0, 0]]
            ),
            allSubmittedPlayers(),
            [earlier]
        )
    }

    private func stalled() -> RoomSnapshot {
        let players = [
            player(.alex, seat: 1, team: 0, submitted: true),
            player(.blair, seat: 2, team: 1, submitted: true),
            player(.gray, seat: 3, team: nil, role: .spectator),
        ]
        let earlier = [
            Turn(id: 1, roomID: Self.roomID, round: 1, team: 0, playerID: SampleCast.alex.id, playerName: "Alex",
                 guessed: ["Tom Hanks", "Cleopatra"], skipped: 0, endedAt: now.addingTimeInterval(-120)),
            Turn(id: 2, roomID: Self.roomID, round: 1, team: 1, playerID: SampleCast.blair.id, playerName: "Blair",
                 guessed: ["Elvis Presley"], skipped: 0, endedAt: now.addingTimeInterval(-60)),
        ]
        return snapshot(
            room(phase: .playing, round: 1, host: .alex, settings: settings(), pile: 9, scores: [[2, 1], [0, 0], [0, 0]]),
            players,
            earlier
        )
    }

    private func roundEnd() -> RoomSnapshot {
        snapshot(
            room(phase: .roundEnd, round: 1, host: .alex, settings: settings(), scores: [[10, 8], [0, 0], [0, 0]]),
            allSubmittedPlayers(),
            turns(forRoundsScores: [[10, 8]], anonymiseFormerPlayer: false)
        )
    }

    private func finished(rounds: [[Int]], anonymiseFormerPlayer: Bool) -> RoomSnapshot {
        var players = allSubmittedPlayers()
        if anonymiseFormerPlayer { players = players.filter { $0.userID != SampleCast.frankie.id }.enumerated().map { var p = $1; p.seat = $0 + 1; return p } }
        return snapshot(
            room(phase: .finished, round: 3, host: .alex, settings: settings(), scores: rounds, finishedAt: now.addingTimeInterval(-30)),
            players,
            turns(forRoundsScores: rounds, anonymiseFormerPlayer: anonymiseFormerPlayer)
        )
    }

    // MARK: History

    /// Builds a turn history whose guessed counts add up to each round's scores. Teams alternate, three turns each,
    /// rotating through their players. Every other turn has one skip. With `anonymiseFormerPlayer`, Frankie (who has left
    /// and deleted their data) appears as "Former player" with no player id.
    private func turns(forRoundsScores scores: [[Int]], anonymiseFormerPlayer: Bool) -> [Turn] {
        let teamPlayers: [[SampleCast]] = [[.alex, .blair, .casey], [.drew, .emery, .frankie]]
        var result: [Turn] = []
        var nextName = 0
        var nextID: Int64 = 1
        var clock = now.addingTimeInterval(-Double(scores.count * 6 * 60 + 60))
        for (roundIndex, pair) in scores.enumerated() {
            let split = pair.map { total in (0..<3).map { total / 3 + ($0 < total % 3 ? 1 : 0) } }
            for slot in 0..<6 {
                // Team 0 and team 1 alternate; the slot's turn index within its team is slot / 2.
                let team = slot % 2
                let turnIndex = slot / 2
                let who = teamPlayers[team][turnIndex]
                let count = split[team][turnIndex]
                let guessed = (0..<count).map { _ -> String in
                    defer { nextName += 1 }
                    return Self.names[nextName % Self.names.count]
                }
                clock = clock.addingTimeInterval(60)
                let anonymous = anonymiseFormerPlayer && who.id == SampleCast.frankie.id
                result.append(Turn(
                    id: nextID, roomID: Self.roomID, round: roundIndex + 1, team: team,
                    playerID: anonymous ? nil : who.id, playerName: anonymous ? "Former player" : who.name,
                    guessed: guessed, skipped: slot % 2 == 0 ? 1 : 0, endedAt: clock
                ))
                nextID += 1
            }
        }
        return result
    }
}
