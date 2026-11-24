import CelebrityBackend
import Supabase
import Testing
@testable import CelebrityBackendSupabase

@Test func supabaseAdapterSeesTheSDKAndTheBackendInterface() {
    #expect(CelebrityBackendSupabase.interfaceRoundCount == CelebrityBackend.roundCount)
    #expect(CelebrityBackendSupabase.sdkIsLinked)
}
