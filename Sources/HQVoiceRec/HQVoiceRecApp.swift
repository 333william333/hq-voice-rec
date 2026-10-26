import AppKit
import SwiftUI

@main
struct HQVoiceRecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("HQ Voice Rec", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 660)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Inspelning") {
                Button(model.isRecording ? "Stoppa och spara" : "Spela in") { model.toggleRecording() }
                    .keyboardShortcut("r")
                    .disabled(!model.isRunning)
                Button("Skapa komprimerad kopia…") {
                    if let item = model.recordings.first(where: { $0.url == model.selectedRecording }) {
                        model.makeCompressedCopy(of: item)
                    }
                }
                .keyboardShortcut("e")
                .disabled(model.selectedRecording == nil)
                Divider()
                Button("Visa inspelningsmappen") { model.revealInFinder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Nollställ klippindikatorer") { model.processor.resetClipIndicators() }
                    .keyboardShortcut("k")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Never lose a take: close and finalize the file before quitting.
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }
}
