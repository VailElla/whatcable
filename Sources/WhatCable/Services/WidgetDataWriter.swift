import Foundation
import Combine
import WidgetKit
import os.log
import WhatCableCore
import WhatCableDarwinBackend
import WhatCableAppKit

/// Writes a pre-computed WidgetSnapshot to the macOS team-prefixed App Group
/// shared container whenever cable state changes, then tells WidgetKit to
/// refresh.
///
/// WidgetKit extensions are sandboxed even though the WhatCable host app is
/// not. For Developer ID builds, the `group.` App Group form requires an
/// embedded provisioning profile. Using `M4RUJ7W6MP.uk.whatcable.whatcable`
/// keeps the distribution profile-free while giving both processes the same
/// sandbox-authorized container.
///
/// Reads from the shared WatcherHub.
@MainActor
final class WidgetDataWriter {
    static let shared = WidgetDataWriter()

    private nonisolated static let log = Logger(
        subsystem: "uk.whatcable.whatcable",
        category: "widget-data"
    )

    private var portWatcher: AppleHPMInterfaceWatcher { WatcherHub.shared.portWatcher }
    private var deviceWatcher: USBWatcher { WatcherHub.shared.deviceWatcher }
    private var powerWatcher: PowerSourceWatcher { WatcherHub.shared.powerWatcher }
    private var pdWatcher: USBPDSOPWatcher { WatcherHub.shared.pdWatcher }
    private var tbWatcher: IOIOThunderboltSwitchWatcher { WatcherHub.shared.tbWatcher }
    private var usb3Watcher: USB3TransportWatcher { WatcherHub.shared.usb3Watcher }
    private var trmWatcher: TRMTransportWatcher { WatcherHub.shared.trmWatcher }

    private var cancellables = Set<AnyCancellable>()
    private var writeTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var lastSnapshot: WidgetSnapshot?
    private var isStarted = false

    private var contributorCancellables = Set<AnyCancellable>()

    /// How often to re-write the snapshot even when ports haven't changed.
    /// Keeps the timestamp fresh so the widget's staleness check doesn't
    /// discard valid data just because nothing changed for a while.
    private let heartbeatInterval: Duration = .seconds(120)

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        Self.log.debug("WidgetDataWriter starting (sharedFileURL: \(WidgetSnapshot.sharedFileURL?.path ?? "nil"))")
        // Write an initial snapshot once watchers have had a tick to populate.
        DispatchQueue.main.async { [weak self] in
            self?.scheduleWrite()
        }

