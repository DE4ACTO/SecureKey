import SwiftUI

@main
struct SecureKeyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Скрываем заголовок окна и делаем его прозрачным
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
    }
}
