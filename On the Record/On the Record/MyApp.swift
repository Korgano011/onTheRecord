import SwiftUI

@main struct MyApp: App {
    #if os(iOS) || os(visionOS)
    /// Accepts invitations to shared agreements.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
