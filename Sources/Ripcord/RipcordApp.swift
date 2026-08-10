import SwiftUI

@main
struct RipcordApp: App {
    var body: some Scene {
        Window("Ripcord", id: "main") {
            ContentView()
                .frame(minWidth: 780, idealWidth: 820, minHeight: 600, idealHeight: 660)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
