import SwiftUI

@main
struct BrushEngineApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 400, minHeight: 300)
        }
        .windowResizability(.contentSize)
    }
}
