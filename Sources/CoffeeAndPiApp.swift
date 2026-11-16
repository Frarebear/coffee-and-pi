import SwiftUI

@main
struct CoffeeAndPiApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 960, minHeight: 640)
                .task {
                    await appModel.bootstrap()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    Task { await appModel.newChat() }
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appModel)
        }
    }
}
