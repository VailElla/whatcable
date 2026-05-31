import SwiftUI
import WhatCableCore

extension PortSummary {
    var icon: String {
        switch status {
        case .empty: return "powerplug"
        case .charging: return "bolt.fill"
        case .batteryFull: return "battery.100"
        case .dataDevice: return "cable.connector"
        case .thunderboltCable: return "bolt.horizontal.fill"
        case .displayCable: return "display"
        case .unknown: return "questionmark.circle"
        }
    }

    var iconColor: Color {
        switch status {
        case .empty: return .secondary
        case .charging: return .yellow
        case .batteryFull: return .green
        case .dataDevice: return .blue
        case .thunderboltCable: return .purple
        case .displayCable: return .teal
        case .unknown: return .orange
        }
    }
}

extension ChargingDiagnostic {
    var icon: String {
        switch bottleneck {
        case .noCharger: return "battery.0"
        case .chargerLimit: return "exclamationmark.triangle.fill"
        case .cableLimit: return "exclamationmark.triangle.fill"
        case .macLimit: return "questionmark.circle"
        case .fine: return "checkmark.seal.fill"
        }
    }
}

extension DataLinkDiagnostic {
    var icon: String {
        switch bottleneck {
        case .cableLimit: return "exclamationmark.triangle.fill"
        case .hostLimit: return "exclamationmark.triangle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .cableContradictsActive: return "exclamationmark.triangle.fill"
        case .deviceLimit: return "info.circle"
        case .unknownCable: return "questionmark.circle"
        case .fine: return "checkmark.seal.fill"
        }
    }
}

