import AppKit
import CaptionCore
import SwiftUI

enum PreferencesTab: String, CaseIterable, Identifiable {
    case general, audio, recognition, diarization, translation, subtitles, storage, models
    var id: String { rawValue }
    var title: String { self == .diarization ? "Speakers" : rawValue.capitalized }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .audio: "speaker.wave.2"
        case .recognition: "waveform"
        case .diarization: "person.2.wave.2"
        case .translation: "character.bubble"
        case .subtitles: "captions.bubble"
        case .storage: "internaldrive"
        case .models: "shippingbox"
        }
    }
}

struct PreferencesView: View {
    @Bindable var model: AppModel
    let updates: ApplicationUpdates
    @State private var removal: ModelDescriptor?
    @State private var speakerDownload: ModelDescriptor?

    var body: some View {
        TabView(selection: $model.preferencesTab) {
            ForEach(PreferencesTab.allCases) { tab in
                Group {
                    switch tab {
                    case .general: general
                    case .audio: audio
                    case .recognition: recognition
                    case .diarization: speakerSettings
                    case .translation: translation
                    case .subtitles: subtitles
                    case .storage: storage
                    case .models: models
                    }
                }
                .tabItem { Label(tab.title, systemImage: tab.icon) }
                .tag(tab)
            }
        }
        .frame(width: 690, height: 560)
        .onAppear { model.refreshDevicesAndPermissions() }
        .onChange(of: model.settings.options.sources) { _, _ in model.updateReadyLanes() }
        .alert("Remove \(removal?.name ?? "model")?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }
        ), presenting: removal) { modelToRemove in
            Button("Remove", role: .destructive) { Task { await model.remove(modelToRemove) } }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.requiresImport ? "You can install it again from a prepared model folder."
                : "You can download this model again from Settings.")
        }
        .confirmationDialog("Download speaker model?", isPresented: Binding(
            get: { speakerDownload != nil }, set: { if !$0 { speakerDownload = nil } }
        ), titleVisibility: .visible, presenting: speakerDownload) { item in
            Button("Download") { model.install(item) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("\(item.name) · \(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)) · \(item.license ?? "")")
        }
    }

    private var general: some View {
        Form {
            Section("Application") {
                Picker("Open on launch", selection: $model.settings.launchView) {
                    ForEach(LaunchView.allCases) { Text($0.title).tag($0) }
                }
                Picker("Appearance", selection: $model.settings.appearance) {
                    ForEach(Theme.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Application Updates") {
                LabeledContent("Version", value: updates.version)
                LabeledContent("Build", value: updates.build)
                LabeledContent("Last update check") {
                    if let date = updates.lastCheck {
                        Text(date, format: .dateTime.year().month().day().hour().minute())
                    } else {
                        Text("Never")
                    }
                }
                Toggle("Automatically Check for Updates", isOn: Binding(
                    get: { updates.automaticallyChecks }, set: updates.setAutomaticChecks
                ))
                .disabled(!updates.isConfigured)
                Button("Check for Updates…", action: updates.check)
                    .disabled(!updates.canCheck)
                if let message = updates.checkMessage {
                    Text(message).foregroundStyle(.secondary)
                }
            }
            Section("New sessions") {
                Picker("Default profile", selection: $model.settings.options.profile) {
                    ForEach(RecognitionProfile.allCases) { Text($0.title).tag($0) }
                }
                .disabled(model.sessionActive)
                Picker("Session titles", selection: $model.settings.titleMode) {
                    ForEach(SessionNaming.allCases) { Text($0.title).tag($0) }
                }
                if model.settings.titleMode == .custom {
                    TextField("Default title", text: $model.settings.sessionTitle)
                }
                Toggle("Save transcripts automatically", isOn: $model.settings.autoSave)
                    .disabled(model.sessionActive)
                if !model.settings.autoSave {
                    Text("Export the current session to keep it after closing LocalCaption or starting another session.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var audio: some View {
        Form {
            Section("Audio sources") {
                ForEach(AudioSource.allCases) { source in
                    LabeledContent {
                        HStack {
                            SignalMeter(level: model.lanes[source]?.level ?? 0, color: Palette.color(source))
                            Toggle(source.title, isOn: sourceBinding(source, overlay: false)).labelsHidden()
                                .disabled(model.sessionActive)
                        }
                    } label: { Label(source.title, systemImage: source.icon) }
                }
                Picker("Microphone device", selection: Binding(
                    get: { model.settings.options.microphoneUID },
                    set: {
                        model.settings.options.microphoneUID = $0
                        model.microphoneDeviceChanged()
                    }
                )) {
                    Text("System Default").tag(nil as String?)
                    ForEach(model.devices) { device in Text(device.name).tag(Optional(device.id)) }
                    if let saved = model.settings.options.microphoneUID, !model.devices.contains(where: { $0.id == saved }) {
                        Text("Disconnected device").tag(Optional(saved))
                    }
                }
                .disabled(model.phase == .preparing || model.phase == .stopping)
                Button("Refresh Devices") { model.refreshDevicesAndPermissions() }
            }
            Section("Microphone control") {
                Picker("Mode", selection: microphoneShortcut.mode) {
                    ForEach(MicrophoneControlMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Shortcut key", selection: microphoneShortcut.key) {
                    ForEach(MicrophoneShortcut.Key.allCases) { Text($0.title).tag($0) }
                }
                Picker("Shortcut modifiers", selection: microphoneShortcut.modifiers) {
                    ForEach(MicrophoneShortcut.Modifiers.allCases) { Text($0.title).tag($0) }
                }
                .disabled(microphoneShortcut.wrappedValue.key == .disabled)
                Toggle("Use shortcut in other apps", isOn: microphoneShortcut.global)
                    .disabled(!microphoneShortcut.wrappedValue.canRegisterGlobally)
                if let issue = model.microphoneShortcutIssue {
                    Text(issue).font(.callout).foregroundStyle(.secondary)
                }
                Text("Push-to-Talk works while the LocalCaption window is focused. Global Toggle requires a modifier key, such as Control + Option + M.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                LabeledContent("Microphone", value: permissionLabel)
                HStack {
                    if model.microphonePermission == .notDetermined {
                        Button("Request Microphone Access") { Task { await model.requestMicrophone() } }
                    }
                    Button("Microphone Settings…") { openPrivacy("Privacy_Microphone") }
                }
                LabeledContent("System Audio status", value: model.systemAudioAccess.title)
                Picker("System Audio source", selection: Binding(
                    get: { model.settings.options.systemAudioSelection ?? .automatic },
                    set: { model.settings.options.systemAudioSelection = $0 }
                )) {
                    ForEach(SystemAudioSelection.allCases) { Text($0.title).tag($0) }
                }
                .disabled(model.sessionActive)
                if #available(macOS 14.2, *) {
                    Text("Automatic uses System Audio Recording Only. ScreenCaptureKit display discovery uses Screen & System Audio Recording.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("Recording Settings…") { openPrivacy("Privacy_ScreenCapture") }
                Text("LocalCaption listens only during an active session. Speakers can cause playback speech to appear in both lanes. Use headphones to reduce overlap.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var microphoneShortcut: Binding<MicrophoneShortcut> {
        Binding(
            get: { model.settings.microphoneShortcut ?? MicrophoneShortcut() },
            set: {
                if $0.mode == .pushToTalk && model.settings.microphoneShortcut?.mode != .pushToTalk {
                    model.setMicrophoneEnabled(false)
                }
                model.microphoneShortcutIssue = nil
                model.settings.microphoneShortcut = $0
            }
        )
    }

    private var recognition: some View {
        Form {
            Section("Whisper") {
                Picker("Model", selection: $model.settings.options.model) {
                    ForEach(WhisperModel.allCases) { Text($0.title).tag($0) }
                }
                Picker("Source language", selection: $model.settings.options.sourceLanguage) {
                    ForEach(SpeechLanguage.allCases) { Text($0.title).tag($0) }
                }
                Picker("Profile", selection: $model.settings.options.profile) {
                    ForEach(RecognitionProfile.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Use Metal acceleration", isOn: $model.settings.options.useMetal)
                Toggle("Use Silero voice activity detection", isOn: $model.settings.options.enableVAD)
                Text("Low Latency updates captions more often. High Accuracy uses longer speech windows and a wider search when finalizing.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .disabled(model.sessionActive)
            Section("Speech Segmentation") {
                Picker("Translation Strategy", selection: Binding(
                    get: { model.settings.options.translationStrategy ?? .balanced },
                    set: {
                        model.settings.options.translationStrategy = $0
                        model.settings.options.phraseCompletionPause = nil
                    }
                )) {
                    ForEach(TranslationStrategy.allCases) { Text($0.title).tag($0) }
                }
                HStack {
                    Slider(value: Binding(
                        get: { model.settings.options.effectivePhrasePause },
                        set: { model.settings.options.phraseCompletionPause = $0 }
                    ), in: 0.5...4, step: 0.1) {
                        Text("Phrase Completion Pause")
                    }
                    Text("\(model.settings.options.effectivePhrasePause, specifier: "%.1f") s")
                        .monospacedDigit().frame(width: 42, alignment: .trailing)
                }
                Text("How long LocalCaption waits after speech stops before completing a phrase and sending it for translation.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .disabled(model.sessionActive)
            Button("Manage Models…") { model.preferencesTab = .models }
        }
        .formStyle(.grouped)
    }

    private var translation: some View {
        Form {
            Section("Local translation") {
                Toggle("Translate finalized captions", isOn: $model.settings.options.translate)
                Picker("Target language", selection: $model.settings.options.targetLanguage) {
                    ForEach([SpeechLanguage.en, .ru]) { Text($0.title).tag($0) }
                }
            }
            .disabled(model.sessionActive)
            Section("Translation Engine") {
                Picker("Engine", selection: $model.settings.options.translationModel) {
                    ForEach(TranslationModel.allCases) { Text($0.title).tag($0) }
                }
                Text(model.settings.options.translationModel.detail).font(.callout).foregroundStyle(.secondary)
                ForEach(TranslationModel.allCases) { engine in
                    let installed = model.translationInstallation(engine).map(model.installed.contains) ?? false
                    LabeledContent(engine.title, value: installed ? "Installed" : "Not installed")
                }
                if model.settings.options.translationModel == .nllb {
                    Text("NLLB-200 Distilled 600M is licensed for noncommercial use under CC BY-NC 4.0.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("Manage Language Models…") { model.preferencesTab = .models }
            }
            Section("Transcript display") {
                Toggle("Show original text", isOn: $model.settings.showOriginal)
                Toggle("Show translation", isOn: $model.settings.showTranslation)
            }
        }
        .formStyle(.grouped)
    }

    private var speakerSettings: some View {
        Form {
            Section("Speaker Diarization") {
                Toggle("Enable Speaker Diarization by Default", isOn: $model.diarizationOptions.enabledByDefault)
                if !model.speakerModelsInstalled {
                    Text("Install both speaker models to label voices in System Audio.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Manage Speaker Models…") { model.preferencesTab = .models }
                }
            }
            Section("Detection") {
                Picker("Detection Mode", selection: $model.diarizationOptions.mode) {
                    ForEach(DiarizationMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Expected Number of Speakers", selection: $model.diarizationOptions.speakerLimit) {
                    Text("Auto Detect").tag(0)
                    ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                }
                Text("A fixed count limits the number of speaker profiles. Uncertain speech can remain unlabeled.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Slider(value: $model.diarizationOptions.similarity, in: 0.3...0.85, step: 0.01) {
                        Text("Speaker Similarity Threshold")
                    }
                    Text(model.diarizationOptions.similarity, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                }
                Text("Lower values merge similar voices more readily. Higher values make separate profiles more likely.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Speaker-Aware Phrase Aggregation", isOn: $model.diarizationOptions.speakerAwarePhrases)
            }
            .disabled(!model.speakerModelsInstalled || model.sessionActive)
            Section("Display") {
                Toggle("Color-Code Speakers", isOn: $model.diarizationOptions.colorSpeakers)
                Toggle("Show Speaker Names in Floating Subtitles", isOn: $model.diarizationOptions.subtitleNames)
            }
        }
        .formStyle(.grouped)
    }

    private var subtitles: some View {
        Form {
            Section("Floating subtitles") {
                Toggle("Show floating subtitles", isOn: $model.settings.overlay)
                Picker("Display", selection: $model.settings.overlayDisplay) {
                    ForEach(CaptionDisplay.allCases) { Text($0.title).tag($0) }
                }
                ForEach(AudioSource.allCases) { source in
                    Toggle(source.title, isOn: sourceBinding(source, overlay: true))
                }
            }
            Section("Appearance") {
                LabeledContent("Font size") {
                    Slider(value: $model.settings.overlayFontSize, in: 15...44, step: 1)
                        .frame(width: 170)
                        .accessibilityLabel("Subtitle font size")
                    Text("\(Int(model.settings.overlayFontSize)) pt").monospacedDigit()
                }
                LabeledContent("Background opacity") {
                    Slider(value: $model.settings.overlayOpacity, in: 0.4...1, step: 0.05)
                        .frame(width: 170)
                        .accessibilityLabel("Subtitle background opacity")
                    Text("\(Int((model.settings.overlayOpacity * 100).rounded()))%").monospacedDigit()
                }
                Stepper("Maximum lines · \(model.settings.overlayLines)", value: $model.settings.overlayLines, in: 1...8)
            }
        }
        .formStyle(.grouped)
    }

    private var storage: some View {
        Form {
            Section("Application data") {
                Text(model.dataFolder.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Button("Open Data Folder…") { model.openDataFolder() }
                Button("Manage Session History") {
                    NotificationCenter.default.post(name: .captionShowHistory, object: nil)
                    NSApp.windows.first(where: { $0.title == "LocalCaption" })?.makeKeyAndOrderFront(nil)
                }
            }
            Section("Export") {
                Toggle("Export automatically when a session ends", isOn: $model.settings.autoExport)
                Picker("Default format", selection: $model.settings.exportFormat) {
                    ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
                }
                if model.settings.exportFormat == .srt {
                    Toggle("Include speaker names", isOn: Binding(
                        get: { model.settings.exportSpeakerNames ?? true },
                        set: { model.settings.exportSpeakerNames = $0 }
                    ))
                }
                Picker("Include", selection: $model.settings.exportDisplay) {
                    ForEach(CaptionDisplay.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Automatic export folder") {
                    Text(model.settings.exportFolder?.path ?? "No folder selected")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { Task { await model.chooseExportFolder() } }
                }
                if model.settings.autoExport && model.settings.exportFolder == nil {
                    Text("Choose a folder to enable automatic export.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var models: some View {
        Form {
            Section("Speech recognition") {
                ForEach(WhisperModel.allCases) { selection in
                    if let item = model.modelCatalog.first(where: { $0.id == selection.q8ID }) {
                        modelRow(item, speech: selection)
                    }
                }
            }
            Section("Voice activity detection") {
                ForEach(model.modelCatalog.filter { $0.kind == .vad }) { modelRow($0) }
            }
            Section("Translation") {
                ForEach(model.modelCatalog.filter { $0.kind == .translation }) { modelRow($0) }
            }
            Section("Speaker Diarization Models") {
                ForEach(model.modelCatalog.filter { $0.kind == .diarization }) { modelRow($0) }
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshModels() }
    }

    private func modelRow(_ item: ModelDescriptor, speech: WhisperModel? = nil) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).fontWeight(.semibold)
                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                        Text("·")
                        Text(model.installed.contains(item.id) ? "Installed disk usage" : item.requiresImport ? "Folder size" : "Download size")
                        if speech == model.settings.options.model { Text("· Selected") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let version = item.version {
                        Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let license = item.license, let url = item.licenseURL {
                        Link(license, destination: url).font(.caption)
                    }
                }
                Spacer()
                if model.downloadProgress[item.id] != nil {
                    Button("Cancel") { model.cancelInstall(item) }
                } else if model.installed.contains(item.id) {
                    if let speech, speech != model.settings.options.model {
                        Button("Select") { model.settings.options.model = speech }
                        .disabled(model.sessionActive)
                    }
                    Button("Remove…") { removal = item }.disabled(model.sessionActive || model.translationRetryActive)
                } else if item.requiresImport {
                    Button("Install from Folder…") { Task { await importModel(item) } }
                } else {
                    Button("Download") {
                        if item.kind == .diarization { speakerDownload = item }
                        else { model.install(item) }
                    }
                }
            }
            if let progress = model.downloadProgress[item.id] {
                ProgressView(value: progress) {
                    Text("\(item.requiresImport ? "Validating" : "Downloading") \(Int(progress * 100))%")
                }
                    .font(.caption)
            }
            if let error = model.modelErrors[item.id] {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private func importModel(_ item: ModelDescriptor) async {
        let panel = NSOpenPanel()
        panel.title = "Install \(item.name)"
        panel.message = "Choose the prepared NLLB model folder."
        panel.prompt = "Install"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.showsHiddenFiles = true
        guard await panel.begin() == .OK, let folder = panel.url else { return }
        model.install(item, from: folder)
    }

    private var permissionLabel: String {
        switch model.microphonePermission {
        case .authorized: "Allowed"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Awaiting permission"
        @unknown default: "Unknown"
        }
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func sourceBinding(_ source: AudioSource, overlay: Bool) -> Binding<Bool> {
        Binding(get: {
            overlay ? model.settings.overlaySources.contains(source) : model.settings.options.sources.contains(source)
        }, set: { enabled in
            if overlay {
                if enabled { model.settings.overlaySources.insert(source) } else { model.settings.overlaySources.remove(source) }
            } else {
                if enabled { model.settings.options.sources.insert(source) } else { model.settings.options.sources.remove(source) }
                model.updateReadyLanes()
            }
        })
    }
}

extension Notification.Name {
    static let captionShowHistory = Self("LocalCaption.showHistory")
}
