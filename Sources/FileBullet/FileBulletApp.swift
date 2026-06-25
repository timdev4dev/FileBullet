import SwiftUI
import AppKit

/// Ensures the app behaves as a normal foreground GUI app even when launched
/// via `swift run` (no .app bundle), so it gets a Dock icon, menu bar and focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct FileBulletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup("FileBullet") {
            ContentView(app: app)
                .frame(minWidth: 760, minHeight: 500)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button(loc("New Tab", "Новая вкладка", "Neuer Tab", "Nueva pestaña")) { app.addSession() }
                    .keyboardShortcut("t", modifiers: .command)
                Button(loc("Close Tab", "Закрыть вкладку", "Tab schließen", "Cerrar pestaña")) {
                    if let s = app.selected { app.close(s) }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button(loc("Refresh", "Обновить", "Aktualisieren", "Actualizar")) {
                    if let s = app.selected, s.isConnected {
                        Task { await s.refresh() }
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
