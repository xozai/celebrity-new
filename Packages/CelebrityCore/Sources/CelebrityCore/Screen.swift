public enum Screen: Sendable, Equatable {
    case home
    case lobby
    case submit
    case game
    case finished

    public static func from(snapshot: RoomSnapshot?) -> Screen {
        switch snapshot?.room.phase {
        case nil: .home
        case .lobby: .lobby
        case .submitting: .submit
        case .playing, .roundEnd: .game
        case .finished: .finished
        }
    }
}
