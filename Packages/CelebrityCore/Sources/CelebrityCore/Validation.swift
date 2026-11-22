import Foundation

public enum Validation {
    public static let playerNameLimit = 20
    public static let teamNameLimit = 20
    public static let slipNameLimit = 60

    private static let roomCodeAlphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789".utf8)

    public static func playerName(_ input: String) -> String? {
        name(input, limit: playerNameLimit)
    }

    public static func teamName(_ input: String) -> String? {
        name(input, limit: teamNameLimit)
    }

    public static func slipName(_ input: String) -> String? {
        name(input, limit: slipNameLimit)
    }

    /// Validates each entry in order and preserves duplicate slips.
    public static func submissionNames(_ inputs: [String]) -> [String]? {
        var names: [String] = []
        for input in inputs {
            guard let name = slipName(input) else { return nil }
            names.append(name)
        }
        return names
    }

    public static func roomCode(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count == 4, trimmed.utf8.allSatisfy({ $0 < 128 }) else { return nil }
        let code = trimmed.uppercased()
        return code.utf8.allSatisfy(roomCodeAlphabet.contains) ? code : nil
    }

    public static func joinCode(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.percentEncodedHost?.lowercased() == "celeb.xozai.com",
              url.user == nil, url.password == nil, url.port == nil,
              url.percentEncodedPath.hasPrefix("/join/") else { return nil }

        let code = url.percentEncodedPath.dropFirst("/join/".count)
        return roomCode(String(code.hasSuffix("/") ? code.dropLast() : code))
    }

    private static func name(_ input: String, limit: Int) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...limit).contains(trimmed.count) ? trimmed : nil
    }
}
