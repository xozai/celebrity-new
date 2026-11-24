import CelebrityBackend
import Supabase

/// Placeholder for the Supabase implementation of `GameBackend` (docs/PLAN.md Tasks 3.3 and 3.4).
///
/// This target is the only one in the package that links the Supabase SDK. Link it from the app's
/// composition root and from integration tests; previews and fake-based tests need only `CelebrityBackend`.
public enum CelebrityBackendSupabase {
    /// The round count seen through the `CelebrityBackend` interface target.
    public static let interfaceRoundCount = CelebrityBackend.roundCount

    /// True once the Supabase SDK is linked into this target.
    public static let sdkIsLinked: Bool = {
        _ = SupabaseClient.self
        return true
    }()
}
