import Foundation
import Testing
@testable import WhatCable

// These tests launch real subprocesses and include an intentional watchdog
// timeout. Serial execution keeps the timeout test from racing the two
// concurrent 4 MiB output fixtures on slower CI hosts.
@Suite("Test Kit probe output limit", .serialized)
struct TestKitRunnerOutputLimitTests {
    @Test("Output at the byte limit is preserved")
    @MainActor
    func outputAtLimitIsPreserved() async throws {
        let fixture = try makeOutputFixture(byteCount: TestKitRunner.maxProbeOutputBytes)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let result = await TestKitRunner.shared.runProbe(at: fixture)

        #expect(result.output?.utf8.count == TestKitRunner.maxProbeOutputBytes)
        #expect(!result.didExceedOutputLimit)
    }

    @Test("Output over the byte limit is rejected")
    @MainActor
    func outputOverLimitIsRejected() async throws {
        let fixture = try makeOutputFixture(byteCount: TestKitRunner.maxProbeOutputBytes + 1)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let result = await TestKitRunner.shared.runProbe(at: fixture)

        let outputWasRejected = result.output == nil
        #expect(outputWasRejected)
        #expect(result.didExceedOutputLimit)
    }

    @Test("An unbounded child is terminated as soon as it exceeds the limit")
    @MainActor
    func unboundedChildIsTerminatedAtLimit() async {
        let clock = ContinuousClock()
        let started = clock.now

        let result = await TestKitRunner.shared.runProbe(
            at: URL(fileURLWithPath: "/usr/bin/yes"),
            timeout: 5
        )

        let elapsed = started.duration(to: clock.now)
        #expect(result.output == nil)
        #expect(result.didExceedOutputLimit)
        #expect(elapsed < .seconds(3))
    }

    @Test("Small partial output from the watchdog path is preserved")
    @MainActor
    func timeoutPartialOutputIsPreserved() async throws {
        let fixture = try makeScript(contents: "#!/bin/sh\n/bin/echo partial\n/bin/sleep 5\n")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let result = await TestKitRunner.shared.runProbe(at: fixture, timeout: 2)

        #expect(result.output == "partial\n")
        #expect(result.didTimeout)
        #expect(!result.didExceedOutputLimit)
    }

    @Test("An incomplete UTF-8 sequence from the watchdog path is preserved")
    @MainActor
    func timeoutIncompleteUTF8IsPreserved() async throws {
        let fixture = try makeScript(contents: "#!/bin/sh\n/usr/bin/printf '\\303'\n/bin/sleep 5\n")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let result = await TestKitRunner.shared.runProbe(at: fixture, timeout: 2)

        #expect(result.output == "\u{FFFD}")
        #expect(result.didTimeout)
        #expect(!result.didExceedOutputLimit)
    }

    @Test("Oversized JSON request bodies are rejected")
    @MainActor
    func oversizedJSONBodyIsRejected() throws {
        let payload = ["output": String(repeating: "x", count: TestKitRunner.maxRequestBodyBytes)]

        let body = try TestKitRunner.boundedJSONBody(payload)

        #expect(body == nil)
    }

    @Test("Small JSON request bodies are preserved")
    @MainActor
    func smallJSONBodyIsPreserved() throws {
        let payload = ["output": "diagnostic"]

        let body = try TestKitRunner.boundedJSONBody(payload)

        #expect(body != nil)
    }

    private func makeOutputFixture(byteCount: Int) throws -> URL {
        try makeScript(contents: "#!/bin/sh\n/usr/bin/yes x | /usr/bin/head -c \(byteCount)\n")
    }

    private func makeScript(contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whatcable-test-kit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let script = directory.appendingPathComponent("emit-output")
        try Data(contents.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }
}
