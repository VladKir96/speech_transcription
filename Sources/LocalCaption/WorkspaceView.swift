import CaptionCore
import SwiftUI

private enum WorkspaceTab: Hashable {
    case live, history
}

struct WorkspaceView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var tab: WorkspaceTab = .live
    @State private var initialized = false
    @State private var showExport = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if tab == .live {
                LiveWorkspace(model: model, showExport: $showExport)
            } else {
                HistoryView(model: model)
            }
            if let message = model.notice {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(message).font(.callout).textSelection(.enabled)
                    Spacer(minLength: 8)
                    if !model.unsaved.isEmpty {
                        Button("Retry Save") { Task { await model.retrySaving() } }
                    }
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss message")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.orange.opacity(0.09))
            }
        }
        .background(Palette.canvas)
        .onAppear {
            if !initialized { tab = model.settings.launchView == .history ? .history : .live }
            initialized = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .captionShowHistory)) { _ in tab = .history }
        .overlay(alignment: .bottomTrailing) {
            if let success = model.exportSuccess {
                Button {
                    model.exportSuccess = nil
                } label: {
                    Label(success, systemImage: "checkmark.circle.fill")
                        .padding(12)
                        .foregroundStyle(.primary)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                .padding(20)
            }
        }
        .task(id: model.exportSuccess) {
            if model.exportSuccess != nil {
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { model.exportSuccess = nil }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            HStack(spacing: 9) {
                Image(systemName: "waveform")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 33, height: 33)
                    .background(Palette.system, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                Text("LocalCaption")
                    .font(.system(size: 18, weight: .semibold))
            }
            Divider().frame(height: 23)
            HStack(spacing: 5) {
                navigation("Live", symbol: "waveform", value: .live)
                navigation("History", symbol: "clock.arrow.circlepath", value: .history)
            }
            Spacer()
            Button {
                model.settings.overlay.toggle()
            } label: {
                Label("Subtitles", systemImage: model.settings.overlay ? "captions.bubble.fill" : "captions.bubble")
            }
            .help(model.settings.overlay ? "Hide floating subtitles" : "Show floating subtitles")
            .accessibilityValue(model.settings.overlay ? "Shown" : "Hidden")
            Button { openSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16))
                    .padding(4)
            }
            .accessibilityLabel("Settings")
            .help("Settings")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 22)
        .frame(height: 59)
        .background(Palette.surface)
    }

    private func navigation(_ label: String, symbol: String, value: WorkspaceTab) -> some View {
        Button { tab = value } label: {
            Label(label, systemImage: symbol)
                .font(.system(size: 13, weight: tab == value ? .semibold : .medium))
                .foregroundStyle(tab == value ? .primary : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(tab == value ? Palette.selection : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }
}

private struct LiveWorkspace: View {
    @Bindable var model: AppModel
    @Binding var showExport: Bool
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 15) {
            sessionToolbar
            HSplitView {
                TranscriptColumn(model: model, source: .system)
                    .frame(minWidth: 310, idealWidth: 550, maxWidth: .infinity, maxHeight: .infinity)
                TranscriptColumn(model: model, source: .microphone)
                    .frame(minWidth: 310, idealWidth: 550, maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.border))
            footer
        }
        .padding(.horizontal, 21)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .sheet(isPresented: $showExport) {
            ExportOptions(defaultFormat: model.settings.exportFormat, defaultDisplay: model.settings.exportDisplay) { format, display in
                await model.exportCurrent(format: format, display: display)
            }
        }
    }

    private var sessionToolbar: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 11) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.sessionTitle)
                        .font(.system(size: 24, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        Circle().fill(model.recording ? Color.red : Color.secondary.opacity(0.45))
                            .frame(width: 7, height: 7)
                        Text(model.phase.title)
                        Text("·").accessibilityHidden(true)
                        Text(CaptionTime.clock(model.elapsed))
                            .monospacedDigit()
                            .accessibilityLabel("Session duration \(CaptionTime.clock(model.elapsed))")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 5)
                if model.phase == .preparing || model.phase == .stopping || model.busy {
                    ProgressView().controlSize(.small).padding(.trailing, 5)
                }
                if model.sessionActive {
                    Button {
                        Task {
                            if model.phase == .paused { await model.resume() } else { await model.pause() }
                        }
                    } label: {
                        Label(model.phase == .paused ? "Resume" : "Pause",
                              systemImage: model.phase == .paused ? "play.fill" : "pause.fill")
                            .padding(.horizontal, 6)
                    }
                    .disabled(model.busy || (model.phase != .recording && model.phase != .paused))
                    Button {
                        Task { await model.stop() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill").padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!model.canStop)
                } else {
                    Button {
                        Task { await model.start() }
                    } label: {
                        Label("Start Session", systemImage: "record.circle")
                            .padding(.horizontal, 9)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.system)
                    .disabled(!model.canStart)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)

            HStack(spacing: 12) {
                if model.sessionActive {
                    microphoneButton
                }
                Picker("Profile", selection: $model.settings.options.profile) {
                    ForEach(RecognitionProfile.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(model.sessionActive)
                Toggle("Translation", isOn: $model.settings.options.translate)
                    .toggleStyle(.switch)
                    .disabled(model.sessionActive)
                if model.settings.options.translate {
                    Picker("Translate to", selection: $model.settings.options.targetLanguage) {
                        ForEach([SpeechLanguage.en, .ru]) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    .disabled(model.sessionActive)
                }
                Spacer()
                if model.session != nil {
                    Button { showExport = true } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.phase == .preparing || model.phase == .stopping)
                }
            }
            .controlSize(.small)
        }
    }

    private var microphoneButton: some View {
        let status = model.lanes[.microphone]?.status ?? .disabled
        let active = status == .capturing
        let title = active ? "Mic On" : status == .starting ? "Mic Starting"
            : status.issue == nil ? "Mic Off" : "Mic Unavailable"
        return Button {
            model.toggleMicrophone()
        } label: {
            Label(title, systemImage: active || status == .starting ? "mic.fill" : "mic.slash")
                .foregroundStyle(active ? Palette.microphone : Color.primary)
        }
        .disabled(!model.recording)
        .help(status.issue ?? (model.microphoneRequested ? "Turn microphone off" : "Turn microphone on"))
        .accessibilityLabel(title.replacingOccurrences(of: "Mic ", with: "Microphone "))
        .fixedSize()
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if !model.installed.contains(model.settings.options.model.id), !model.sessionActive {
                Image(systemName: "arrow.down.circle").foregroundStyle(Palette.system)
                Text("Install \(model.settings.options.model.title) to begin.")
                Button("Open Settings") {
                    model.preferencesTab = .models
                    openSettings()
                }
                    .buttonStyle(.link)
            } else if let hardware = model.hardware {
                Label(hardware, systemImage: "cpu")
            } else {
                Label("On-device inference", systemImage: "lock")
            }
            Spacer()
            Text(model.settings.autoSave ? "Transcripts saved locally" : "Automatic saving off")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(minHeight: 17)
    }
}

enum Palette {
    static let system = Color(red: 0.08, green: 0.48, blue: 0.43)
    static let microphone = Color(red: 0.33, green: 0.31, blue: 0.75)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor).opacity(0.45)
    static let selection = Color(nsColor: .quaternaryLabelColor).opacity(0.42)
    static func color(_ source: AudioSource) -> Color { source == .system ? system : microphone }
}
