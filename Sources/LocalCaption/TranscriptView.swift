import CaptionCore
import SwiftUI

struct TranscriptColumn: View {
    let model: AppModel
    let source: AudioSource
    private enum Target: Hashable {
        case latest
        case partial(UUID), draftPhrase(UUID), caption(UUID)
    }

    @State private var position: Target? = .latest
    @State private var archived: [TranscriptSegment]?
    @State private var archiveTotal = 0
    @State private var page: Task<Void, Never>?

    private var lane: TranscriptLane { model.lanes[source] ?? TranscriptLane() }
    private var color: Color { Palette.color(source) }
    private var segments: [TranscriptSegment] { archived ?? lane.latest }
    private var showTranslation: Bool { model.settings.showTranslation && (model.session?.options.translate ?? model.settings.options.translate) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if segments.isEmpty, lane.partial == nil, lane.pendingPhrase == nil {
                empty
            } else {
                transcript
            }
        }
        .background(Palette.surface)
        .onChange(of: model.session?.id) { _, _ in backToLatest() }
        .onDisappear { backToLatest() }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: source.icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 35, height: 35)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(source.title).font(.system(size: 16, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(lane.status == .capturing ? color : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                    Text(lane.status.title).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            Spacer()
            if page != nil { ProgressView().controlSize(.mini) }
            if lane.status == .capturing {
                SignalMeter(level: lane.level, color: color)
                    .padding(.trailing, 1)
            }
            if let issue = lane.status.issue ?? lane.issue {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .help(issue)
                    .accessibilityLabel(issue)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 67)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: source == .system ? "waveform.circle" : "mic.circle")
                .font(.system(size: 35, weight: .light))
                .foregroundStyle(color.opacity(0.8))
                .accessibilityHidden(true)
            Text(lane.status.issue == nil ? emptyTitle : "\(source.title) unavailable")
                .font(.system(size: 15, weight: .semibold))
            Text(lane.status.issue ?? lane.issue ?? emptyDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 275)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if lane.status == .capturing { return "Listening for speech" }
        if lane.status == .disabled { return "Source turned off" }
        if model.phase == .completed { return "No speech in this session" }
        return "No transcript yet"
    }

    private var emptyDetail: String {
        if lane.status == .disabled {
            return source == .microphone && model.sessionActive
                ? "Turn on the microphone in the recording toolbar." : "Enable this source in Audio settings."
        }
        if lane.status == .paused { return "Resume the session to continue transcribing." }
        if model.phase == .completed { return "Recognized speech from this source will appear in a new session." }
        return source == .system ? "Play audio in another app during a session." : "Speak into the selected microphone during a session."
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 1).id(Target.latest).accessibilityHidden(true)
                    if archived == nil, let partial = lane.partial, model.settings.showOriginal {
                        TranscriptRow(segment: partial, showOriginal: true, showTranslation: false, showSource: false)
                            .id(Target.partial(partial.id))
                    }
                    if archived == nil, let phrase = lane.pendingPhrase, phrase.id != lane.partial?.id {
                        TranscriptRow(segment: phrase, showOriginal: model.settings.showOriginal,
                                      showTranslation: showTranslation, showSource: false, waitingForPhrase: true)
                            .id(Target.draftPhrase(phrase.id))
                    }
                    ForEach(segments) { segment in
                        VStack(spacing: 0) {
                            let current = model.currentTranslation(for: segment)
                            TranscriptRow(segment: current, showOriginal: model.settings.showOriginal,
                                          showTranslation: showTranslation, showSource: false,
                                          retry: showTranslation ? TranslationRetryAction(model: model, segment: current) : nil)
                            Divider().overlay(Palette.border)
                        }
                        .id(Target.caption(segment.id))
                    }
                    if (archived == nil ? lane.total : archiveTotal) > segments.count {
                        Button {
                            loadEarlier()
                        } label: {
                            Label("Load earlier captions", systemImage: "arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(page != nil)
                        .padding(.vertical, 12)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 18)
            }
            .scrollPosition(id: $position, anchor: .top)
            .accessibilityLabel("\(source.title) transcript")
            .onChange(of: position) { _, target in
                if case let .caption(id) = target, lane.latest.contains(where: { $0.id == id }) {
                    beginBrowsing()
                } else if target == .latest, archived != nil {
                    backToLatest()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if archived != nil {
                    Button {
                        backToLatest()
                        proxy.scrollTo(Target.latest, anchor: .top)
                    } label: {
                        Label("Back to Latest", systemImage: "arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(color)
                    .padding(13)
                }
            }
        }
    }

    private func beginBrowsing() {
        guard archived == nil else { return }
        archived = lane.latest
        archiveTotal = lane.total
    }

    private func backToLatest() {
        page?.cancel()
        page = nil
        archived = nil
        position = .latest
    }

    private func loadEarlier() {
        guard page == nil, let before = segments.last, let session = model.session?.id else { return }
        beginBrowsing()
        page = Task {
            defer { if !Task.isCancelled { page = nil } }
            do {
                let earlier = try await model.older(source, before: before)
                guard !Task.isCancelled, model.session?.id == session else { return }
                archived?.append(contentsOf: earlier)
                if earlier.count < 160 { archiveTotal = archived?.count ?? 0 }
            } catch {
                if !Task.isCancelled { model.notice = error.localizedDescription }
            }
        }
    }
}

struct SignalMeter: View {
    let level: Double
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<8) { bar in
                Capsule()
                    .fill(Double(bar) < level * 8 ? color : color.opacity(0.16))
                    .frame(width: 3, height: Double([7, 10, 14, 20, 17, 12, 8, 5][bar]))
            }
        }
        .accessibilityLabel("Input activity")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}

