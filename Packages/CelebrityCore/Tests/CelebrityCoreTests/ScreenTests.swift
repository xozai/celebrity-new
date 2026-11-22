import Testing
import CelebrityCore

@Test(arguments: [
    (nil, .home), (.lobby, .lobby), (.submitting, .submit),
    (.playing, .game), (.roundEnd, .game), (.finished, .finished),
] as [(RoomPhase?, Screen)])
func routesEveryPhase(phase: RoomPhase?, screen: Screen) throws {
    var snapshot: RoomSnapshot?
    if let phase {
        snapshot = try fixture()
        snapshot?.room.phase = phase
    }
    #expect(Screen.from(snapshot: snapshot) == screen)
}
