// Self-hosted update checker.
import Foundation
import AppKit
import UserNotifications
import os.log
import WhatCableCore

struct AvailableUpdate: Equatable {
    let version: String
    let url: URL
    let downloadURL: URL?
    let notes: String?
}

/// Polls the GitHub releases API for newer versions of WhatCable.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    private nonisolated static let log = Logger(subsystem: "uk.whatcable.whatcable", category: "updates")
    private static let endpoint = URL(string: "https://api.github.com/repos/darrylmorley/whatcable/releases/latest")!
    private static let pollInterval: TimeInterval = 6 * 60 * 60 // 6h

    @Published private(set) var available: AvailableUpdate?
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheck: Date?

    private var timer: Timer?
    private var notifiedVersion: String?
    /// When a manual "Check for Updates" click arrives while a silent
    /// background check is in flight, we set this so the in-flight result
    /// surfaces a visible alert instead of being silently swallowed.
    private var pendingVisibleCheck = false

    private init() {}

    func start() {
        guard timer == nil else { return }
        check(silent: true)
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(silent: true) }
        }
    }

    /// Fire a silent check only if the last one is older than `staleAfter` (or
    /// none has run yet). Called when the menu bar panel opens so the displayed
    /// "X available" version is current before the user acts, without hitting
    /// the API on every open. The 6-hour background poll stays the baseline.
    /// (issue #372: keep the offered version fresh so a user isn't surprised by
    /// landing on a newer build than the one shown.)
    func checkIfStale(staleAfter: TimeInterval = 30 * 60) {
        // Don't re-check mid-install. A check that finds the running version is
        // newest sets `available = nil`, which would yank the install progress
        // banner out from under an in-flight install. The install path does its
        // own pre-download re-check anyway.
        guard case .idle = Installer.shared.state else { return }
        if Self.isStale(lastCheck: lastCheck, now: Date(), staleAfter: staleAfter) {
            check(silent: true)
        }
    }

    /// Pure throttle decision: a check is due if none has run yet, or the last
    /// one is at least `staleAfter` old. Split out so the policy is unit-tested
    /// without a live network call. Boundary is inclusive (>=).
    nonisolated static func isStale(lastCheck: Date?, now: Date, staleAfter: TimeInterval) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= staleAfter
    }

    /// Manually trigger a check. When `silent` is false, surfaces an alert
    /// for the "no update" case so the user gets feedback from the menu item.
    func check(silent: Bool) {
        if isChecking {
            // A check is already in flight. If the user explicitly asked for
            // one, upgrade the in-flight result to non-silent so they still
            // get feedback. Multiple manual clicks coalesce into one alert.
            if !silent { pendingVisibleCheck = true }
            return
        }
        isChecking = true
        pendingVisibleCheck = !silent

        URLSession.shared.dataTask(with: Self.makeReleaseRequest()) { [weak self] data, _, error in
            Task { @MainActor in
                guard let self else { return }
                self.isChecking = false
                // If a manual click arrived during the in-flight check, this
                // gets surfaced. Reset for the next run.
                let visible = self.pendingVisibleCheck
                self.pendingVisibleCheck = false

                if let error {
                    // Don't stamp lastCheck on failure: the panel-open throttle
                    // uses it to mean "we successfully learned the latest N
                    // minutes ago", so a failed check should let the next panel
                    // open retry instead of suppressing checks for 30 minutes
                    // (e.g. after the Mac comes back online).
                    Self.log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
                    if visible { self.showAlert(title: "Couldn't check for updates", message: error.localizedDescription) }
                    return
                }

                guard let data, let release = Self.parseRelease(from: data) else {
                    if visible { self.showAlert(title: "Couldn't check for updates", message: "Unexpected response from GitHub.") }
                    return
                }

                // Only a successful, parsed response counts as a check for
                // throttle purposes.
                self.lastCheck = Date()

                if Self.isNewer(remote: release.version, current: AppInfo.version) {
                    let update = release
                    self.available = update
                    self.postNotification(update)
                    if visible {
                        // Manual "Check for Updates" click: surface a modal
                        // alert so the user gets the same feedback they get
                        // when already up-to-date, with a button to open the
                        // release page directly.
                        self.showUpdateAlert(update)
                    }
                } else {
                    self.available = nil
                    if visible {
                        self.showAlert(
                            title: "You're up to date",
                            message: "WhatCable \(AppInfo.version) is the latest version."
                        )
                    }
                }
            }
        }.resume()
    }

    /// Fetch the current latest release without touching published state or
    /// surfacing any UI. Used for the pre-install re-check (issue #372) so a
    /// release that shipped since the last background poll isn't missed.
    /// Returns nil on any network or parse error: callers fall back to
    /// whatever update they already had.
    func fetchLatestRelease() async -> AvailableUpdate? {
        do {
            let (data, _) = try await URLSession.shared.data(for: Self.makeReleaseRequest())
            return Self.parseRelease(from: data)
        } catch {
            Self.log.error("Pre-install update re-check failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Build the `releases/latest` request used by both the background poll and
    /// the pre-install re-check, so the endpoint, headers and timeout live in
    /// one place.
    private nonisolated static func makeReleaseRequest() -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WhatCable/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        return request
    }

    /// Sync the published `available` pointer when a pre-install re-check finds
    /// a newer release than the one originally surfaced, so the panel row
    /// reflects the version that's actually being installed.
    func updateAvailable(to update: AvailableUpdate) {
        available = update
    }

    /// Parse GitHub's `releases/latest` JSON into an `AvailableUpdate`. Returns
    /// nil if the payload is missing the fields we need. Does not compare
    /// against the running version; callers apply `isNewer` themselves.
    nonisolated static func parseRelease(from data: Data) -> AvailableUpdate? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let urlString = json["html_url"] as? String,
              let url = URL(string: urlString) else {
            return nil
        }
        // releases/latest never returns pre-releases, but this is a client-side
        // backstop so a mis-flagged release can never be offered as an update.
        if json["prerelease"] as? Bool == true {
            return nil
        }
        let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let notes = json["body"] as? String
        let downloadURL = (json["assets"] as? [[String: Any]])?
            .first(where: { ($0["name"] as? String) == "WhatCable.zip" })
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap { URL(string: $0) }
            .flatMap { isTrustedDownloadURL($0) ? $0 : nil }
        return AvailableUpdate(version: remote, url: url, downloadURL: downloadURL, notes: notes)
    }

    private func postNotification(_ update: AvailableUpdate) {
        guard AppSettings.shared.notifyOnChanges, AppSettings.shared.notifyOnUpdates else { return }
        // Stamp only once we actually post, not when the version is first seen.
        // Otherwise re-enabling either toggle after an update was already
        // detected would find this version "already notified" and stay silent.
        guard notifiedVersion != update.version else { return }
        notifiedVersion = update.version
        let content = UNMutableNotificationContent()
        content.title = "WhatCable \(update.version) available"
        content.body = "You're on \(AppInfo.version). Click to view release notes."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "update-\(update.version)", content: content, trigger: nil)
        )
    }

    private func showAlert(title: String, message: String) {
        // LSUIElement apps can't reliably bring a modal alert to the front.
        // Briefly promote to a regular app so the alert takes focus, then
        // restore accessory policy after dismissal.
        let originalPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.window.level = .floating
        alert.runModal()

        NSApp.setActivationPolicy(originalPolicy)
    }

    private func showUpdateAlert(_ update: AvailableUpdate) {
        let originalPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        let alert = NSAlert()
        alert.messageText = "WhatCable \(update.version) is available"
        alert.informativeText = "You're on \(AppInfo.version). Open the release page to read the notes and download."
        alert.window.level = .floating
        let hasDownload = update.downloadURL != nil
        if hasDownload {
            alert.addButton(withTitle: "Update")
        }
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()

        NSApp.setActivationPolicy(originalPolicy)

        if hasDownload && response == .alertFirstButtonReturn {
            Installer.shared.install(update)
        } else if response == (hasDownload ? .alertSecondButtonReturn : .alertFirstButtonReturn) {
            NSWorkspace.shared.open(update.url)
        }
    }

    /// Compare dot-separated numeric versions. Non-numeric segments compare lexically.
    nonisolated static func isNewer(remote: String, current: String) -> Bool {
        AppInfo.isNewer(remote: remote, current: current)
    }

    /// Only accept download URLs from GitHub's release asset CDN.
    nonisolated static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme == "https",
              let host = url.host else { return false }
        let trusted = ["objects.githubusercontent.com", "github.com", "releases.githubusercontent.com"]
        return trusted.contains(host)
    }
}

