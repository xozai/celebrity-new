public enum RoundRules: Int, CaseIterable, Sendable, CustomStringConvertible {
    case sayAnything = 1
    case oneWord
    case charades

    public var title: String {
        switch self {
        case .sayAnything: "Say Anything"
        case .oneWord: "One Word"
        case .charades: "Charades"
        }
    }

    public var description: String {
        switch self {
        case .sayAnything: "Describe the celebrity without saying any part of their name."
        case .oneWord: "Give exactly one word as a clue for each celebrity."
        case .charades: "Act out the celebrity without speaking or making sounds."
        }
    }
}
