import AppKit
import Observation
import Sparkle

@MainActor
@Observable
final class ApplicationUpdates: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    private(set) var automaticallyChecks = false
    private(set) var lastCheck: Date?
    private(set) var canCheck = false
    private(set) var isConfigured = false
    private(set) var deferredVersion: String?
    private(set) var checkMessage: String?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var checkingDuringSession = false
    @ObservationIgnored private var noUpdateFound = false
    @ObservationIgnored private var offeredVersion: String?

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func start(model: AppModel) {
        guard controller == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        self.model = model
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self,
                                                      userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        do {
            try updater.start()
        } catch {
            checkMessage = error.localizedDescription
            return
        }
        isConfigured = true
        automaticallyChecks = updater.automaticallyChecksForUpdates
        lastCheck = updater.lastUpdateCheckDate
        canCheck = updater.canCheckForUpdates
        observations = [
            updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
                Task { @MainActor in self?.refreshCheckState() }
            },
            updater.observe(\.lastUpdateCheckDate) { [weak self] _, _ in
                Task { @MainActor in self?.refreshCheckState() }
            }
        ]
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard isConfigured, let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        automaticallyChecks = updater.automaticallyChecksForUpdates
    }

    func check() {
        guard isConfigured, let updater = controller?.updater, updater.canCheckForUpdates else { return }
        checkMessage = nil
        if model?.canOfferUpdate == false {
            if updater.sessionInProgress {
                deferredVersion = offeredVersion ?? deferredVersion
                return
            }
            deferredVersion = nil
            checkingDuringSession = true
            noUpdateFound = false
            checkMessage = "Checking for updates…"
            updater.checkForUpdateInformation()
        } else {
            deferredVersion = nil
            updater.checkForUpdates()
        }
    }

    func dismissNotice() {
        deferredVersion = nil
        checkMessage = nil
    }

    private func refreshCheckState() {
        guard let updater = controller?.updater else { return }
        canCheck = updater.canCheckForUpdates
        lastCheck = updater.lastUpdateCheckDate
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        offeredVersion = item.displayVersionString
        if updateCheck == .updateInformation {
            deferredVersion = item.displayVersionString
        } else if updateCheck == .updates, model?.canOfferUpdate != true {
            deferredVersion = item.displayVersionString
            throw NSError(domain: "local.caption.macos.updates", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Finish the current session and save its transcript before updating."
            ])
        }
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                               andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        offeredVersion = update.displayVersionString
        if !handleShowingUpdate { deferredVersion = update.displayVersionString }
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .install, model?.reserveUpdate() != true {
            deferredVersion = updateItem.displayVersionString
        }
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        guard model?.reserveUpdate() == true else {
            deferredVersion = offeredVersion
            return false
        }
        return true
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        if checkingDuringSession { noUpdateFound = true }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock install: @escaping () -> Void) -> Bool {
        guard let model else { return true }
        // Sparkle runs its installer out of process. Finish cleanup before handing it control.
        Task {
            if await model.prepareForUpdate() {
                install()
            }
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        model?.endUpdate()
        refreshCheckState()
        offeredVersion = nil
        if updateCheck == .updateInformation {
            checkingDuringSession = false
            if noUpdateFound {
                checkMessage = "LocalCaption is up to date."
            } else if error != nil {
                checkMessage = "Couldn’t check for updates. Try again when you’re online."
            } else {
                checkMessage = nil
            }
        }
    }
}
