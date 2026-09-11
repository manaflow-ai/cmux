#!/usr/bin/env swift
// Exports the editable Icon Composer document to the legacy .icns file that
// System Settings uses for the standalone Computer Use helper.
//
// Usage: swift scripts/generate-computer-use-helper-icon.swift

import Foundation

private struct Rendition {
    let filename: String
    let points: Int
    let scale: Int
}

private let renditions = [
    Rendition(filename: "icon_16x16.png", points: 16, scale: 1),
    Rendition(filename: "icon_16x16@2x.png", points: 16, scale: 2),
    Rendition(filename: "icon_32x32.png", points: 32, scale: 1),
    Rendition(filename: "icon_32x32@2x.png", points: 32, scale: 2),
    Rendition(filename: "icon_128x128.png", points: 128, scale: 1),
    Rendition(filename: "icon_128x128@2x.png", points: 128, scale: 2),
    Rendition(filename: "icon_256x256.png", points: 256, scale: 1),
    Rendition(filename: "icon_256x256@2x.png", points: 256, scale: 2),
    Rendition(filename: "icon_512x512.png", points: 512, scale: 1),
    Rendition(filename: "icon_512x512@2x.png", points: 512, scale: 2),
]

private enum ExportError: LocalizedError {
    case missingFile(URL)
    case commandFailed(URL, Int32, String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let url):
            "Required file is missing: \(url.path)"
        case .commandFailed(let executable, let status, let output):
            "\(executable.lastPathComponent) failed with status \(status): \(output)"
        }
    }
}

private struct ComputerUseHelperIconExporter {
    let fileManager: FileManager

    @discardableResult
    private func run(_ executable: URL, arguments: [String]) throws -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExportError.commandFailed(
                executable,
                process.terminationStatus,
                output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return output
    }

    func export() throws {
        let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
        let repositoryRoot = scriptURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let documentURL = repositoryRoot
            .appendingPathComponent("Resources/ComputerUseHelper.icon", isDirectory: true)
        let outputURL = repositoryRoot
            .appendingPathComponent("Resources/ComputerUseHelperIcon.icns")

        guard fileManager.fileExists(atPath: documentURL.path) else {
            throw ExportError.missingFile(documentURL)
        }

        let developerDirectory = try run(
            URL(fileURLWithPath: "/usr/bin/xcode-select"),
            arguments: ["-p"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let iconComposerURL = URL(fileURLWithPath: developerDirectory)
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Applications/Icon Composer.app/Contents/Executables/ictool"
            )
        guard fileManager.isExecutableFile(atPath: iconComposerURL.path) else {
            throw ExportError.missingFile(iconComposerURL)
        }

        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(
                "cmux-computer-use-icon-\(UUID().uuidString)",
                isDirectory: true
            )
        let iconsetURL = temporaryRoot
            .appendingPathComponent("ComputerUseHelper.iconset", isDirectory: true)
        try fileManager.createDirectory(
            at: iconsetURL,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        for rendition in renditions {
            let imageURL = iconsetURL.appendingPathComponent(rendition.filename)
            _ = try run(iconComposerURL, arguments: [
                documentURL.path,
                "--export-image",
                "--output-file", imageURL.path,
                "--platform", "macOS",
                "--rendition", "Default",
                "--width", String(rendition.points),
                "--height", String(rendition.points),
                "--scale", String(rendition.scale),
            ])
        }

        _ = try run(URL(fileURLWithPath: "/usr/bin/iconutil"), arguments: [
            "-c", "icns",
            "-o", outputURL.path,
            iconsetURL.path,
        ])
        print(outputURL.path)
    }
}

do {
    try ComputerUseHelperIconExporter(fileManager: .default).export()
} catch {
    FileHandle.standardError.write(
        Data("error: \(error.localizedDescription)\n".utf8)
    )
    exit(1)
}
