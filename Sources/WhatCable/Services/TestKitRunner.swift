import CryptoKit
import Foundation
import os.log
import WhatCableCore

@MainActor
final class TestKitRunner: ObservableObject {
    static let shared = TestKitRunner()

    private nonisolated static let log = Logger(subsystem: "uk.whatcable.whatcable", category: "test-kit")
    private static let apiURL = "https://whatcable-test-kit.darrylmorley-uk.workers.dev"

    enum State: Equatable {
        case idle
        case running(probe: String, current: Int, total: Int)
        // `noOutputProbes` carries names (no output content) for an optional
        // subtle tooltip in the settings UI; `noOutput` is the count for the
        // completion label. See `runAllProbes()` for how a probe lands here
        // vs in `passed`/`failed`.
        case done(passed: Int, failed: Int, noOutput: Int, noOutputProbes: [String])
        case error(String)
    }

    @Published private(set) var state: State = .idle

    static let probeNames: [String] = [
        "01_walk_pd_tree",
        "03_hpm_deep_dive",
        "04_raw_registry_dump",
        "17_deep_property_dump",
        "19_pdo_decode_and_usb3_watch",
        "21_tb_cfplugin_retimer",
        "25_usb_bos_descriptor",
        "26_displayport_altmode",
        "27_iopower_management",
        "29_usb4_router_interfaces",
        "31_typec_phy_properties",
        "32_smart_battery_full_keys",
        "33_displayport_capability",
        "34_smc_power_keys",
        "35_hpm_port_uuid",
        "36_xhci_port_map",
        "37_tb_tunnel_port_map",
        "38_usb_device_tree",
    ]

    private var runTask: Task<Void, Never>?

    private init() {}

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func run() {
        guard !isRunning else { return }

        runTask = Task {
            await runAllProbes()
            runTask = nil
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        if isRunning {
            state = .idle
        }
    }

    private func runAllProbes() async {
        let machineID = await Task.detached { Self.machineID() }.value
        let ver = ProcessInfo.processInfo.operatingSystemVersion
        let macosVersion = ver.patchVersion > 0
            ? "\(ver.majorVersion).\(ver.minorVersion).\(ver.patchVersion)"
            : "\(ver.majorVersion).\(ver.minorVersion)"
        let chip = Self.chipName()
        let timestamp = ISO8601DateFormatter().string(from: Date())

        guard let probesDir = Self.probesDirectory() else {
            state = .error("Probe binaries not found in app bundle")
            Self.log.error("Probe binaries directory not found")
            return
        }

        let total = Self.probeNames.count
        var passed = 0
        var failed = 0
        var noOutputProbes: [String] = []

        for (index, probeName) in Self.probeNames.enumerated() {
            guard !Task.isCancelled else {
                state = .idle
                return
            }

            state = .running(probe: probeName, current: index + 1, total: total)

            let binaryURL = probesDir.appendingPathComponent(probeName)
            guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
                Self.log.warning("Probe binary not found: \(probeName)")
                noOutputProbes.append(probeName)
                continue
            }

            let result = await runProbe(at: binaryURL)

            // Accounting decision (audit finding: crashes/empty-output/missing
            // binaries were silently uncounted). A probe lands in the new
            // no-output bucket, and its output (if any) is discarded, unless
            // it either exited cleanly (status 0, no signal) or was killed by
            // our own 30s watchdog below (`result.didTimeout`, an explicit
            // flag, not inferred from the exit signal, since an external
            // SIGTERM would look identical to our own). The watchdog case is
            // deliberately still treated as good data: when a probe is killed
            // for running long we'd still rather submit whatever it had
            // already written than throw it away, so it counts as
            // passed/failed same as a clean run, and only a log line notes
            // the timeout (not the no-output array, since it did produce
            // something and did get submitted). Any other nonzero exit or
            // signal (a genuine crash) is NOT trusted even if the pipe
            // carries partial bytes, since an unsupervised crash's output
            // isn't known to be well-formed; it goes to noOutputProbes and
            // nothing is submitted for it.
            let cleanExit = result.terminationReason == .exit && result.exitStatus == 0
            guard let output = result.output, !output.isEmpty, cleanExit || result.didTimeout else {
                Self.log.warning("Probe \(probeName) produced no usable output (exit \(result.exitStatus), reason \(String(describing: result.terminationReason)))")
                noOutputProbes.append(probeName)
                continue
            }

            if result.didTimeout {
                Self.log.info("Probe \(probeName) hit the 30s watchdog but produced output; submitting partial data")
            }

            let ok = await submitProbeResult(
                machineID: machineID,
                probeName: probeName,
                output: output,
                macosVersion: macosVersion,
                chip: chip,
                timestamp: timestamp
            )

            if ok {
                passed += 1
            } else {
                failed += 1
            }
        }

        await submitComplete(
            machineID: machineID,
            macosVersion: macosVersion,
            chip: chip,
            passed: passed,
            failed: failed,
            total: total,
            noOutputProbes: noOutputProbes
        )

        state = .done(passed: passed, failed: failed, noOutput: noOutputProbes.count, noOutputProbes: noOutputProbes)
        Self.log.info("Test kit complete: \(passed) passed, \(failed) failed, \(noOutputProbes.count) no output\(noOutputProbes.isEmpty ? "" : ": \(noOutputProbes.joined(separator: ", "))")")

        AppSettings.shared.testKitLastRunVersion = AppInfo.version
    }

