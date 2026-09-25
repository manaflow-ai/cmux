import CMUXProjectModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Project panel localization")
struct ProjectPanelLocalizationTests {
    @Test("unreadable project errors use the localized summary")
    func unreadableProjectErrorUsesLocalizedSummary() async throws {
        let url = Self.uniqueProjectURL()
        let panel = ProjectPanel(projectURL: url)
        panel.reload()

        let message = try await Self.waitForFailure(in: panel)
        #expect(message == String.localizedStringWithFormat(
            String(localized: "projectPanel.loadError.unreadable", defaultValue: "Cannot read project at %@"),
            url.path
        ))
        #expect(message.contains(url.path))
    }

    @Test("parse failure errors hide parser reasons")
    func parseFailureHidesParserReason() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-project-panel-\(UUID().uuidString).xcodeproj")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not a property list".utf8).write(to: directory.appendingPathComponent("project.pbxproj"))

        let panel = ProjectPanel(projectURL: directory)
        panel.reload()

        let message = try await Self.waitForFailure(in: panel)
        #expect(message == String.localizedStringWithFormat(
            String(localized: "projectPanel.loadError.parseFailure", defaultValue: "Unable to parse project at %@"),
            directory.path
        ))
        #expect(message.contains(directory.path))
        #expect(!message.localizedCaseInsensitiveContains("not a property list"))
    }

    private static func uniqueProjectURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-project-panel-\(UUID().uuidString).xcodeproj")
    }

    private static func waitForFailure(in panel: ProjectPanel) async throws -> String {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if case let .failed(message) = panel.loadState {
                return message
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TestTimeout()
    }

    private struct TestTimeout: Error {}
}
