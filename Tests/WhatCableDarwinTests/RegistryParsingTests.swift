import Foundation
import Testing
@testable import WhatCableCore
@testable import WhatCableDarwinBackend

@Suite("Registry parsing")
struct RegistryParsingTests {
    @Test("AppleHPMInterfaceWatcher scans M4 Mini front port class")
    func appleHPMInterfaceWatcherScansM4MiniFrontPortClass() {
        #expect(AppleHPMInterfaceWatcher.candidateClasses.contains("IOPort"))
    }

    @Test("AppleHPMInterfaceWatcher extracts busIndex across controller name shapes")
    func appleHPMInterfaceWatcherExtractsBusIndexAcrossControllerNameShapes() {
        #expect(AppleHPMInterfaceWatcher.busIndex(fromRegistryName: "hpm4@3") == 4)
        #expect(AppleHPMInterfaceWatcher.busIndex(fromRegistryName: "atc1") == 1)
        #expect(AppleHPMInterfaceWatcher.busIndex(fromRegistryName: "usb-drd2@2280000") == 2)
        #expect(AppleHPMInterfaceWatcher.busIndex(fromRegistryName: "hpm@3") == nil)
        #expect(AppleHPMInterfaceWatcher.busIndex(fromRegistryName: "AppleT6000USBXHCI") == nil)
    }

    @Test("AppleHPMInterfaceWatcher extracts location fallback as hex")
    func appleHPMInterfaceWatcherExtractsLocationFallbackAsHex() {
        #expect(AppleHPMInterfaceWatcher.busIndex(fromLocation: "1") == 1)
        #expect(AppleHPMInterfaceWatcher.busIndex(fromLocation: "0A") == 10)
        #expect(AppleHPMInterfaceWatcher.busIndex(fromLocation: "") == nil)
        #expect(AppleHPMInterfaceWatcher.busIndex(fromLocation: "Port-USB-C") == nil)
    }

    @Test("USBWatcher parses usbIOPort string and Data")
    func usbWatcherParsesUsbIOPortStringAndData() {
        let path = "AppleARMIO/Port-USB-C@1"
        #expect(USBWatcher.usbIOPortPath(from: path) == path)

        let data = Data("AppleARMIO/Port-USB-C@2\u{0}".utf8)
        #expect(USBWatcher.usbIOPortPath(from: data) == "AppleARMIO/Port-USB-C@2")
    }

    @Test("USBWatcher extracts port name and bus index")
    func usbWatcherExtractsPortNameAndBusIndex() {
        #expect(
            USBWatcher.portName(fromUSBIOPortPath: "AppleARMIO/Port-USB-C@1") ==
            "Port-USB-C@1"
        )
        #expect(USBWatcher.portName(fromUSBIOPortPath: "AppleARMIO/AppleUSBHostPort@1") == nil)
        #expect(USBWatcher.busIndex(fromLocationID: 0x0300_0000) == 3)
    }

    @Test("PowerSourceWatcher handles built-in parent fields and priority fallback")
    func powerSourceWatcherHandlesBuiltInParentFieldsAndPriorityFallback() {
        let builtIn: [String: Any] = [
            "ParentBuiltInPortType": NSNumber(value: 0x11),
            "ParentBuiltInPortNumber": NSNumber(value: 2),
            "ParentPortType": NSNumber(value: 2),
            "ParentPortNumber": NSNumber(value: 1)
        ]
        let builtInParent = PowerSourceWatcher.parentPortIdentity(from: builtIn)
        #expect(builtInParent.type == 0x11)
        #expect(builtInParent.number == 2)

        let priority: [String: Any] = [
            "ParentPortType": NSNumber(value: 0x11),
            "Priority": NSNumber(value: 0x0201)
        ]
        let priorityParent = PowerSourceWatcher.parentPortIdentity(from: priority)
        #expect(priorityParent.type == 0x11)
        #expect(priorityParent.number == 1)
    }

    @Test("USBPDSOP watcher handles MagSafe CC and SOP1 metadata")
    func usbPDSOPWatcherHandlesMagSafeCCAndSOP1Metadata() {
        let dict: [String: Any] = [
            "TransportTypeDescription": "CC",
            "ParentBuiltInPortType": NSNumber(value: 0x11),
            "ParentBuiltInPortNumber": NSNumber(value: 1),
            "Metadata": [
                "Vendor ID (SOP1)": NSNumber(value: 0x05AC),
                "Product ID (SOP1)": NSNumber(value: 0x1234),
                "bcdDevice": NSNumber(value: 0x0100)
            ]
        ]
        let metadata = USBPDSOPWatcher.metadataDictionary(from: dict)
        let parent = USBPDSOPWatcher.parentPortIdentity(from: dict)

        #expect(USBPDSOPWatcher.endpoint(from: dict) == .sopPrime)
        #expect(parent.type == 0x11)
        #expect(parent.number == 1)
        #expect(USBPDSOPWatcher.vendorID(from: dict, metadata: metadata) == 0x05AC)
        #expect(USBPDSOPWatcher.productID(from: dict, metadata: metadata) == 0x1234)
        #expect(USBPDSOPWatcher.bcdDevice(from: metadata) == 0x0100)
    }
}
