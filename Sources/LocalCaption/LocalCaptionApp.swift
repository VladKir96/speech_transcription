import AppKit
import CaptionCore
import SwiftUI

@main
enum LocalCaptionEntry {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnose-system-audio") {
            SystemAudioDiagnosticApp.main()
        } else {
            LocalCaptionApp.main()
        }
    }
}

struct LocalCaptionApp: App {
    @NSApplicationDelegateAdaptor(CaptionAppDelegate.self) private var delegate
    @State private var model = Self.makeModel()
    @State private var overlay = SubtitleController()
    @State private var updates = ApplicationUpdates()

    private static func makeModel() -> AppModel {
        guard let path = ProcessInfo.processInfo.environment["LOCALCAPTION_DATA_DIRECTORY"] else { return AppModel() }
        return AppModel(dataFolder: URL(fileURLWithPath: path, isDirectory: true), defaults: nil)
    }

    var body: some Scene {
        Window("LocalCaption", id: "main") {
            WorkspaceView(model: model, updates: updates)
                .background(MicrophoneShortcutView(model: model,
                    shortcut: model.settings.microphoneShortcut ?? MicrophoneShortcut(), recording: model.recording))
                .preferredColorScheme(model.settings.appearance.colorScheme)
                .frame(minWidth: 790, minHeight: 530)
                .task {
                    delegate.model = model
                    await model.initialize()
                    updates.start(model: model)
                    overlay.update(model)
                }
                .onDisappear { model.cancelPreparation() }
                .onChange(of: model.settings.overlay) { _, _ in overlay.update(model) }
                .onChange(of: model.settings.appearance) { _, _ in overlay.update(model) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.refreshDevicesAndPermissions()
                    Task { await model.refreshModels() }
                }
        }
        .defaultSize(width: 1_180, height: 735)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: updates.check)
                    .disabled(!updates.canCheck)
            }
            CommandGroup(after: .windowArrangement) {
                Button(model.settings.overlay ? "Hide Floating Subtitles" : "Show Floating Subtitles") {
                    model.settings.overlay.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        Settings {
            PreferencesView(model: model, updates: updates)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }
    }
}

@MainActor
final class CaptionAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var awaitingTermination = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !awaitingTermination else { return .terminateLater }
        awaitingTermination = true
        Task {
            let canQuit = await model.canTerminate()
            awaitingTermination = false
            sender.reply(toApplicationShouldTerminate: canQuit)
        }
        return .terminateLater
    }
}

extension Theme {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
