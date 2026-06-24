import Foundation
import IOKit
import IOKit.usb
import os
import WhatCableCore

@MainActor
public final class USBWatcher: ObservableObject {
    @Published public private(set) var devices: [USBDevice] = []

    private static let log = Logger(subsystem: "uk.whatcable.whatcable", category: "usb")

    private var notifyPort: IONotificationPortRef?
    private var addedIter: io_iterator_t = 0
    private var removedIter: io_iterator_t = 0

    public init() {}

    public func start() {
        guard notifyPort == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let addedCallback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<USBWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak watcher] in watcher?.handleAdded(iterator: iterator) }
        }

        let removedCallback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<USBWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak watcher] in watcher?.handleRemoved(iterator: iterator) }
        }

        // IOServiceAddMatchingNotification consumes one reference to the matching
        // dictionary, so call IOServiceMatching fresh for each registration.
        // Only drain the iterator when registration succeeds; the out-parameter
        // iterator is only valid on KERN_SUCCESS, and passing an uninitialised
        // value to IOIteratorNext is undefined behaviour.
        if IOServiceAddMatchingNotification(
            port,
            kIOMatchedNotification,
            IOServiceMatching("IOUSBHostDevice"),
            addedCallback,
            selfPtr,
            &addedIter
        ) == KERN_SUCCESS {
            handleAdded(iterator: addedIter)
        }

        if IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching("IOUSBHostDevice"),
            removedCallback,
            selfPtr,
            &removedIter
        ) == KERN_SUCCESS {
            handleRemoved(iterator: removedIter)
        }
    }

    public func stop() {
        if addedIter != 0 { IOObjectRelease(addedIter); addedIter = 0 }
        if removedIter != 0 { IOObjectRelease(removedIter); removedIter = 0 }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        devices.removeAll()
    }

    private func handleAdded(iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            if let device = makeDevice(from: service) {
                if !devices.contains(where: { $0.id == device.id }) {
                    devices.append(device)
                }
            }
            IOObjectRelease(service)
        }
        devices.sort { ($0.productName ?? "") < ($1.productName ?? "") }
    }

    private func handleRemoved(iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS {
                devices.removeAll { $0.id == entryID }
            }
            IOObjectRelease(service)
        }
    }

    private func makeDevice(from service: io_service_t) -> USBDevice? {
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return nil }

        // USBWatcher uses the bulk fetch intentionally: it iterates all keys
        // from the returned dictionary to populate `rawProperties` on USBDevice.
        // There is no fixed key list, so per-key reads are not feasible here.
        // USB device services are stable (not torn-down mid-read), so the
        // IOCFUnserializeBinary crash path described in issue #181 does not
        // apply. See also: AppleHPMInterfaceWatcher.makePort for the contrast.
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        let vendorID = (dict["idVendor"] as? NSNumber)?.uint16Value ?? 0
        let productID = (dict["idProduct"] as? NSNumber)?.uint16Value ?? 0
        let locationID = (dict["locationID"] as? NSNumber)?.uint32Value ?? 0
        let speedRaw = (dict["Device Speed"] as? NSNumber)?.uint8Value
        let bcdUSB = (dict["bcdUSB"] as? NSNumber)?.uint16Value
        let busPower = (dict["Bus Power Available"] as? NSNumber).map { $0.intValue * 2 }
        let current = (dict["Requested Power"] as? NSNumber).map { $0.intValue * 2 }
        let deviceClass = (dict["bDeviceClass"] as? NSNumber)?.uint8Value

        // The leaf IOKit class. A Billboard device enumerates as
        // "AppleUSBHostBillboardDevice" (a subclass of IOUSBHostDevice, so the
        // matcher above still catches it). Used as a detection signal that
        // doesn't depend on the product-name string.
        // Only trust the buffer when the call succeeds; on failure IOKit does
        // not guarantee it leaves the buffer untouched, and USBDevice's
        // contract is that ioClassName is nil when unavailable.
        var classBuf = [CChar](repeating: 0, count: 128)
        let ioClassName = IOObjectGetClass(service, &classBuf) == KERN_SUCCESS
            ? String(cString: classBuf)
            : nil

        var raw: [String: String] = [:]
        for (k, v) in dict {
            raw[k] = stringify(v)
        }

        let (busIdx, portName, tunnelled, behindInternalHub) = controllerInfo(for: service, fallback: locationID)

        // Read the Billboard Capability Descriptor (advertised Alt Modes and
        // their per-mode state) once, here at device-appearance. One-shot
        // control transfer, no device-open. See DAR-141.
        //
        // We probe every device deliberately, NOT just Billboard-class ones.
        // Functional docks, hubs and AV adapters advertise a Billboard
        // capability inside their ordinary BOS (seen on 103 such devices across
        // 71 machines in the customer-probe corpus), and the Pro Cable
        // Diagnostics screen surfaces those alt modes; gating to Billboard-class
        // devices would blank that table for them. The freeze in issue #370
        // came purely from a force-open fallback that no longer exists; the
        // no-open read here is harmless on a device a kernel driver holds.
        let billboard = BillboardDescriptorReader.read(from: service)

        return USBDevice(
            id: entryID,
            locationID: locationID,
            vendorID: vendorID,
            productID: productID,
            vendorName: dict["USB Vendor Name"] as? String,
            productName: dict["USB Product Name"] as? String,
            serialNumber: dict["USB Serial Number"] as? String,
            usbVersion: bcdUSB.map { formatBCD($0) },
            speedRaw: speedRaw,
            busPowerMA: busPower,
            currentMA: current,
            busIndex: busIdx,
            controllerPortName: portName,
            isThunderboltTunnelled: tunnelled,
            isBehindInternalHub: behindInternalHub,
            deviceClass: deviceClass,
            ioClassName: ioClassName,
            billboard: billboard,
            rawProperties: raw
        )
    }

    /// Walks the IOKit parent chain from a USB device collecting these pieces
    /// of information:
    ///   - `controllerPortName`: parsed from the first ancestor with a
    ///     `UsbIOPort` property. These are the `usb-drd*-port-hs/ss` nodes
    ///     that sit between the device and the `AppleT*USBXHCI` controller.
    ///     Their `UsbIOPort` value is a registry path ending in the physical
    ///     port's service name (e.g. ".../Port-USB-C@1").
    ///   - `busIndex`: upper byte of the XHCI controller's `locationID`,
    ///     kept as a fallback for older topologies that don't expose
    ///     `UsbIOPort` (and for the advanced view).
    ///   - `tunnelled`: the chain runs through `AppleUSBXHCITR`, i.e. the
    ///     device reached the Mac over a Thunderbolt PCIe tunnel (issue #274).
    ///   - `behindInternalHub`: the device is on a desktop Mac's plain-USB
    ///     front port. Detected structurally: the walk reaches a native
    ///     controller, is not tunnelled, and finds no `UsbIOPort` ancestor
    ///     (no `Port-USB-C@N` match). See the gate below the loop (issue #348).
    ///
    /// Walks up to 20 hops to handle devices behind deeper hub chains.
    private func controllerInfo(for service: io_service_t, fallback locationID: UInt32) -> (Int?, String?, Bool, Bool) {
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        var portName: String?
        var bus: Int?
        var tunnelled = false
        // Set when the walk lands on a *native* Apple Silicon USB host
        // controller (`AppleT*USBXHCI`), as opposed to the tunnelled
        // `AppleUSBXHCITR`. Used below to gate the internal-hub classification.
        var reachedNativeController = false

        // Bound the walk so a malformed or cyclic registry can't loop forever.
        // The real depth from a USB device to its host controller is small (2-4
        // hops directly attached; a few more behind chained hubs), so 20 is far
        // beyond anything observed and just acts as a backstop. Hitting it means
        // the controller was never found, so `portName` / `reachedNativeController`
        // stay unset and the device fails safe (not classified as front-port).
        for _ in 0..<20 {
            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                break
            }
            IOObjectRelease(current)
            current = parent

            if portName == nil,
               let raw = IORegistryEntryCreateCFProperty(
                    current,
                    "UsbIOPort" as CFString,
                    kCFAllocatorDefault,
                    0
               )?.takeRetainedValue(),
               let portPath = Self.usbIOPortPath(from: raw) {
                if let name = Self.portName(fromUSBIOPortPath: portPath) {
                    portName = name
                } else {
                    // Found a `UsbIOPort` ancestor, but its path tail isn't a
                    // recognised `Port-*` node. Without a port name the device
                    // is later treated as port-less and, on a desktop, surfaced
                    // as a front-port device (issue #348). If a future Apple
                    // Silicon generation renames the port node, this is the
                    // silent failure mode; log it so it's diagnosable. The path
                    // is IOKit topology, not PII.
                    Self.log.debug("UsbIOPort path has no recognised port node: \(portPath, privacy: .public)")
                }
            }

            var classBuf = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(current, &classBuf)
            let className = String(cString: classBuf)
            // The tunnelled host controller for devices behind a Thunderbolt
            // dock or display (issue #274). It plays the same role as the native
            // XHCI controller below, but reached over the TB PCIe tunnel, so we
            // flag the device and stop the walk at it. There is no `UsbIOPort`
            // on this path, so `portName` stays nil and the device matches no
            // physical port.
            if className.hasPrefix("AppleUSBXHCITR") {
                tunnelled = true
                if let loc = (IORegistryEntryCreateCFProperty(current, "locationID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.uint32Value {
                    bus = Int((loc >> 24) & 0xFF)
                }
                break
            }
            if className.hasPrefix("AppleT") && className.hasSuffix("USBXHCI") {
                reachedNativeController = true
                if let loc = (IORegistryEntryCreateCFProperty(current, "locationID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.uint32Value {
                    bus = Int((loc >> 24) & 0xFF)
                }
                break
            }
        }

        let behindInternalHub = Self.classifyBehindInternalHub(
            reachedNativeController: reachedNativeController,
            tunnelled: tunnelled,
            portName: portName
        )

        if bus == nil {
            // Fallback: the device's own locationID upper byte mirrors its
            // controller's locationID upper byte on Apple Silicon.
            bus = Int((locationID >> 24) & 0xFF)
        }
        return (bus, portName, tunnelled, behindInternalHub)
    }

    /// Structural front-port classification (issue #348). True when all three
    /// hold:
    ///   1. `reachedNativeController` -- the parent walk reached a native USB
    ///      host controller (`AppleT*USBXHCI`), not the Thunderbolt tunnel.
    ///   2. `!tunnelled` -- the walk did NOT go through `AppleUSBXHCITR`.
    ///   3. `portName == nil` -- no `UsbIOPort` ancestor, i.e. no `Port-USB-C@N`
    ///      match.
    /// On a desktop Mac that means a plain-USB front-panel port. Back-port
    /// devices always have a `usb-drd*-port-*` (`UsbIOPort`) ancestor, so they
    /// fail (3). TB-tunnelled devices fail (1)/(2). An external hub on a laptop
    /// hangs off a real port, so it also has a `UsbIOPort` ancestor and fails
    /// (3). This structural gate replaces the earlier PID allow-list, which the
    /// customer-probe corpus showed was both too narrow (missed M1/M2/Studio
    /// internal-hub PIDs) and ambiguous (the same PIDs appear on external Apple
    /// hubs).
    ///
    /// This is pure structure, not a desktop guarantee: the desktop-only product
    /// policy is applied downstream in `TunnelledDeviceGrouping.group`. Pure so
    /// it is unit-testable without IOKit.
    nonisolated static func classifyBehindInternalHub(
        reachedNativeController: Bool,
        tunnelled: Bool,
        portName: String?
    ) -> Bool {
        reachedNativeController && !tunnelled && portName == nil
    }

    nonisolated static func busIndex(fromLocationID locationID: UInt32) -> Int {
        Int((locationID >> 24) & 0xFF)
    }

    nonisolated static func usbIOPortPath(from value: Any) -> String? {
        if let string = value as? String {
            return string
        }
        if let data = value as? Data {
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters)
        }
        return nil
    }

    nonisolated static func portName(fromUSBIOPortPath path: String) -> String? {
        guard let last = path.split(separator: "/").last else { return nil }
        let name = String(last)
        return name.hasPrefix("Port-") ? name : nil
    }

    private func formatBCD(_ value: UInt16) -> String {
        let major = (value >> 8) & 0xFF
        let minor = (value >> 4) & 0xF
        let sub = value & 0xF
        return sub == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(sub)"
    }

    private func stringify(_ value: Any) -> String {
        switch value {
        case let n as NSNumber: return n.stringValue
        case let s as String: return s
        case let d as Data: return d.map { String(format: "%02X", $0) }.joined(separator: " ")
        case let a as [Any]: return "[\(a.map { stringify($0) }.joined(separator: ", "))]"
        default: return String(describing: value)
        }
    }
}

