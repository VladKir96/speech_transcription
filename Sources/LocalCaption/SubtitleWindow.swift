import AppKit
import CaptionCore
import SwiftUI

@MainActor
final class SubtitleController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private weak var model: AppModel?

    func update(_ model: AppModel) {
        self.model = model
        guard model.settings.overlay else {
            panel?.orderOut(nil)
            return
        }
        let window: NSPanel
        if let panel {
            window = panel
        } else {
            window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 190),
                             styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            window.title = "LocalCaption Subtitles"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isFloatingPanel = true
            window.becomesKeyOnlyIfNeeded = true
            window.hidesOnDeactivate = false
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.contentMinSize = NSSize(width: 300, height: 90)
            window.contentView = NSHostingView(rootView: SubtitleContent(model: model))
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("LocalCaption.subtitles")
            if !window.setFrameUsingName("LocalCaption.subtitles"),
               let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: frame.midX - 340, y: frame.minY + 50))
            }
            panel = window
        }
        switch model.settings.appearance {
        case .system: window.appearance = nil
        case .light: window.appearance = NSAppearance(named: .aqua)
        case .dark: window.appearance = NSAppearance(named: .darkAqua)
        }
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        model?.settings.overlay = false
    }
}

private struct SubtitleContent: View {
    let model: AppModel
    @Environment(\.colorScheme) private var scheme

    private var display: CaptionDisplay { model.settings.overlayDisplay }
    private var foreground: Color { scheme == .dark ? .white : Color(red: 0.08, green: 0.10, blue: 0.13) }
    private var backing: Color { scheme == .dark ? .black : .white }
    private func named(_ text: String, segment: TranscriptSegment) -> String {
        guard model.diarizationRequested, model.diarizationOptions.subtitleNames,
              let speaker = model.currentTranslation(for: segment).speakerLabel else { return text }
        return "\(speaker): \(text)"
    }
    private var rows: [Row] {
        let sources = AudioSource.allCases.filter { model.settings.overlaySources.contains($0) }
        return sources.compactMap { source in
            guard let lane = model.lanes[source] else { return nil }
            if display == .translated {
                guard let last = lane.latest.first(where: { $0.translation != nil || $0.translationStatus == .sameLanguage }) else { return nil }
                return Row(source: source, start: last.start, text: named(last.translation ?? last.original, segment: last), secondary: nil)
            }
            guard let last = lane.partial ?? lane.speakerDrafts.last ?? lane.pendingPhrase ?? lane.latest.first else { return nil }
            return Row(source: source, start: last.start, text: named(last.original, segment: last),
                       secondary: display == .both ? last.translation : nil)
        }.sorted { ($0.start, $0.source.rawValue) > ($1.start, $1.source.rawValue) }
    }

    var body: some View {
        GeometryReader { geometry in
            let available = max(1, Int((geometry.size.height - 34) / (model.settings.overlayFontSize * 1.3 + 6)))
            let limit = min(model.settings.overlayLines, available)
            let visible = Array(rows.prefix(limit))
            VStack(alignment: .leading, spacing: 6) {
                if visible.isEmpty {
                    Text(model.settings.overlaySources.isEmpty ? "Choose a subtitle source in Settings" : "Waiting for captions")
                        .font(.system(size: min(model.settings.overlayFontSize, 22), weight: .medium))
                        .opacity(0.76)
                        .lineLimit(1)
                } else {
                    ForEach(visible, id: \.source) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            if model.settings.overlaySources.count > 1 {
                                Text(row.source.title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Palette.color(row.source).opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                            }
                            let lines = max(1, limit / visible.count)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.text)
                                    .font(.system(size: model.settings.overlayFontSize, weight: .semibold))
                                    .lineLimit(row.secondary != nil && lines > 1 ? lines - 1 : lines)
                                if let translated = row.secondary, lines > 1 {
                                    Text(translated)
                                        .font(.system(size: model.settings.overlayFontSize * 0.88, weight: .medium))
                                        .lineLimit(1)
                                        .opacity(0.84)
                                }
                            }
                        }
                    }
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .padding(.top, 23)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(backing.opacity(model.settings.overlayOpacity), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(foreground.opacity(0.18)))
        }
    }

    private struct Row {
        let source: AudioSource
        let start: Double
        let text: String
        let secondary: String?
    }
}
