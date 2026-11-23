import Foundation
import ScreenCaptureKit

enum SystemAudioAccess: Equatable {
    case unchecked, verified, declined

    var title: String {
        switch self {
        case .unchecked: "Checked at capture start"
        case .verified: "Stream started"
        case .declined: "macOS declined screen capture"
        }
    }
}

struct SystemAudioCaptureFailure: LocalizedError {
    enum Stage: String {
        case discovery = "Finding shareable displays"
        case selection = "Choosing a display"
        case registration = "Registering the audio output"
        case startup = "Starting the audio stream"
        case interruption = "System Audio stopped"
        case initialization = "Initializing System Audio capture"
        case samples = "Waiting for system audio buffers"
        case processing = "Processing system audio"
    }

    enum Kind {
        case authorization, sourceUnavailable, configuration, initialization, stream, selectionCancelled, noSamples, processing
    }

    let stage: Stage
    let kind: Kind
    let underlying: (any Error)?

    init(_ stage: Stage, kind: Kind, underlying: (any Error)? = nil) {
        self.stage = stage
        self.kind = kind
        self.underlying = underlying
    }

    init(_ stage: Stage, error: any Error) {
        let kind: Kind
        switch (error as? SCStreamError)?.code {
        case .userDeclined:
            kind = .authorization
        case .noDisplayList, .noWindowList, .noCaptureSource:
            kind = .sourceUnavailable
        case .invalidParameter, .missingEntitlements:
            kind = .configuration
        default:
            kind = .stream
        }
        self.init(stage, kind: kind, underlying: error)
    }

    var errorDescription: String? {
        let detail = underlying.map { " \($0.localizedDescription)" } ?? ""
        switch kind {
        case .authorization:
            return "macOS declined ScreenCaptureKit access for this copy of LocalCaption. Check Screen & System Audio Recording for the exact app you opened. Quit and reopen the app if macOS asks."
        case .sourceUnavailable:
            return "\(stage.rawValue): ScreenCaptureKit found no available capture source. Connect or unlock a display and try again.\(detail)"
        case .configuration:
            return "\(stage.rawValue): The System Audio capture configuration is invalid.\(detail)"
        case .initialization, .stream, .processing:
            return "\(stage.rawValue) failed.\(detail)"
        case .noSamples:
            return "System Audio started but hasn’t received any buffers. Play audio in another app and check the selected source."
        case .selectionCancelled:
            return "Display selection was canceled. Start System Audio again to choose a display."
        }
    }
}

// Each instance owns one picker request. Only the MainActor touches its continuation.
@MainActor
final class ScreenAudioPicker: NSObject, SCContentSharingPickerObserver {
    // The callback hands off a filter which we pass to SCStream without mutating it.
    private struct SelectedFilter: @unchecked Sendable {
        let value: SCContentFilter
    }

    private var selection: CheckedContinuation<SelectedFilter, any Error>?
    private var active = false

    func chooseDisplay() async throws -> SCContentFilter {
        try Task.checkCancellation()
        let selected: SelectedFilter = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                selection = continuation
                let picker = SCContentSharingPicker.shared
                var config = SCContentSharingPickerConfiguration()
                config.allowedPickerModes = [.singleDisplay]
                config.allowsChangingSelectedContent = false
                picker.defaultConfiguration = config
                picker.maximumStreamCount = 1
                picker.add(self)
                picker.isActive = true
                active = true
                CaptureDiagnostics.audio.info("Presenting macOS display picker for System Audio")
                picker.present(using: .display)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
        return selected.value
    }

    func stop() {
        resolve(.failure(CancellationError()))
        if active {
            SCContentSharingPicker.shared.isActive = false
            active = false
        }
    }

    private func resolve(_ result: Result<SelectedFilter, any Error>) {
        guard let continuation = selection else { return }
        selection = nil
        SCContentSharingPicker.shared.remove(self)
        continuation.resume(with: result)
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        guard stream == nil else { return }
        Task { @MainActor in
            resolve(.failure(SystemAudioCaptureFailure(.selection, kind: .selectionCancelled)))
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter,
                                          for stream: SCStream?) {
        guard stream == nil else { return }
        let selected = SelectedFilter(value: filter)
        Task { @MainActor in resolve(.success(selected)) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in resolve(.failure(error)) }
    }
}
