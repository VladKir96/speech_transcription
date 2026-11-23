import AppKit
import Carbon.HIToolbox
import SwiftUI

enum MicrophoneControlMode: String, Codable, CaseIterable, Identifiable {
    case toggle, pushToTalk
    var id: String { rawValue }
    var title: String { self == .toggle ? "Toggle" : "Push-to-Talk" }
}

struct MicrophoneShortcut: Codable, Equatable {
    enum Key: String, Codable, CaseIterable, Identifiable {
        case disabled, space, m, f8, f9
        var id: String { rawValue }
        var title: String { self == .disabled ? "None" : self == .space ? "Space" : rawValue.uppercased() }
        var code: UInt16? {
            switch self {
            case .disabled: nil
            case .space: UInt16(kVK_Space)
            case .m: UInt16(kVK_ANSI_M)
            case .f8: UInt16(kVK_F8)
            case .f9: UInt16(kVK_F9)
            }
        }
    }

    enum Modifiers: String, Codable, CaseIterable, Identifiable {
        case none, option, controlOption
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "None"
            case .option: "Option"
            case .controlOption: "Control + Option"
            }
        }
        var appKit: NSEvent.ModifierFlags {
            switch self {
            case .none: []
            case .option: [.option]
            case .controlOption: [.control, .option]
            }
        }
        var carbon: UInt32 {
            switch self {
            case .none: 0
            case .option: UInt32(optionKey)
            case .controlOption: UInt32(controlKey | optionKey)
            }
        }
    }

    var mode = MicrophoneControlMode.toggle
    var key = Key.space
    var modifiers = Modifiers.none
    var global = false
    var canRegisterGlobally: Bool { mode == .toggle && key.code != nil && modifiers != .none }
}

struct MicrophoneShortcutView: NSViewRepresentable {
    let model: AppModel
    let shortcut: MicrophoneShortcut
    let recording: Bool

    func makeNSView(context: Context) -> MicrophoneShortcutHost { MicrophoneShortcutHost() }

    func updateNSView(_ view: MicrophoneShortcutHost, context: Context) {
        view.configure(model, shortcut: shortcut, recording: recording)
    }

    static func dismantleNSView(_ view: MicrophoneShortcutHost, coordinator: ()) { view.uninstall() }
}

@MainActor
final class MicrophoneShortcutHost: NSView {
    private weak var model: AppModel?
    private var shortcut = MicrophoneShortcut()
    private var recording = false
    private var localMonitor: Any?
    private var pressedKey: UInt16?
    private var globalPressed = false
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?

    func configure(_ model: AppModel, shortcut: MicrophoneShortcut, recording: Bool) {
        guard self.model !== model || self.shortcut != shortcut || self.recording != recording else { return }
        uninstall()
        self.model = model
        self.shortcut = shortcut
        self.recording = recording
        install()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        uninstall()
        install()
    }

    private func install() {
        guard recording, let window, let key = shortcut.key.code else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(lostFocus),
            name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(lostFocus),
            name: NSApplication.didResignActiveNotification, object: NSApp)
        if shortcut.global, shortcut.canRegisterGlobally, installGlobal(key: key) { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handleLocal(event)
        }
    }

    func uninstall() {
        lostFocus()
        NotificationCenter.default.removeObserver(self)
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        globalPressed = false
    }

    @objc private func lostFocus() {
        if pressedKey != nil, shortcut.mode == .pushToTalk { model?.endPushToTalk() }
        pressedKey = nil
    }

    private var modifiers: NSEvent.ModifierFlags { [.command, .control, .option, .shift] }

    private func handleLocal(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyUp, pressedKey == event.keyCode {
            lostFocus()
            return nil
        }
        let flags = event.modifierFlags.intersection(modifiers)
        if event.type == .flagsChanged {
            if pressedKey != nil, !flags.isSuperset(of: shortcut.modifiers.appKit) { lostFocus() }
            return event
        }
        guard event.type == .keyDown, event.keyCode == shortcut.key.code,
              flags == shortcut.modifiers.appKit, NSApp.keyWindow === window, window?.attachedSheet == nil,
              !(window?.firstResponder is NSTextView), !(window?.firstResponder is NSTextField),
              let model, model.recording else { return event }
        guard !event.isARepeat, pressedKey == nil else { return nil }
        pressedKey = event.keyCode
        switch shortcut.mode {
        case .toggle: model.toggleMicrophone()
        case .pushToTalk: model.beginPushToTalk()
        }
        return nil
    }

    private func installGlobal(key: UInt16) -> Bool {
        let target = GetApplicationEventTarget()
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let install = InstallEventHandler(target, { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x4C434D43, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            return MainActor.assumeIsolated {
                Unmanaged<MicrophoneShortcutHost>.fromOpaque(context).takeUnretainedValue().handleGlobal(pressed)
                return noErr
            }
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let status = install == noErr
            ? RegisterEventHotKey(UInt32(key), shortcut.modifiers.carbon, EventHotKeyID(signature: 0x4C434D43, id: 1),
                                  target, OptionBits(kEventHotKeyExclusive), &hotKey)
            : install
        if status != noErr, let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
        let issue = status == noErr ? nil : "The global microphone shortcut is unavailable. The focused shortcut is still active."
        Task { @MainActor [weak self] in
            guard let self, self.recording else { return }
            self.model?.microphoneShortcutIssue = issue
        }
        return status == noErr
    }

    private func handleGlobal(_ pressed: Bool) {
        if pressed, !globalPressed { model?.toggleMicrophone() }
        globalPressed = pressed
    }
}
