import CaptionCore
import SwiftUI

struct HistoryView: View {
    let model: AppModel
    @State private var sessions: [CaptionSession] = []
    @State private var selection: UUID?
    @State private var canLoadMoreSessions = false
    @State private var query = ""
    @State private var segments: [TranscriptSegment] = []
    @State private var canLoadMoreSegments = false
    @State private var pendingDelete: CaptionSession?
    @State private var confirmingDeleteAll = false
    @State private var pendingRename: CaptionSession?
    @State private var newTitle = ""
    @State private var exporting = false
    @State private var loading = false

    private var selected: CaptionSession? { sessions.first { $0.id == selection } }
    private var searchIdentity: SearchIdentity { SearchIdentity(id: selection, query: query, revision: model.historyRevision) }
    private var canDeleteHistory: Bool {
        !model.busy && (model.sessionActive || model.unsaved.isEmpty)
            && (canLoadMoreSessions || sessions.contains { !isActive($0) })
    }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 220, idealWidth: 255, maxWidth: 350)
            detail.frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.surface)
        .task(id: model.historyRevision) { await reloadSessions() }
        .task(id: searchIdentity) {
            segments = []
            canLoadMoreSegments = false
            guard selection != nil else { return }
            if !query.isEmpty {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            await loadSegments(reset: true)
        }
        .confirmationDialog("Delete this session?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible, presenting: pendingDelete) { session in
            Button("Delete Session", role: .destructive) { Task { await delete(session) } }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("“\(session.title)” and its transcript will be permanently deleted.")
        }
        .alert("Delete all history?", isPresented: $confirmingDeleteAll) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All History", role: .destructive) { Task { await deleteAll() } }
        } message: {
            Text(model.sessionActive
                 ? "All saved sessions and their transcripts and translations will be permanently deleted. The current session is excluded."
                 : "All saved sessions and their transcripts and translations will be permanently deleted.")
        }
        .alert("Rename Session", isPresented: Binding(
            get: { pendingRename != nil }, set: { if !$0 { pendingRename = nil } }
        ), presenting: pendingRename) { session in
            TextField("Session title", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") { Task { await rename(session) } }
                .keyboardShortcut(.defaultAction)
        }
        .sheet(isPresented: $exporting) {
            if let selected {
                ExportOptions(defaultFormat: model.settings.exportFormat, defaultDisplay: model.settings.exportDisplay) { format, display in
                    await model.exportHistory(selected, format: format, display: display)
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sessions").font(.headline)
                Button(role: .destructive) { confirmingDeleteAll = true } label: {
                    Label("Delete All History", systemImage: "trash")
                }
                .foregroundStyle(canDeleteHistory ? Color.red : Color.secondary)
                .disabled(!canDeleteHistory)
                if model.sessionActive {
                    Text("The current session is excluded.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            Divider()
            List(selection: $selection) {
                ForEach(sessions) { session in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.title).lineLimit(1)
                            Text(session.startedAt.formatted(date: .numeric, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(CaptionTime.clock(session.duration))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .tag(session.id)
                    .contextMenu { actions(session) }
                }
                if canLoadMoreSessions {
                    Button("Load More Sessions") { Task { await loadMoreSessions() } }
                        .buttonStyle(.borderless)
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if sessions.isEmpty {
                    Text("No saved sessions").foregroundStyle(.secondary).font(.callout)
                }
            }
        }
        .background(Palette.canvas)
    }

    @ViewBuilder
    private var detail: some View {
        if let selected {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selected.title).font(.title2.bold()).lineLimit(1)
                        Text("\(selected.status.title) · \(CaptionTime.clock(selected.duration))")
                            .foregroundStyle(.secondary).font(.callout)
                    }
                    Spacer()
                    Button { exporting = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    Menu {
                        actions(selected)
                    } label: {
                        Image(systemName: "ellipsis.circle").accessibilityLabel("Session actions")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                TextField("Search original and translated text", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(20)
                Divider()
                if segments.isEmpty && !loading {
                    ContentUnavailableView(query.isEmpty ? "No Transcript" : "No Matches",
                                           systemImage: query.isEmpty ? "text.bubble" : "magnifyingglass")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(segments) { segment in
                                let current = model.currentTranslation(for: segment)
                                TranscriptRow(segment: current, showOriginal: true,
                                              showTranslation: selected.options.translate, showSource: true,
                                              retry: TranslationRetryAction(model: model, segment: current) { result in
                                                  if let index = segments.firstIndex(where: { $0.id == result.id }) {
                                                      segments[index] = result
                                                  }
                                              })
                                Divider()
                            }
                            if canLoadMoreSegments {
                                Button("Load More Captions") { Task { await loadSegments(reset: false) } }
                                    .disabled(loading)
                                    .padding(.vertical, 16)
                            }
                            if loading { ProgressView().controlSize(.small).padding(.vertical, 14) }
                        }
                        .padding(.horizontal, 20)
                    }
                    .id(searchIdentity)
                }
            }
        } else {
            ContentUnavailableView("Select a Session", systemImage: "clock.arrow.circlepath",
                                   description: Text("Open a saved session to read, search, or export its transcript."))
        }
    }

    private func actions(_ session: CaptionSession) -> some View {
        Group {
            Button("Rename…") {
                newTitle = session.title
                pendingRename = session
            }
            .disabled(isActive(session))
            Button("Delete…", role: .destructive) { pendingDelete = session }
                .disabled(isActive(session))
        }
    }

    private func isActive(_ session: CaptionSession) -> Bool {
        model.sessionActive && model.session?.id == session.id
    }

    private func reloadSessions() async {
        let revision = model.historyRevision
        do {
            let values = try await model.repository?.sessions() ?? []
            guard revision == model.historyRevision, !Task.isCancelled else { return }
            sessions = values
            canLoadMoreSessions = values.count == 100
            if let selection, !values.contains(where: { $0.id == selection }) { self.selection = nil }
        } catch {
            model.notice = error.localizedDescription
        }
    }

    private func loadMoreSessions() async {
        let revision = model.historyRevision
        do {
            let offset = sessions.count
            let values = try await model.repository?.sessions(offset: offset) ?? []
            guard revision == model.historyRevision, sessions.count == offset else { return }
            sessions.append(contentsOf: values)
            canLoadMoreSessions = values.count == 100
        } catch {
            model.notice = error.localizedDescription
        }
    }

    private func loadSegments(reset: Bool) async {
        guard let selection, let repository = model.repository, reset || !loading else { return }
        loading = true
        let identity = searchIdentity
        defer { if searchIdentity == identity { loading = false } }
        do {
            let results = try await repository.segments(selection, search: query, limit: 160,
                                                        offset: reset ? 0 : segments.count, newestFirst: true)
            guard searchIdentity == identity, !Task.isCancelled else { return }
            if reset { segments = results } else { segments.append(contentsOf: results) }
            canLoadMoreSegments = results.count == 160
        } catch {
            model.notice = error.localizedDescription
        }
    }

    private func rename(_ session: CaptionSession) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isActive(session) else { return }
        do {
            try await model.repository?.rename(session.id, title: trimmed)
            if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index].title = trimmed }
            model.reflectRename(session.id, title: trimmed)
        } catch {
            model.notice = error.localizedDescription
        }
    }

    private func delete(_ session: CaptionSession) async {
        guard !isActive(session) else { return }
        do {
            try await model.repository?.delete(session.id)
            if selection == session.id { selection = nil }
            sessions.removeAll { $0.id == session.id }
            model.reflectDelete(session.id)
        } catch {
            model.notice = error.localizedDescription
        }
    }

    private func deleteAll() async {
        guard canDeleteHistory else { return }
        do {
            try await model.deleteSavedHistory()
            await reloadSessions()
        } catch {
            model.notice = error.localizedDescription
        }
    }

    private struct SearchIdentity: Hashable {
        let id: UUID?
        let query: String
        let revision: Int
    }
}