    /// Everything `runProbe` learns about how the probe process ended, so the
    /// caller can distinguish "ran cleanly", "we killed it on the 30s
    /// watchdog", and "it crashed/exited nonzero on its own" instead of just
    /// getting an output string. `didTimeout` is the source of truth for the
    /// watchdog case: `Process.terminate()` sends SIGTERM, but an external
    /// SIGTERM (someone else killing the probe) produces the exact same
    /// `terminationReason`/`terminationStatus` pair, so that pair alone can't
    /// distinguish "our watchdog" from "somebody else's kill" (raw signal 15
    /// is still worth knowing as a sanity check when reading logs, but it is
    /// not what this code branches on).
    private struct ProbeRunResult {
        let output: String?
        let exitStatus: Int32
        let terminationReason: Process.TerminationReason
        let didTimeout: Bool
    }

    /// Cross-queue flag: the timer fires on its own queue (`.global()`) and
    /// sets this *before* calling `process.terminate()`; the probe-running
    /// queue reads it after `process.waitUntilExit()` returns. A plain `var`
    /// captured by both closures would be a data race, so this uses the same
    /// NSLock-guarded-box pattern already used elsewhere in the app (e.g.
    /// `DashboardApp.swift`'s state boxes) rather than inferring the answer
    /// from the exit signal.
    private final class TimeoutMarker: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false

        func markFired() {
            lock.lock()
            fired = true
            lock.unlock()
        }

        var didFire: Bool {
            lock.lock()
            defer { lock.unlock() }
            return fired
        }
    }

    private func runProbe(at binaryURL: URL) async -> ProbeRunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = binaryURL
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                } catch {
                    Self.log.error("Failed to launch probe: \(error.localizedDescription)")
                    continuation.resume(returning: ProbeRunResult(output: nil, exitStatus: -1, terminationReason: .exit, didTimeout: false))
                    return
                }

                let timeoutMarker = TimeoutMarker()

                // Timer is created only after process.run() succeeds, so the
                // catch path above cannot leak a live timer source.
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + 30)
                timer.setEventHandler {
                    if process.isRunning {
                        // Set before terminate() so a read after
                        // waitUntilExit() always observes it once this
                        // handler has run at all.
                        timeoutMarker.markFired()
                        process.terminate()
                    }
                }
                timer.resume()
                defer { timer.cancel() }

                // Drain the pipe while the probe runs; reading after waitUntilExit
                // deadlocks once output exceeds the 64KB pipe buffer (the child
                // blocks on write() and nothing is draining the other end).
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8)
                continuation.resume(returning: ProbeRunResult(
                    output: output,
                    exitStatus: process.terminationStatus,
                    terminationReason: process.terminationReason,
                    didTimeout: timeoutMarker.didFire
                ))
            }
        }
    }

    private func submitProbeResult(
        machineID: String,
        probeName: String,
        output: String,
        macosVersion: String,
        chip: String,
        timestamp: String
    ) async -> Bool {
        let payload: [String: Any] = [
            "machine_id": machineID,
            "probe_name": probeName,
            "output": output,
            "macos_version": macosVersion,
            "chip": chip,
            "timestamp": timestamp,
        ]

        return await postJSON(to: "\(Self.apiURL)/submit", payload: payload)
    }

    private func submitComplete(
        machineID: String,
        macosVersion: String,
        chip: String,
        passed: Int,
        failed: Int,
        total: Int,
        noOutputProbes: [String]
    ) async {
        var payload: [String: Any] = [
            "machine_id": machineID,
            "macos_version": macosVersion,
            "chip": chip,
            "passed": passed,
            "failed": failed,
            "total": total,
            "no_output": noOutputProbes.count,
        ]
        if !noOutputProbes.isEmpty {
            payload["no_output_probes"] = noOutputProbes
        }

        _ = await postJSON(to: "\(Self.apiURL)/complete", payload: payload)
    }

    private func postJSON(to urlString: String, payload: [String: Any]) async -> Bool {
        guard let url = URL(string: urlString) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status == 200
        } catch {
            Self.log.error("POST to \(urlString) failed: \(error.localizedDescription)")
            return false
        }
    }

    static func probesDirectory() -> URL? {
        let fm = FileManager.default

        if let bundlePath = Bundle.main.resourceURL?.appendingPathComponent("probes"),
           fm.fileExists(atPath: bundlePath.path) {
            return bundlePath
        }

        let execURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .resolvingSymlinksInPath()
        let contentsDir = execURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fallback = contentsDir.appendingPathComponent("Resources/probes")
        if fm.fileExists(atPath: fallback.path) {
            return fallback
        }

        return nil
    }

    nonisolated static func machineID() -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-d2", "-c", "IOPlatformExpertDevice"]
        process.standardOutput = pipe
        try? process.run()
        // Drain the pipe while the probe runs; reading after waitUntilExit
        // deadlocks once output exceeds the 64KB pipe buffer. ioreg output is
        // small so this never triggered here, but keep the ordering consistent.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""

        var uuid = "unknown"
        for line in output.components(separatedBy: "\n") {
            if line.contains("IOPlatformUUID") {
                let parts = line.components(separatedBy: "\"")
                if parts.count >= 4 {
                    uuid = parts[3]
                }
                break
            }
        }

        let digest = SHA256.hash(data: Data(uuid.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func chipName() -> String {
        var size: size_t = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var result = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &result, &size, nil, 0)
        return String(cString: result)
    }
}
