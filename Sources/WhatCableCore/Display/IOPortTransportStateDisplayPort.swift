import Foundation

public struct DisplayPortLink: Codable, Sendable, Equatable {
    public let active: Bool
    public let laneCount: Int
    public let maxLaneCount: Int
    public let linkRate: Int
    public let linkRateDescription: String?
    public let tunneled: Bool
    public let hpdState: Int
    public let hpdStateDescription: String?

    public init(
        active: Bool,
        laneCount: Int,
        maxLaneCount: Int,
        linkRate: Int,
        linkRateDescription: String? = nil,
        tunneled: Bool,
        hpdState: Int,
        hpdStateDescription: String? = nil
    ) {
        self.active = active
        self.laneCount = laneCount
        self.maxLaneCount = maxLaneCount
        self.linkRate = linkRate
        self.linkRateDescription = linkRateDescription
        self.tunneled = tunneled
        self.hpdState = hpdState
        self.hpdStateDescription = hpdStateDescription
    }
}

public struct MonitorInfo: Codable, Sendable, Equatable {
    public let manufacturerName: String?
    public let productName: String?
    public let productId: Int?
    public let serialNumber: Int?
    public let yearOfManufacture: Int?
    public let weekOfManufacture: Int?
    public let edid: Data?

    public init(
        manufacturerName: String?,
        productName: String?,
        productId: Int?,
        serialNumber: Int? = nil,
        yearOfManufacture: Int?,
        weekOfManufacture: Int? = nil,
        edid: Data?
    ) {
        self.manufacturerName = manufacturerName
        self.productName = productName
        self.productId = productId
        self.serialNumber = serialNumber
        self.yearOfManufacture = yearOfManufacture
        self.weekOfManufacture = weekOfManufacture
        self.edid = edid
    }
}

public struct IOPortTransportStateDisplayPort: Codable, Sendable, Equatable {
    public let link: DisplayPortLink
    public let monitor: MonitorInfo?
    public let dfpType: String?
    public let branchDeviceId: String?
    public let branchDeviceOUI: Data?
    public let sinkCount: Int
    public let role: Int
    public let roleDescription: String?
    public let driverStatus: Int
    public let driverStatusDescription: String?
    public let transportType: Int
    public let transportTypeDescription: String?
    public let transportDescription: String?
    public let authorizationRequired: Bool
    public let authorizationStatus: Int
    public let authorizationStatusDescription: String?
    public let authenticationRequired: Bool
    public let authenticationStatus: Int
    public let authenticationStatusDescription: String?
    public let hashStatus: Int
    public let hashStatusDescription: String?
    public let trmTransportSupervised: Bool
    public let parentPortType: Int
    public let parentPortTypeDescription: String?
    public let parentPortNumber: Int
    public let parentPortBuiltIn: Bool
    public let parentBuiltInPortType: Int
    public let parentBuiltInPortTypeDescription: String?
    public let parentBuiltInPortNumber: Int
    public let edidChanged: Bool
    public let nominalSignalingFrequenciesHz: [Int]
    public let index: Int
    /// The live on-screen mode from CoreGraphics, attached by the Darwin
    /// backend when it can match this node to exactly one display. nil on the
    /// Windows backend, in tests, and whenever the match is missing or
    /// ambiguous, so every consumer treats its absence as "no extra data".
    public let currentMode: DisplayCurrentMode?
    /// The display's native top mode as macOS reports it (from
    /// `CGDisplayCopyAllDisplayModes`): highest resolution, at its best refresh.
    /// The authoritative top mode that does not depend on parsing the EDID, so
    /// it is correct even for 5K/6K displays whose EDID can't describe their
    /// native mode. Same nil contract as `currentMode`.
    public let maxMode: DisplayCurrentMode?

    public init(
        link: DisplayPortLink,
        monitor: MonitorInfo?,
        dfpType: String? = nil,
        branchDeviceId: String? = nil,
        branchDeviceOUI: Data? = nil,
        sinkCount: Int = 0,
        role: Int = 0,
        roleDescription: String? = nil,
        driverStatus: Int = 0,
        driverStatusDescription: String? = nil,
        transportType: Int = 0,
        transportTypeDescription: String? = nil,
        transportDescription: String? = nil,
        authorizationRequired: Bool = false,
        authorizationStatus: Int = 0,
        authorizationStatusDescription: String? = nil,
        authenticationRequired: Bool = false,
        authenticationStatus: Int = 0,
        authenticationStatusDescription: String? = nil,
        hashStatus: Int = 0,
        hashStatusDescription: String? = nil,
        trmTransportSupervised: Bool = false,
        parentPortType: Int = 0,
        parentPortTypeDescription: String? = nil,
        parentPortNumber: Int = 0,
        parentPortBuiltIn: Bool = false,
        parentBuiltInPortType: Int = 0,
        parentBuiltInPortTypeDescription: String? = nil,
        parentBuiltInPortNumber: Int = 0,
        edidChanged: Bool = false,
        nominalSignalingFrequenciesHz: [Int] = [],
        index: Int = 0,
        currentMode: DisplayCurrentMode? = nil,
        maxMode: DisplayCurrentMode? = nil
    ) {
        self.link = link
        self.monitor = monitor
        self.dfpType = dfpType
        self.branchDeviceId = branchDeviceId
        self.branchDeviceOUI = branchDeviceOUI
        self.sinkCount = sinkCount
        self.role = role
        self.roleDescription = roleDescription
        self.driverStatus = driverStatus
        self.driverStatusDescription = driverStatusDescription
        self.transportType = transportType
        self.transportTypeDescription = transportTypeDescription
        self.transportDescription = transportDescription
        self.authorizationRequired = authorizationRequired
        self.authorizationStatus = authorizationStatus
        self.authorizationStatusDescription = authorizationStatusDescription
        self.authenticationRequired = authenticationRequired
        self.authenticationStatus = authenticationStatus
        self.authenticationStatusDescription = authenticationStatusDescription
        self.hashStatus = hashStatus
        self.hashStatusDescription = hashStatusDescription
        self.trmTransportSupervised = trmTransportSupervised
        self.parentPortType = parentPortType
        self.parentPortTypeDescription = parentPortTypeDescription
        self.parentPortNumber = parentPortNumber
        self.parentPortBuiltIn = parentPortBuiltIn
        self.parentBuiltInPortType = parentBuiltInPortType
        self.parentBuiltInPortTypeDescription = parentBuiltInPortTypeDescription
        self.parentBuiltInPortNumber = parentBuiltInPortNumber
        self.edidChanged = edidChanged
        self.nominalSignalingFrequenciesHz = nominalSignalingFrequenciesHz
        self.index = index
        self.currentMode = currentMode
        self.maxMode = maxMode
    }
}

extension IOPortTransportStateDisplayPort {
    /// Join key to the owning USB-C / MagSafe port. The DisplayPort node
    /// reports its parent as `ParentPortType` (2 = USB-C, 0x11 = MagSafe) and
    /// `ParentPortNumber`, the same scheme `PowerSource.portKey` and
    /// `AppleHPMInterface.portKey` use, so `"\(type)/\(number)"` matches a
    /// port directly. Confirmed against probe 17 (ParentPortType 2 /
    /// ParentPortNumber 4 for the active "Port-USB-C" display).
    public var portKey: String { "\(parentPortType)/\(parentPortNumber)" }
}

@available(*, deprecated, renamed: "IOPortTransportStateDisplayPort")
public typealias DisplayPortStatus = IOPortTransportStateDisplayPort
