import Foundation

public enum RoomEventDeriver {
    public static func events(old: RoomSnapshot?, new: RoomSnapshot?, userID: UUID) -> [RoomEvent] {
        guard let old, let new, old.room.id == new.room.id else { return [] }
        if old.me(userID: userID) != nil && new.me(userID: userID) == nil {
            return [.kicked]
        }

        var events: [RoomEvent] = []
        if old.room.hostID != new.room.hostID {
            events.append(.hostChanged)
        }

        let oldTurnIDs = Set(old.turns.map(\.id))
        let completedTurns = new.turns.filter { !oldTurnIDs.contains($0.id) }.sorted {
            if $0.endedAt != $1.endedAt { return $0.endedAt < $1.endedAt }
            return $0.id < $1.id
        }
        events.append(contentsOf: completedTurns.map(RoomEvent.turnEnded))

        let before = old.room
        let after = new.room
        if after.phase == .playing {
            if before.phase == .submitting,
               let deadline = before.submissionDeadline,
               new.serverNow >= deadline,
               new.players.contains(where: { $0.role == .player && !$0.submitted }) {
                events.append(.submissionsAutoClosed)
            }
            if before.phase != .playing || before.round != after.round {
                events.append(.roundStarting)
            }
            if new.nextUp != nil, after.turnEndsAt != nil,
               before.phase != .playing || before.round != after.round
                   || before.turnEndsAt != after.turnEndsAt || before.turnPlayerID != after.turnPlayerID {
                events.append(.turnStarted)
            }
        } else if before.phase != after.phase {
            if after.phase == .roundEnd { events.append(.roundEnded) }
            if after.phase == .finished { events.append(.gameEnded) }
        }
        return events
    }
}
