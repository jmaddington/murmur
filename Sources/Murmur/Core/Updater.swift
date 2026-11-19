import AppKit
import Observation
import Sparkle

/// Sparkle auto-update. The feed is `appcast.xml` attached to the latest GitHub Release
/// (see SUFeedURL in Info.plist and scripts/make-appcast.sh); updates are EdDSA-signed.
// AIDEV-NOTE: never started in E2E/demo mode; Sparkle UI would block the automated runs.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?

    private(set) var isRunning = false
    private(set) var canCheck = false
    var automaticallyChecks = false {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }
    var automaticallyInstalls = false {
        didSet { controller?.updater.automaticallyDownloadsUpdates = automaticallyInstalls }
    }

    var lastChecked: Date? { controller?.updater.lastUpdateCheckDate }

    func start() {
        guard controller == nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = c
        isRunning = true
        automaticallyChecks = c.updater.automaticallyChecksForUpdates
        automaticallyInstalls = c.updater.automaticallyDownloadsUpdates
        canCheck = c.updater.canCheckForUpdates
        canCheckObservation = c.updater.observe(\.canCheckForUpdates, options: [.new]) { updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in Updater.shared.canCheck = value }
        }
    }

    func checkForUpdates() {
        // Menu bar (accessory) apps must come forward or Sparkle's window opens behind others.
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    static var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