struct TranscriptRow: View {
    let segment: TranscriptSegment
    let showOriginal: Bool
    let showTranslation: Bool
    let showSource: Bool
    var waitingForPhrase = false
    var retry: TranslationRetryAction?

    private var language: String {
        Locale.current.localizedString(forLanguageCode: segment.language) ?? segment.language.uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(CaptionTime.clock(segment.start)).monospacedDigit()
                if showSource {
                    Text(segment.source.title).foregroundStyle(Palette.color(segment.source))
                }
                if segment.language != "auto" { Text(language) }
                if waitingForPhrase {
                    Text("Completing phrase…").foregroundStyle(.secondary)
                } else if !segment.finalized {
                    Text("Listening").foregroundStyle(Palette.color(segment.source))
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            if showOriginal {
                Text(segment.original)
                    .foregroundStyle(segment.finalized ? .primary : .secondary)
                    .italic(!segment.finalized)
            }
            if showTranslation {
                if let translation = segment.translation {
                    Text(translation)
                        .foregroundStyle(showOriginal ? Palette.color(segment.source) : .primary)
                } else if segment.translationStatus == .sameLanguage && !showOriginal {
                    Text(segment.original)
                } else if !waitingForPhrase && (segment.translationStatus == .pending || segment.translationStatus == .translating) {
                    Text(segment.translationStatus == .pending ? "Translation pending" : "Translating…")
                        .font(.caption).foregroundStyle(.secondary)
                } else if segment.translationStatus == .failed {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(segment.translationError ?? "Translation unavailable", systemImage: "exclamationmark.circle")
                            .lineLimit(2)
                        if let retry { retry }
                    }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(segment.translationError ?? "")
                } else if segment.translationStatus == .unsupported {
                    Text("Language pair unavailable").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 15))
        .lineSpacing(3)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11)
    }
}

struct TranslationRetryAction: View {
    let model: AppModel
    let segment: TranscriptSegment
    var update: (TranscriptSegment) -> Void = { _ in }

    var body: some View {
        let selected = model.settings.options.translationModel
        Menu {
            Button("Retry with \(selected.title)") { retry(selected) }
            if selected != .marian, model.canUseTranslation(.marian, for: segment) {
                Button("Retry with MarianMT (Fast)") { retry(.marian) }
            }
        } label: {
            Text(model.translationRetryActive ? "Retry in progress…" : "Retry Translation")
        }
        .disabled(model.translationRetryActive)
        .fixedSize()
    }

    private func retry(_ engine: TranslationModel) {
        Task {
            if let result = await model.retryTranslation(segment, using: engine) { update(result) }
        }
    }
}

struct ExportOptions: View {
    @Environment(\.dismiss) private var dismiss
    @State var format: ExportFormat
    @State var display: CaptionDisplay
    let export: (ExportFormat, CaptionDisplay) async -> Void

    init(defaultFormat: ExportFormat, defaultDisplay: CaptionDisplay,
         export: @escaping (ExportFormat, CaptionDisplay) async -> Void) {
        _format = State(initialValue: defaultFormat)
        _display = State(initialValue: defaultDisplay)
        self.export = export
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export Transcript").font(.title2.bold())
            Form {
                Picker("Format", selection: $format) {
                    ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
                }
                if format != .json {
                    Picker("Include", selection: $display) {
                        ForEach(CaptionDisplay.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Choose Destination…") {
                    let chosenFormat = format
                    let chosenDisplay = display
                    dismiss()
                    Task {
                        try? await Task.sleep(for: .milliseconds(180))
                        await export(chosenFormat, chosenDisplay)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(23)
        .frame(width: 390)
    }
}
