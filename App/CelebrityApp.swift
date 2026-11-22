import SwiftUI

@main
struct CelebrityApp: App {
    var body: some Scene {
        WindowGroup {
            PlaceholderView()
        }
    }
}

struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Celebrity Celebrity")
                .font(.largeTitle.bold())
            Text("Coming soon")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    PlaceholderView()
}
