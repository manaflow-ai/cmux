#!/usr/bin/env swift

import AppKit
import Darwin
import Dispatch
import Foundation

private struct Options {
    let appURL: URL
    let authProfile: String?
    let credentialsFile: String?

    init(arguments: ArraySlice<String>) throws {
        guard let path = arguments.first, !path.isEmpty else {
            throw NSError(domain: "LaunchBundleApp", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "usage: launch-bundle-app.swift <app-path> [--auth-profile <profile>] [--credentials-file <path>]"
            ])
        }
        var profile: String?
        var credentials: String?
        var remaining = arguments.dropFirst()
        while let option = remaining.first {
            remaining = remaining.dropFirst()
            switch option {
            case "--auth-profile":
                guard let value = remaining.first, !value.isEmpty else {
                    throw NSError(domain: "LaunchBundleApp", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "--auth-profile requires a value"
                    ])
                }
                profile = value
                remaining = remaining.dropFirst()
            case "--credentials-file":
                guard let value = remaining.first, !value.isEmpty else {
                    throw NSError(domain: "LaunchBundleApp", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "--credentials-file requires a path"
                    ])
                }
                credentials = value
                remaining = remaining.dropFirst()
            default:
                throw NSError(domain: "LaunchBundleApp", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "unknown option '\(option)'"
                ])
            }
        }
        self.appURL = URL(fileURLWithPath: path, isDirectory: true)
        self.authProfile = profile
        self.credentialsFile = credentials
    }
}

private let secretEnvironmentKeys = [
    "CMUX_AUTH_CREDENTIALS_FILE",
    "CMUX_DEV_AUTH_PROFILE",
    "CMUX_DEV_AUTH_ACCOUNT",
    "CMUX_DEV_AUTH_REPLACE_SESSION",
    "CMUX_DOGFOOD_STACK_EMAIL",
    "CMUX_DOGFOOD_STACK_PASSWORD",
    "CMUX_UITEST_STACK_EMAIL",
    "CMUX_UITEST_STACK_PASSWORD",
]

private func launchEnvironment(
    for appURL: URL,
    authProfile: String?,
    credentialsFile: String?
) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    for key in secretEnvironmentKeys {
        environment.removeValue(forKey: key)
    }

    if let bundle = Bundle(url: appURL),
       let launchEnvironment = bundle.infoDictionary?["LSEnvironment"] as? [String: Any] {
        for (key, value) in launchEnvironment {
            guard let value = value as? String else { continue }
            environment[key] = value
        }
    }

    if let authProfile {
        environment["CMUX_DEV_AUTH_PROFILE"] = authProfile
        environment["CMUX_DEV_AUTH_REPLACE_SESSION"] = "1"
    }
    if let credentialsFile {
        environment["CMUX_AUTH_CREDENTIALS_FILE"] = credentialsFile
    }
    return environment
}

private func run() async throws {
    let options = try Options(arguments: CommandLine.arguments.dropFirst())
    guard FileManager.default.fileExists(atPath: options.appURL.path) else {
        throw NSError(domain: "LaunchBundleApp", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "application bundle does not exist: \(options.appURL.path)"
        ])
    }
    guard Bundle(url: options.appURL)?.executableURL != nil else {
        throw NSError(domain: "LaunchBundleApp", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "application bundle has no executable: \(options.appURL.path)"
        ])
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.environment = launchEnvironment(
        for: options.appURL,
        authProfile: options.authProfile,
        credentialsFile: options.credentialsFile
    )
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        NSWorkspace.shared.openApplication(at: options.appURL, configuration: configuration) { _, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
}

Task {
    do {
        try await run()
        exit(EXIT_SUCCESS)
    } catch {
        fputs("error: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}
dispatchMain()
