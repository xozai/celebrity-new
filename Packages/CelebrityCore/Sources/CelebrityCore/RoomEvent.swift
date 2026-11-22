public enum RoomEvent: Sendable, Equatable {
    case roundStarting
    case turnStarted
    case turnEnded(Turn)
    case roundEnded
    case gameEnded
    case kicked
    case hostChanged
    case submissionsAutoClosed
}
