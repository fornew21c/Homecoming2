import SwiftUI

@main
struct HomecomingApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView(environment: delegate.environment)
        }
    }
}
