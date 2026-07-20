import Foundation
import Testing

@Suite("Cable report sync script")
struct CableReportSyncTests {
    @Test("Raw Cable VDO speed derivation and fallbacks")
    func rawCableVDOSpeedDerivationAndFallbacks() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        process.currentDirectoryURL = repoRoot
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "scripts/sync-cable-reports.swift", "--test-speed"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errors = String(data: errorData, encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, Comment(rawValue: errors))
        #expect(output.contains("Cable report speed self-tests passed"))
    }
}
