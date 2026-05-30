// SPDX-License-Identifier: MIT
//
// Task 1.19 — round-trips the HTTP control Settings view model against
// a real ``HTTPControlSettings`` instance backed by a per-test
// `UserDefaults` suite, and asserts the two spec-mandated safety
// warnings show the expected substrings (spec §5.4 TCP RCE warning;
// spec §8.3 OSC 52 / DSR / DECRQSS reflection-injection warning).

import Foundation
import Testing
@testable import cmux

@Suite struct HTTPControlSettingsViewModelTests {
    @MainActor
    @Test func settingsRoundTripThroughViewModel() throws {
        let suite = "cmux.http.vm.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-http-vm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let settings = HTTPControlSettings(supportDirectory: dir, defaults: defaults)
        let vm = HTTPControlSettingsViewModel(settings: settings)
        vm.enabled = true
        vm.tcpPort = 9999
        vm.allowRawInput = true
        try vm.commit()

        #expect(settings.enabled)
        #expect(settings.tcpPort == 9999)
        #expect(settings.allowRawInput)

        let rotated = try vm.rotateToken()
        let read = try settings.ensureToken()
        #expect(rotated == read)
    }

    @MainActor
    @Test func enabledTCPSurfacesWarningString() throws {
        let suite = "cmux.http.vm.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-http-vm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let settings = HTTPControlSettings(supportDirectory: dir, defaults: defaults)
        settings.enabled = true
        settings.transport = .tcp
        let vm = HTTPControlSettingsViewModel(settings: settings)
        // EN string contains "local process"; JA contains "ローカル".
        let s = vm.tcpSafetyWarning
        #expect(s.contains("local process") || s.contains("ローカル"))
    }

    @MainActor
    @Test func rawToggleSurfacesOSC52DSRWarning() throws {
        let suite = "cmux.http.vm.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-http-vm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let settings = HTTPControlSettings(supportDirectory: dir, defaults: defaults)
        settings.allowRawInput = true
        let vm = HTTPControlSettingsViewModel(settings: settings)
        let s = vm.rawInputWarning
        #expect(s.contains("OSC 52") || s.contains("クリップボード"))
        // DSR substring covers both EN (DSR / DECRQSS) and JA (DSR/DECRQSS).
        #expect(s.contains("DSR") || s.contains("DECRQSS") || s.contains("反射"))
    }

    @MainActor
    @Test func rotateTokenInvokesOnRotatedCallback() throws {
        let suite = "cmux.http.vm.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-http-vm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let settings = HTTPControlSettings(supportDirectory: dir, defaults: defaults)
        let vm = HTTPControlSettingsViewModel(settings: settings)
        var rotatedTo: String?
        vm.onTokenRotated = { rotatedTo = $0 }
        let t = try vm.rotateToken()
        #expect(rotatedTo == t)
    }
}
