import Foundation
import Combine

/// Single owner of the app's IOKit watchers. Lives in the backend (not the app
/// target) so both the menu bar app and the Pro plugin can share one set of
/// watchers instead of each constructing its own. Builds the watchers once,
/// starts them together, polls every second, and fires a burst of refreshes on
/// plug/unplug.
@MainActor
public final class WatcherHub {
    public static let shared = WatcherHub()

    public let portWatcher    = AppleHPMInterfaceWatcher()
    public let deviceWatcher  = USBWatcher()
    public let powerWatcher   = PowerSourceWatcher()
    public let pdWatcher      = USBPDSOPWatcher()
    public let tbWatcher      = IOIOThunderboltSwitchWatcher()
    public let usb3Watcher    = USB3TransportWatcher()
    public let trmWatcher     = TRMTransportWatcher()
    public let displayWatcher = DisplayPortTransportWatcher()

    private var isStarted = false
    private var pollTask: Task<Void, Never>?
    private var burstTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var isRefreshing = false

    private init() {}

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        portWatcher.start()
        deviceWatcher.start()
        powerWatcher.start()
        pdWatcher.start()
        tbWatcher.start()
        usb3Watcher.start()
        trmWatcher.start()
        displayWatcher.start()

        startPoll()
        setupBurstTriggers()
    }

    public func refreshAll() {
        isRefreshing = true
        defer { isRefreshing = false }
        portWatcher.refresh()
        powerWatcher.refresh()
        pdWatcher.refresh()
        tbWatcher.refresh()
        usb3Watcher.refresh()
        trmWatcher.refresh()
        displayWatcher.refresh()
    }

    private func startPoll() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.refreshAll()
            }
        }
    }

    private func setupBurstTriggers() {
        deviceWatcher.$devices
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, !self.isRefreshing else { return }
                self.scheduleBurst()
            }
            .store(in: &cancellables)

        powerWatcher.$sources
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, !self.isRefreshing else { return }
                self.scheduleBurst()
            }
            .store(in: &cancellables)

        pdWatcher.$identities
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, !self.isRefreshing else { return }
                self.scheduleBurst()
            }
            .store(in: &cancellables)
    }

    private func scheduleBurst() {
        burstTask?.cancel()
        burstTask = Task { @MainActor [weak self] in
            for delay in [150, 500, 1500, 3000, 6000] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.refreshAll()
            }
        }
    }
}
