import SwiftUI

@main
struct PM3KitApp: App {
    @StateObject private var store = CardStore()

    var body: some Scene {
        WindowGroup("pm3-kit") {
            ContentView().environmentObject(store)
        }
        .windowResizability(.contentMinSize)

        Settings {
            PM3SettingsView().environmentObject(store)
        }
    }
}
