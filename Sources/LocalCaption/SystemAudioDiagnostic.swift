import AppKit
import CaptionCore
import Foundation
import os
import SwiftUI

struct AudioProbeSnapshot: Sendable {
    var buffers = 0
    var nativeFrames = 0
    var normalizedFrames = 0
    var peak: Float = 0
    var sumOfSquares = 0.0

    var rms: Double {
        normalizedFrames > 0 ? sqrt(sumOfSquares / Double(normalizedFrames)) : 0
    }
}

final class AudioProbeMeasurements: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: AudioProbeSnapshot())

    func received(frames: Int) {
        state.withLock {
            $0.buffers += 1
            $0.nativeFrames += frames
        }
    }

    func normalized(_ samples: [Float]) {
        var peak: Float = 0
        var sum = 0.0
        for sample in samples {
            peak = max(peak, abs(sample))
            sum += Double(sample) * Double(sample)
        }
        state.withLock { [peak, sum] in
            $0.normalizedFrames += samples.count
            $0.peak = max($0.peak, peak)
            $0.sumOfSquares += sum
        }
    }

    func snapshot() -> AudioProbeSnapshot { state.withLock { $0 } }
}

@MainActor @Observable
final class SystemAudioProbe {
    var selection = SystemAudioSelection.automatic
    private(set) var snapshot = AudioProbeSnapshot()
    private(set) var status = "Ready"
    private(set) var issue: String?
    private(set) var running = false
    let identity = CaptureDiagnostics.identity()

    @ObservationIgnored private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        let selection = selection
        running = true
        issue = nil
        status = "Starting capture"
        snapshot = AudioProbeSnapshot()
        task = Task { await run(selection: selection) }
    }

    func stop() { task?.cancel() }

    func stopAndWait() async {
        task?.cancel()
        await task?.value
    }

    private func run(selection: SystemAudioSelection) async {
        let measurement = AudioProbeMeasurements()
        let capture = SystemCapture(measurement: measurement)
        let pair = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(96))
        let consumer = Task.detached {
            for await chunk in pair.stream { measurement.normalized(chunk.samples) }
        }
        do {
            try await capture.start(selection: selection, clock: CaptureClock(), chunks: pair.continuation,
                issue: { [weak self] issue in
                    Task { @MainActor in self?.issue = issue }
                }, failure: { [weak self] failure in
                    Task { @MainActor in
                        self?.issue = failure.localizedDescription
                        self?.stop()
                    }
                })
            status = "Capture started"
            while !Task.isCancelled {
                snapshot = measurement.snapshot()
                try await Task.sleep(for: .milliseconds(250))
            }
        } catch is CancellationError {
            CaptureDiagnostics.audio.debug("System Audio diagnostic stopped")
        } catch {
            issue = error.localizedDescription
            CaptureDiagnostics.failure("System Audio diagnostic", error, logger: CaptureDiagnostics.audio)
        }
        await capture.stop()
        pair.continuation.finish()
        await consumer.value
        snapshot = measurement.snapshot()
        CaptureDiagnostics.audio.notice("Probe summary: buffers=\(self.snapshot.buffers) nativeFrames=\(self.snapshot.nativeFrames) normalizedFrames=\(self.snapshot.normalizedFrames) peak=\(self.snapshot.peak) rms=\(self.snapshot.rms)")
        status = "Stopped"
        running = false
        task = nil
    }
}

struct SystemAudioDiagnosticApp: App {
    @NSApplicationDelegateAdaptor(ProbeAppDelegate.self) private var delegate
    @State private var probe = SystemAudioProbe()

    var body: some Scene {
        Window("System Audio Diagnostic", id: "capture-probe") {
            VStack(alignment: .leading, spacing: 16) {
                Text("System Audio Diagnostic").font(.title2.bold())
                Text("Start capture, then play speech in your browser. This test measures audio before transcription.")
                    .foregroundStyle(.secondary)
                HStack {
                    Picker("Capture", selection: $probe.selection) {
                        ForEach(SystemAudioSelection.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(probe.running)
                    Spacer()
                    Button("Start Capture") { probe.start() }
                        .disabled(probe.running)
                    Button("Stop") { probe.stop() }
                        .disabled(!probe.running)
                }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow { Text("Status"); Text(probe.status) }
                    GridRow { Text("Native buffers"); Text(probe.snapshot.buffers.formatted()) }
                    GridRow { Text("Native frames"); Text(probe.snapshot.nativeFrames.formatted()) }
                    GridRow { Text("Normalized frames"); Text(probe.snapshot.normalizedFrames.formatted()) }
                    GridRow { Text("Peak"); Text(probe.snapshot.peak.formatted(.number.precision(.fractionLength(6)))) }
                    GridRow { Text("RMS"); Text(probe.snapshot.rms.formatted(.number.precision(.fractionLength(6)))) }
                    GridRow { Text("Audio energy"); Text(probe.snapshot.peak > 0.0001 ? "Detected" : "Awaiting audio") }
                }
                .monospacedDigit()
                if let issue = probe.issue {
                    Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                Divider()
                Text(probe.identity.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(22)
            .frame(minWidth: 565, minHeight: 360)
            .onAppear { delegate.probe = probe }
            .onDisappear { probe.stop() }
        }
        .defaultSize(width: 630, height: 475)
    }
}

@MainActor
final class ProbeAppDelegate: NSObject, NSApplicationDelegate {
    weak var probe: SystemAudioProbe?
    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let probe, probe.running else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            await probe.stopAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
