import Testing
import CelebrityCore

@Test func namesAreTrimmedAndValidatedByCharacterCount() {
    #expect(Validation.playerName("  Zoë \n") == "Zoë")
    #expect(Validation.playerName(" \n ") == nil)
    let twenty = String(repeating: "👩🏽‍🚀", count: 20)
    #expect(Validation.playerName(twenty) == twenty)
    #expect(Validation.playerName(twenty + "a") == nil)
    #expect(Validation.teamName("  Stars  ") == "Stars")
    #expect(Validation.teamName(String(repeating: "a", count: 21)) == nil)
    #expect(Validation.slipName(String(repeating: "a", count: 60)) != nil)
    #expect(Validation.slipName(String(repeating: "a", count: 61)) == nil)
}

@Test func submissionKeepsIdenticalNamesAndRejectsInvalidEntries() {
    #expect(Validation.submissionNames([" Beyoncé ", "Beyoncé"]) == ["Beyoncé", "Beyoncé"])
    #expect(Validation.submissionNames(["Beyoncé", " "]) == nil)
}

@Test(arguments: [
    (" ab24\n", "AB24"), ("AB2", nil), ("AB240", nil), ("A B24", nil),
    ("AIO1", nil), ("AB04", nil), ("ſB24", nil),
] as [(String, String?)])
func normalizesRoomCode(input: String, expected: String?) {
    #expect(Validation.roomCode(input) == expected)
}

@Test(arguments: [
    (" https://celeb.xozai.com/join/ab24 ", "AB24"),
    ("http://celeb.xozai.com/join/AB24", nil),
    ("https://celeb.xozai.com.evil.example/join/AB24", nil),
    ("https://guest@celeb.xozai.com/join/AB24", nil),
    ("https://celeb.xozai.com:1234/join/AB24", nil),
    ("https://celeb.xozai.com:443/join/AB24/?source=share#invite", nil),
    ("https://celeb.xozai.com/JOIN/AB24", nil),
    ("https://celeb.xozai.com/join/AB24/extra", nil),
    ("https://celeb.xozai.com/join/AB24/", "AB24"),
    ("https://celeb.xozai.com/join/AB24?code=AB25", "AB24"),
    ("https://celeb.xozai.com/join/AB24#invite", "AB24"),
    ("https://celeb.xozai.com/join/ab24/?source=share#invite", "AB24"),
    ("https://celeb.xozai.com/join//AB24", nil),
    ("https://celeb.xozai.com/join/?code=AB24", nil),
    ("https://celeb.xozai.com/join/%41B24", nil),
    ("https://celeb.xozai.com/join/%41B24/?source=share#invite", nil),
] as [(String, String?)])
func parsesJoinLinks(input: String, expected: String?) {
    #expect(Validation.joinCode(from: input) == expected)
}

@Test(arguments: [
    (1, "Say Anything", "name"),
    (2, "One Word", "one word"),
    (3, "Charades", "without speaking"),
])
func providesRoundRules(round: Int, title: String, detail: String) {
    let rules = RoundRules(rawValue: round)
    #expect(rules?.title == title)
    #expect(rules?.description.contains(detail) == true)
}

@Test func onlyThreeRoundsHaveRules() {
    #expect(RoundRules.allCases.count == CelebrityCore.roundCount)
    #expect(RoundRules(rawValue: 0) == nil)
    #expect(RoundRules(rawValue: 4) == nil)
}
