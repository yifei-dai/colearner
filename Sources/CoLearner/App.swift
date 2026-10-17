import SwiftUI
import AppKit

@main
struct CoLearnerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Co-learner", id: "main") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 620)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1440, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDF…") { model.openPDFPanel() }.keyboardShortcut("o")
            }
            CommandMenu("Slides") {
                Button("Next Slide") { model.go(1) }.keyboardShortcut("]", modifiers: .command)
                Button("Previous Slide") { model.go(-1) }.keyboardShortcut("[", modifiers: .command)
                Divider()
                Button("Ask About This Slide") {
                    model.rightTab = .chat
                    // The chat view is only back in the window after this update; focus it then.
                    DispatchQueue.main.async { model.chat.focusInput() }
                }.keyboardShortcut("l", modifiers: .command)
                Button("Show Walkthrough") { model.rightTab = .walkthrough }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Show Chat") { model.rightTab = .chat }
                    .keyboardShortcut("1", modifiers: .command)
                Divider()
                Button("Reload Library") { model.reloadLibrary() }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Writing to a CLI that already exited must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        // Also needed when started as a bare executable (swift run) instead of an .app.
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.chat.stopAll() }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Claude") {
                Picker("Model", selection: $model.claudeModel) {
                    ForEach(ModelCatalog.list(.claude).filter { !ModelCatalog.shared.isHidden(.claude, $0.id) || $0.id == model.claudeModel }, id: \.id) { Text($0.label).tag($0.id) }
                }
                Picker("Effort", selection: $model.claudeEffort) {
                    ForEach(ModelCatalog.model(.claude, model.claudeModel)?.efforts ?? [], id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Claude Code", value: model.chat.claude.versionString)
            }
            Section("ChatGPT (Codex)") {
                Picker("Model", selection: $model.codexModel) {
                    ForEach(ModelCatalog.list(.codex).filter { !ModelCatalog.shared.isHidden(.codex, $0.id) || $0.id == model.codexModel }, id: \.id) { Text($0.label).tag($0.id) }
                }
                Picker("Reasoning effort", selection: $model.codexEffort) {
                    ForEach(ModelCatalog.model(.codex, model.codexModel)?.efforts ?? [], id: \.self) { Text($0).tag($0) }
                }
            }
            Section("Files") {
                LabeledContent("Chats are saved in", value: AppPaths.chats.path)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.chats]) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}