        // Watch all seven signals. A single cable plug can fire several of
        // these within a few ms, so scheduleWrite() debounces into one write.
        WatcherHub.shared.portWatcher.$ports
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleWrite() }
            .store(in: &cancellables)

        WatcherHub.shared.deviceWatcher.$devices
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleWrite() }
            .store(in: &cancellables)

        WatcherHub.shared.powerWatcher.$sources
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleWrite() }
            .store(in: &cancellables)

        WatcherHub.shared.pdWatcher.$identities
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleWrite() }
            .store(in: &cancellables)

        WatcherHub.shared.tbWatcher.$switches
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleWrite() }
            .store(in: &cancellables)

        WatcherHub.shared.usb3Watcher.$transports
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleWrite() }
            .store(in: &cancellables)

        WatcherHub.shared.trmWatcher.$cioCapabilities
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleWrite() }
            .store(in: &cancellables)

        for contributor in PluginRegistry.shared.widgetDataContributors {
            contributor.start()
            contributor.changes
                .sink { [weak self] in self?.scheduleWrite() }
                .store(in: &contributorCancellables)
        }

        // Periodic heartbeat: re-write the snapshot with a fresh timestamp
        // even when ports haven't changed. This prevents the widget's
        // staleness check from discarding valid data during long idle periods.
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.heartbeatInterval ?? .seconds(120))
                guard !Task.isCancelled, let self else { return }
                self.forceWrite()
            }
        }
    }

    /// Debounced write. Cancels any pending write and waits 200ms for
    /// additional watcher updates to settle before encoding and writing.
    /// Mirrors the debounce pattern in ContentView.scheduleLivePortRefresh().
    private func scheduleWrite() {
        writeTask?.cancel()
        writeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }

            let snapshot = buildSnapshot()

            // Skip the write if the port data hasn't changed. Compare
            // ports only, not the timestamp, otherwise every snapshot
            // looks different and the dedup is useless.
            if snapshot.ports == lastSnapshot?.ports && snapshot.powerState == lastSnapshot?.powerState { return }

            // Only update lastSnapshot after a confirmed write. If the
            // write fails (missing container, encoding error), we want
            // the next change to retry rather than silently deduping.
            guard writeToDefaults(snapshot) else { return }
            lastSnapshot = snapshot

            // Tell WidgetKit to reload. This is a no-op when no widgets
            // are installed, so it's safe to call unconditionally.
            WidgetCenter.shared.reloadAllTimelines()

            Self.log.debug("Widget timelines reloaded after snapshot write")
        }
    }

    /// Unconditional write with a fresh timestamp. Called by the heartbeat
    /// timer to keep the snapshot from going stale during idle periods.
    private func forceWrite() {
        let snapshot = buildSnapshot()
        guard writeToDefaults(snapshot) else { return }
        lastSnapshot = snapshot
        WidgetCenter.shared.reloadAllTimelines()
        Self.log.debug("Widget heartbeat: refreshed timestamp and reloaded timelines (\(snapshot.ports.count) ports)")
    }


    private func buildSnapshot() -> WidgetSnapshot {
        let batteryResult = AppleSmartBatteryReader.read()
        let batteryFull = batteryResult.battery?.fullyCharged
        let adapter = SystemPower.currentAdapter()
        let activePortCount = portWatcher.ports.filter { $0.connectionActive == true }.count

        let entries: [WidgetSnapshot.PortEntry] = portWatcher.ports.map { port in
            let devices = port.matchingDevices(from: deviceWatcher.devices)
            let sources = powerWatcher.sources(for: port)
            let identities = pdWatcher.identities(for: port)

            let isLive = WhatCableCore.isPortLive(
                port: port,
                powerSources: sources,
                identities: identities,
                matchingDevices: devices
            )

            let summary = PortSummary(
                port: port,
                sources: sources,
                identities: identities,
                devices: devices,
                thunderboltSwitches: tbWatcher.switches,
                usb3Transports: usb3Watcher.transports(for: port),
                cioCapability: trmWatcher.cioCapabilities.first { $0.portKey == port.portKey },
                isConnectedOverride: isLive,
                batteryFullyCharged: batteryFull
            )

            let status = WidgetSnapshot.Status(from: summary.status)

            let wattageSource = ChargerWattageSource.resolve(
                portSources: sources,
                activePortCount: activePortCount,
                adapter: adapter
            )

            var recentPower: [Double] = []
            if let key = port.portKey {
                for contributor in PluginRegistry.shared.widgetDataContributors {
                    if let samples = contributor.recentPower(forPortKey: key), !samples.isEmpty {
                        recentPower = samples
                        break
                    }
                }
            }

            return WidgetSnapshot.PortEntry(
                id: port.id,
                portName: port.portDescription ?? port.serviceName,
                status: status,
                headline: summary.headline,
                subtitle: summary.subtitle,
                topBullet: summary.bullets.first,
                iconName: status.iconName,
                deviceCount: devices.count,
                recentPower: recentPower,
                portKey: port.portKey,
                chargerWatts: wattageSource.watts
            )
        }

        // Gather Pro power data from contributors (nil for free-tier users).
        var systemPowerInWatts: Double?
        var recentSystemPower: [Double] = []
        var perPortWatts: [WidgetSnapshot.PortPowerEntry]?
        for contributor in PluginRegistry.shared.widgetDataContributors {
            if let sys = contributor.latestSystemPower() {
                systemPowerInWatts = sys.current
                recentSystemPower = sys.history
            }
            // Build per-port power entries from the contributor's port data.
            let portEntries: [WidgetSnapshot.PortPowerEntry] = entries.compactMap { entry in
                guard let key = entry.portKey,
                      let samples = contributor.recentPower(forPortKey: key),
                      let latest = samples.last, latest > 0 else { return nil }
                return WidgetSnapshot.PortPowerEntry(
                    portKey: key,
                    portName: entry.portName,
                    watts: latest,
                    recentSamples: samples
                )
            }
            if !portEntries.isEmpty { perPortWatts = portEntries }
        }

        let batteryPercent: Int? = {
            guard let bat = batteryResult.battery, bat.maxCapacity > 0 else { return nil }
            let raw = Int((Double(bat.currentCapacity) / Double(bat.maxCapacity) * 100).rounded())
            return min(100, max(0, raw))
        }()

        let powerState = WidgetSnapshot.PowerState(
            batteryPercent: batteryPercent,
            isCharging: batteryResult.battery?.isCharging ?? false,
            fullyCharged: batteryResult.battery?.fullyCharged ?? false,
            isDesktopMac: batteryResult.isDesktopMac,
            adapterWatts: adapter?.watts,
            adapterDescription: adapter?.adapterDescription,
            systemPowerInWatts: systemPowerInWatts,
            perPortWatts: perPortWatts,
            recentSystemPower: recentSystemPower
        )

        return WidgetSnapshot(ports: entries, powerState: powerState)
    }

    @discardableResult
    private func writeToDefaults(_ snapshot: WidgetSnapshot) -> Bool {
        guard let url = WidgetSnapshot.sharedFileURL else {
            Self.log.error("Failed to resolve App Group container URL")
            return false
        }

        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
            Self.log.debug("Widget snapshot written to \(url.path, privacy: .public): \(snapshot.ports.count, privacy: .public) ports, \(data.count, privacy: .public) bytes")
            return true
        } catch {
            Self.log.error("Failed to write widget snapshot at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
