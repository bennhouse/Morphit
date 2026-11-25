import AppKit
import SwiftUI

struct MorphitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Morphit", id: "main") {
            ContentView()
                .environment(model)
                // No scroll bars anywhere: with "Always show" they took space and lists changed width.
                .scrollIndicators(.never)
        }
        .defaultSize(width: 820, height: 600)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { MainActions.openPanel() }.keyboardShortcut("o")
            }
        }
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Snapshots.startIfRequested() }
    }

    /// Files dropped on the Dock icon or opened with "Open With › Morphit".
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { Converter.shared.add(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = MainActor.assumeIsolated { Converter.shared.isRunning }
        guard running else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "A conversion is in progress"
        a.informativeText = "Quitting stops it. Files not finished yet are discarded; originals are left untouched."
        a.addButton(withTitle: "Quit")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        // Stop, and quit once every conversion has ended and removed its partial file.
        MainActor.assumeIsolated {
            Converter.shared.stop()
            Task { @MainActor in
                while Converter.shared.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

// Command-line test modes (the tools are found through MORPHIT_TOOLS outside the app bundle):
//   Morphit --probe FILE
//   Morphit --convert '<template JSON>' [--out DIR] [--cpu low|balanced|maximum] [--trash] FILE...
let args = CommandLine.arguments
if args.count > 1, ["--probe", "--convert", "--plan", "--settings-roundtrip"].contains(args[1]) {
    Task { @MainActor in
        await CLI.run(Array(args.dropFirst()))
        exit(0)
    }
    RunLoop.main.run()
} else {
    MorphitApp.main()
}
