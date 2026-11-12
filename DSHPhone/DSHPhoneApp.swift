import SwiftUI

@main
struct DSHPhoneApp: App {
    @StateObject private var discovery = DiscoveryService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(discovery)
                .onAppear { discovery.start() }
        }
    }
}
