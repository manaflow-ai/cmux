import Foundation
import Testing
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct NotificationSoundSettingsTests {
    @Test func namedSystemSoundStagesDistinctSoundFile() async throws {
        let fileManager = FileManager.default
        let stagedName = NotificationSoundSettings.stagedSystemSoundFileName(for: "Bottle")
        let stagingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-notification-sound-\(UUID().uuidString)", isDirectory: true)
        let stagedURL = stagingDirectory.appendingPathComponent(stagedName, isDirectory: false)
        defer {
            try? fileManager.removeItem(at: stagingDirectory)
        }

        #expect(try #require(await NotificationSoundSettings.stagedSystemSoundName(
            for: "Bottle",
            stagingDirectory: stagingDirectory
        )) == stagedName)
        #expect(fileManager.fileExists(atPath: stagedURL.path))

        let sourceURL = URL(fileURLWithPath: "/System/Library/Sounds/Bottle.aiff", isDirectory: false)
        let sourceData = try Data(contentsOf: sourceURL)
        let stagedData = try Data(contentsOf: stagedURL)
        #expect(stagedData == sourceData)
    }

    @Test func readyOnlySystemSoundStagesAnUnstagedBuiltInOverride() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-notification-ready-system-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = directory.appendingPathComponent("source", isDirectory: true)
        let stagingDirectory = directory.appendingPathComponent("staged", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        // The ready-only path must copy a system sound when the matrix selects
        // it for the first time. Custom codec readiness remains separate.
        let sourceURL = sourceDirectory.appendingPathComponent("Ping.aiff")
        try Data("synthetic-aiff".utf8).write(to: sourceURL)
        let stagedName = try #require(await NotificationSoundSettings.stagedSystemSoundName(
            for: "Ping",
            sourceDirectory: sourceDirectory,
            stagingDirectory: stagingDirectory,
            preparationPolicy: .readyOnly
        ))
        #expect(stagedName == NotificationSoundSettings.stagedSystemSoundFileName(for: "Ping"))
        #expect(fileManager.fileExists(atPath: stagingDirectory.appendingPathComponent(stagedName).path))
    }

    @Test func nonSoundSentinelsDoNotStageSystemSoundFiles() async {
        #expect(await NotificationSoundSettings.stagedSystemSoundName(for: "default") == nil)
        #expect(await NotificationSoundSettings.stagedSystemSoundName(for: "none") == nil)
        #expect(await NotificationSoundSettings.stagedSystemSoundName(for: NotificationSoundSettings.customFileValue) == nil)
    }

    @Test(arguments: ["m4r", "M4R"])
    func m4rCustomSoundFilesStageAsCaf(sourceExtension: String) {
        #expect(NotificationSoundSettings.stagedCustomSoundFileExtension(forSourceExtension: sourceExtension) == "caf")
    }

    @Test func activeFocusAssertionSuppressesFallbackSound() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-dnd-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let assertions = directory.appendingPathComponent("Assertions.json", isDirectory: false)

        // A Focus is active: storeAssertionRecords holds a live assertion.
        try Data(#"{"data":[{"storeAssertionRecords":[{"assertionDetails":{"x":1}}]}]}"#.utf8)
            .write(to: assertions)
        #expect(NotificationSoundSettings.isSuppressedByActiveFocus(assertionsFileURL: assertions))
    }

    @Test func endedFocusDoesNotSuppressSound() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-dnd-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let assertions = directory.appendingPathComponent("Assertions.json", isDirectory: false)

        // No Focus active: the assertion array is empty.
        try Data(#"{"data":[{"storeAssertionRecords":[]}]}"#.utf8).write(to: assertions)
        #expect(!NotificationSoundSettings.isSuppressedByActiveFocus(assertionsFileURL: assertions))
    }

    @Test func missingAssertionStoreFailsOpen() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-dnd-missing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Assertions.json", isDirectory: false)
        #expect(!NotificationSoundSettings.isSuppressedByActiveFocus(assertionsFileURL: missing))
    }

    // The canonical repro for the Focus bug is: the user enables a Focus, and
    // the next notification must already be silent. A cached Focus snapshot
    // that refreshes only after deciding lets exactly that first sound punch
    // through, so these tests drive the real playback entry point and assert
    // on the per-play decision, not on the pure predicate.

    @Test func firstPlayAfterFocusActivationIsSuppressed() async throws {
        let fixture = try ActiveFocusFixture()
        defer { fixture.cleanUp() }

        try fixture.writeAssertions(#"{"data":[{"storeAssertionRecords":[{"a":1}]}]}"#)
        #expect(await fixture.playOutcome() == false)
    }

    @Test func silentSelectionReportsNoPlaybackWhenFocusIsInactive() async throws {
        let fixture = try ActiveFocusFixture()
        defer { fixture.cleanUp() }

        #expect(await fixture.playOutcome() == false)
    }

    @Test func firstPlayAfterFocusEndsIsAudible() async throws {
        let fixture = try ActiveFocusFixture(selectedSound: NotificationSoundOverride.defaultValue)
        defer { fixture.cleanUp() }

        try fixture.writeAssertions(#"{"data":[{"storeAssertionRecords":[{"a":1}]}]}"#)
        #expect(await fixture.playOutcome() == false)

        // The Focus ended: the very next play must be audible again.
        try fixture.writeAssertions(#"{"data":[{"storeAssertionRecords":[]}]}"#)
        #expect(await fixture.playOutcome() == true)
    }

    @Test func playbackFailsOpenWhenAssertionStoreIsMissing() async throws {
        let fixture = try ActiveFocusFixture(
            createAssertionsFile: false,
            selectedSound: NotificationSoundOverride.defaultValue
        )
        defer { fixture.cleanUp() }

        #expect(await fixture.playOutcome() == true)
    }

    // The out-of-band fallback (direct NSSound) fires exactly when the OS
    // will not deliver the banner. A user who explicitly denied cmux
    // notifications asked for silence, so the fallback sound is stripped for
    // .denied - and only for .denied: fresh installs and granted states keep
    // the audible fallback, and non-sound effects are never touched.

    @Test func deniedAuthorizationStripsFallbackSound() {
        var effects = TerminalNotificationPolicyEffects()
        effects.sound = true
        let denied = TerminalNotificationStore.fallbackEffects(effects, authorizationState: .denied)
        #expect(!denied.sound)
    }

    @Test func deniedAuthorizationLeavesOtherEffectsIntact() {
        var effects = TerminalNotificationPolicyEffects()
        effects.sound = true
        let denied = TerminalNotificationStore.fallbackEffects(effects, authorizationState: .denied)
        #expect(denied.command == effects.command)
        #expect(denied.record == effects.record)
        #expect(denied.desktop == effects.desktop)
        #expect(denied.markUnread == effects.markUnread)
    }

    @Test func otherAuthorizationStatesKeepFallbackSound() {
        var effects = TerminalNotificationPolicyEffects()
        effects.sound = true
        let states: [NotificationAuthorizationState] = [
            .notDetermined, .unknown, .authorized, .provisional, .ephemeral,
        ]
        for state in states {
            #expect(TerminalNotificationStore.fallbackEffects(effects, authorizationState: state).sound)
        }
    }

    @Test func soundOverrideUsesCellAndMissingCustomFallsBackToGlobal() async throws {
        let suiteName = "cmux-tests-notification-overrides-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("Ping", forKey: NotificationSoundSettings.key)

        let missingCustom = try #require(NotificationSoundOverride(
            sound: NotificationSoundOverride.customFileValue,
            customSoundFilePath: "/tmp/cmux-sound-does-not-exist-\(UUID().uuidString).m4r"
        ))
        var overrides = NotificationSoundOverrides()
        overrides.set(
            try #require(NotificationSoundOverride(sound: "Bottle")),
            forAgentID: "claude",
            alertType: .turnDone
        )
        overrides.set(missingCustom, forAgentID: "claude", alertType: .needsInput)
        defaults.set(
            overrides.jsonString,
            forKey: NotificationsCatalogSection().soundOverrides.userDefaultsKey
        )

        let cases: [(NotificationSoundOverrideContext, String)] = [
            (try #require(NotificationSoundOverrideContext(agentID: "claude", alertType: .turnDone)), "Bottle"),
            (try #require(NotificationSoundOverrideContext(agentID: "codex", alertType: .turnDone)), "Ping"),
            (try #require(NotificationSoundOverrideContext(agentID: "claude", alertType: .needsInput)), "Ping"),
        ]
        for (context, expectedSound) in cases {
            let prepared = await NotificationSoundSettings.prepareNotificationSound(
                snapshot: NotificationSoundSettings.resolutionSnapshot(context: context, defaults: defaults)
            )
            #expect(prepared == .named(NotificationSoundSettings.stagedSystemSoundFileName(for: expectedSound)))
        }
    }

    @Test func explicitNoneOverrideDoesNotFallBack() async throws {
        let suiteName = "cmux-tests-notification-overrides-none-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("Ping", forKey: NotificationSoundSettings.key)
        var overrides = NotificationSoundOverrides()
        overrides.set(
            try #require(NotificationSoundOverride(sound: NotificationSoundOverride.noneValue)),
            forAgentID: "codex",
            alertType: .errorStalled
        )
        defaults.set(overrides.jsonString, forKey: NotificationsCatalogSection().soundOverrides.userDefaultsKey)
        let context = try #require(NotificationSoundOverrideContext(agentID: "codex", alertType: .errorStalled))
        let prepared = await NotificationSoundSettings.prepareNotificationSound(
            snapshot: NotificationSoundSettings.resolutionSnapshot(
                context: context,
                defaults: defaults
            )
        )
        #expect(prepared == .silent)
    }

    @Test func defaultSoundOverrideUsesConfiguredGlobalSound() async throws {
        let suiteName = "cmux-tests-notification-overrides-default-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("Ping", forKey: NotificationSoundSettings.key)

        var overrides = NotificationSoundOverrides()
        overrides.set(
            try #require(NotificationSoundOverride(sound: NotificationSoundOverride.defaultValue)),
            forAgentID: "codex",
            alertType: .turnDone
        )
        defaults.set(
            overrides.jsonString,
            forKey: NotificationsCatalogSection().soundOverrides.userDefaultsKey
        )

        let context = try #require(NotificationSoundOverrideContext(agentID: "codex", alertType: .turnDone))
        let prepared = await NotificationSoundSettings.prepareNotificationSound(
            snapshot: NotificationSoundSettings.resolutionSnapshot(
                context: context,
                defaults: defaults
            )
        )
        #expect(prepared == .named(NotificationSoundSettings.stagedSystemSoundFileName(for: "Ping")))
    }

    @Test func oversizedOverrideMatrixFallsBackToGlobalSound() throws {
        let suiteName = "cmux-tests-notification-overrides-size-limit-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("Ping", forKey: NotificationSoundSettings.key)

        // Keep the JSON valid while making the persisted value large enough to
        // exercise the bounded snapshot admission path.
        let oversizedPath = String(repeating: "a", count: 300_000)
        let raw = "{\"claude\":{\"turnDone\":{\"sound\":\"custom_file\",\"customSoundFilePath\":\"\(oversizedPath)\"}}}"
        defaults.set(
            raw,
            forKey: NotificationsCatalogSection().soundOverrides.userDefaultsKey
        )

        let context = try #require(
            NotificationSoundOverrideContext(agentID: "claude", alertType: .turnDone)
        )
        let snapshot = NotificationSoundSettings.resolutionSnapshot(
            context: context,
            defaults: defaults
        )

        #expect(snapshot.globalSelection.value == "Ping")
        #expect(snapshot.overrideSelection == nil)
    }

    @Test func customSelectionValidatesAndStagesM4R() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-sound-selection-\(UUID().uuidString)", isDirectory: true)
        let stagingDirectory = directory.appendingPathComponent("staged", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let wavURL = directory.appendingPathComponent("source.wav", isDirectory: false)
        try Self.writeSilentWAV(to: wavURL)
        let m4rURL = directory.appendingPathComponent("source.m4r", isDirectory: false)
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "m4af", "-d", "aac", wavURL.path, m4rURL.path]
        try convert.run()
        convert.waitUntilExit()
        #expect(convert.terminationStatus == 0)

        #expect(await NotificationSoundSettings.validateCustomSoundFileForSelection(
            path: m4rURL.path,
            stagingDirectory: stagingDirectory
        ))
        let stagedFiles = try fileManager.contentsOfDirectory(atPath: stagingDirectory.path)
            .filter { $0.hasSuffix(".caf") }
        #expect(stagedFiles.count == 1)
    }

    @Test func concurrentM4RSelectionsShareOneCompleteArtifact() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-sound-concurrent-\(UUID().uuidString)", isDirectory: true)
        let stagingDirectory = directory.appendingPathComponent("staged", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let wavURL = directory.appendingPathComponent("source.wav", isDirectory: false)
        try Self.writeSilentWAV(to: wavURL)
        let m4rURL = directory.appendingPathComponent("source.m4r", isDirectory: false)
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "m4af", "-d", "aac", wavURL.path, m4rURL.path]
        try convert.run()
        convert.waitUntilExit()
        #expect(convert.terminationStatus == 0)

        async let first = NotificationSoundSettings.validateCustomSoundFileForSelection(
            path: m4rURL.path,
            stagingDirectory: stagingDirectory
        )
        async let second = NotificationSoundSettings.validateCustomSoundFileForSelection(
            path: m4rURL.path,
            stagingDirectory: stagingDirectory
        )
        let (firstResult, secondResult) = await (first, second)

        #expect(firstResult)
        #expect(secondResult)
        let stagedFiles = try fileManager.contentsOfDirectory(atPath: stagingDirectory.path)
            .filter { $0.hasSuffix(".caf") }
        #expect(stagedFiles.count == 1)
    }

    @Test func missingOrUndecodableCustomSelectionIsRejected() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sound-invalid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let invalidURL = directory.appendingPathComponent("not-audio.wav", isDirectory: false)
        try Data("not audio".utf8).write(to: invalidURL)
        #expect(!(await NotificationSoundSettings.validateCustomSoundFileForSelection(
            path: invalidURL.path,
            stagingDirectory: directory.appendingPathComponent("staged", isDirectory: true),
            decoder: { _ in false }
        )))
        #expect(!(await NotificationSoundSettings.validateCustomSoundFileForSelection(
            path: directory.appendingPathComponent("missing.wav").path,
            stagingDirectory: directory.appendingPathComponent("staged", isDirectory: true),
            decoder: { _ in true }
        )))
    }

    @Test func disappearedCustomCellFallsBackToGlobalSound() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-sound-disappear-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let customURL = directory.appendingPathComponent("custom.wav", isDirectory: false)
        try Self.writeSilentWAV(to: customURL)

        let suiteName = "cmux-tests-notification-overrides-disappear-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("Ping", forKey: NotificationSoundSettings.key)
        var overrides = NotificationSoundOverrides()
        overrides.set(
            try #require(NotificationSoundOverride(
                sound: NotificationSoundOverride.customFileValue,
                customSoundFilePath: customURL.path
            )),
            forAgentID: "claude",
            alertType: .turnDone
        )
        defaults.set(overrides.jsonString, forKey: NotificationsCatalogSection().soundOverrides.userDefaultsKey)
        let context = try #require(NotificationSoundOverrideContext(agentID: "claude", alertType: .turnDone))

        let stagingDirectory = directory.appendingPathComponent("staged", isDirectory: true)
        let initial = await NotificationSoundSettings.prepareNotificationSound(
            snapshot: NotificationSoundSettings.resolutionSnapshot(
                context: context,
                defaults: defaults
            ),
            stagingDirectory: stagingDirectory
        )
        #expect(initial == .named(NotificationSoundSettings.stagedCustomSoundFileName(
            forSourceURL: customURL,
            destinationExtension: "wav"
        )))

        try fileManager.removeItem(at: customURL)
        let afterRemoval = await NotificationSoundSettings.prepareNotificationSound(
            snapshot: NotificationSoundSettings.resolutionSnapshot(
                context: context,
                defaults: defaults
            ),
            stagingDirectory: stagingDirectory
        )
        #expect(afterRemoval == .named(
            NotificationSoundSettings.stagedSystemSoundFileName(for: "Ping")
        ))
    }

    @Test func undecodableDeclarativeCustomCellFallsBackToGlobalSound() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-sound-undecodable-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let invalidURL = directory.appendingPathComponent("invalid.wav", isDirectory: false)
        try Data("not audio".utf8).write(to: invalidURL)

        let suiteName = "cmux-tests-notification-overrides-undecodable-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("Ping", forKey: NotificationSoundSettings.key)
        var overrides = NotificationSoundOverrides()
        overrides.set(
            try #require(NotificationSoundOverride(
                sound: NotificationSoundOverride.customFileValue,
                customSoundFilePath: invalidURL.path
            )),
            forAgentID: "codex",
            alertType: .needsInput
        )
        defaults.set(
            overrides.jsonString,
            forKey: NotificationsCatalogSection().soundOverrides.userDefaultsKey
        )
        let context = try #require(NotificationSoundOverrideContext(
            agentID: "codex",
            alertType: .needsInput
        ))

        let prepared = await NotificationSoundSettings.prepareNotificationSound(
            snapshot: NotificationSoundSettings.resolutionSnapshot(
                context: context,
                defaults: defaults
            ),
            stagingDirectory: directory.appendingPathComponent("staged", isDirectory: true)
        )
        #expect(prepared == .named(
            NotificationSoundSettings.stagedSystemSoundFileName(for: "Ping")
        ))
    }

    @Test func unavailableGlobalCustomSoundRemainsSilent() async throws {
        let suiteName = "cmux-tests-notification-global-custom-missing-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(NotificationSoundOverride.customFileValue, forKey: NotificationSoundSettings.key)
        defaults.set(
            "/tmp/cmux-global-sound-missing-\(UUID().uuidString).wav",
            forKey: NotificationSoundSettings.customFilePathKey
        )

        let prepared = await NotificationSoundSettings.prepareNotificationSound(
            snapshot: NotificationSoundSettings.resolutionSnapshot(
                context: nil,
                defaults: defaults
            )
        )
        #expect(prepared == .silent)
    }

    @Test func multipleCustomCellsKeepIndependentStagedArtifacts() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-sound-multiple-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.wav", isDirectory: false)
        let second = directory.appendingPathComponent("second.wav", isDirectory: false)
        try Self.writeSilentWAV(to: first)
        try Self.writeSilentWAV(to: second)
        let staging = directory.appendingPathComponent("staged", isDirectory: true)

        let firstName = try #require(await NotificationSoundSettings.prepareCustomFileForNotifications(
            path: first.path,
            stagingDirectory: staging
        ).successValueForTests)
        let secondName = try #require(await NotificationSoundSettings.prepareCustomFileForNotifications(
            path: second.path,
            stagingDirectory: staging
        ).successValueForTests)
        #expect(firstName != secondName)
        #expect(fileManager.fileExists(atPath: staging.appendingPathComponent(firstName).path))
        #expect(fileManager.fileExists(atPath: staging.appendingPathComponent(secondName).path))
    }

    @Test func customSoundStagingRemainsBounded() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-sound-cache-bound-\(UUID().uuidString)", isDirectory: true)
        let staging = directory.appendingPathComponent("staged", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        for index in 0..<70 {
            let source = directory.appendingPathComponent("source-\(index).wav", isDirectory: false)
            try Self.writeSilentWAV(to: source)
            let result = await NotificationSoundSettings.prepareCustomFileForNotifications(
                path: source.path,
                stagingDirectory: staging
            )
            #expect(result.successValueForTests != nil)
        }

        NotificationSoundStagingArtifactCleaner().prune(
            in: staging,
            preserving: []
        )
        let artifacts = try fileManager.contentsOfDirectory(atPath: staging.path)
            .filter {
                $0.hasPrefix(NotificationSoundSettings.customSoundBaseName + "-")
                    && !$0.hasSuffix(".source-metadata")
            }
        #expect(artifacts.count <= 64)
    }

    @Test func customSoundSignatureUsesStableLowercaseHex() {
        let source = URL(fileURLWithPath: "/tmp/cmux-signature-test.wav", isDirectory: false)
        #expect(
            NotificationSoundSettings.stagedFileName(
                forSourceURL: source,
                destinationExtension: "wav"
            ) == "cmux-custom-notification-sound-5e429f2d15385535.wav"
        )
    }

    @Test func customSoundConversionHasBoundedDeadline() async {
        let runner = NotificationSoundProcessRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/sleep"),
            timeoutNanoseconds: 50_000_000,
            argumentBuilder: { _, _ in ["1"] }
        )
        await #expect(throws: CancellationError.self) {
            try await runner.run(
                from: URL(fileURLWithPath: "/tmp/source.wav"),
                to: URL(fileURLWithPath: "/tmp/destination.caf")
            )
        }
    }

    @Test(.timeLimit(.seconds(15)))
    func concurrentBlockingProcessWaitsDoNotStarveTimeoutTasks() async {
        let runner = NotificationSoundProcessRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            timeoutNanoseconds: 250_000_000,
            argumentBuilder: { _, _ in ["-c", "sleep 3"] }
        )
        let startedAt = ContinuousClock.now
        let tasks = (0..<48).map { index in
            Task {
                do {
                    _ = try await runner.run(
                        from: URL(fileURLWithPath: "/tmp/cmux-sound-source-\(index)"),
                        to: URL(fileURLWithPath: "/tmp/cmux-sound-destination-\(index)")
                    )
                    return false
                } catch {
                    return true
                }
            }
        }

        var allTimedOut = true
        for task in tasks {
            allTimedOut = await task.value && allTimedOut
        }

        // The old detached wait/read helpers occupied every cooperative worker
        // until the three-second child exited. A dedicated blocking bridge
        // keeps the timeout tasks runnable and completes this burst promptly.
        #expect(allTimedOut)
        #expect(ContinuousClock.now - startedAt < .seconds(2))
    }

    @Test func customSoundConversionDrainsErrorOutputBeforeReturning() async throws {
        let runner = NotificationSoundProcessRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            timeoutNanoseconds: 1_000_000_000,
            argumentBuilder: { _, _ in
                ["-c", "printf conversion-warning >&2"]
            }
        )
        let result = try await runner.run(
            from: URL(fileURLWithPath: "/tmp/source.wav"),
            to: URL(fileURLWithPath: "/tmp/destination.caf")
        )
        #expect(result.terminationStatus == 0)
        #expect(result.errorOutput == "conversion-warning")
    }

    @Test("Discarded custom-command stderr cannot be held by a background child")
    func customCommandRunnerDoesNotWaitForBackgroundStderrDescendant() async throws {
        let runner = NotificationSoundProcessRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            timeoutNanoseconds: 100_000_000,
            capturesErrorOutput: false
        )
        let result = try await runner.run(
            arguments: ["-c", "sleep 0.5 &"],
            environment: nil
        )

        #expect(result.terminationStatus == 0)
        #expect(result.errorOutput == nil)
    }

    @Test("The sound matrix includes case-preserving Vault registrations")
    func notificationSoundAgentLoaderIncludesUppercaseVaultID() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-sound-agent-registry-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
        try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        let config = """
        {
          "vault": {
            "agents": [{
              "id": "MyAgent",
              "name": "My Agent",
              "detect": { "processName": "my-agent" },
              "sessionIdSource": { "type": "argvOption", "argvOption": "--session" },
              "resumeCommand": "my-agent --session {{sessionId}}"
            }]
          }
        }
        """
        try config.write(
            to: configDirectory.appendingPathComponent("cmux.json"),
            atomically: true,
            encoding: .utf8
        )

        let options = await NotificationSoundAgentRegistryLoader().load(
            homeDirectory: home.path
        )
        #expect(options.contains { $0.id == "MyAgent" && $0.displayName == "My Agent" })
    }

    @Test func customSoundPruningLeavesUserFilesWithReservedPrefix() throws {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-sound-prune-ownership-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let userFile = staging.appendingPathComponent(
            "cmux-custom-notification-sound-user.wav",
            isDirectory: false
        )
        try Self.writeSilentWAV(to: userFile)
        let managedSource = staging.appendingPathComponent(
            "managed-source.wav",
            isDirectory: false
        )
        try Self.writeSilentWAV(to: managedSource)
        let generatedNamedSource = staging.appendingPathComponent(
            NotificationSoundSettings.stagedFileName(
                forSourceURL: managedSource,
                destinationExtension: "wav"
            ),
            isDirectory: false
        )
        try Self.writeSilentWAV(to: generatedNamedSource)
        let generatedSourceMetadata = try #require(
            NotificationSoundSettings.currentMetadata(
                for: managedSource,
                fileManager: fileManager
            )
        )
        try NotificationSoundSettings.saveMetadata(
            generatedSourceMetadata,
            for: generatedNamedSource
        )
        for index in 0..<65 {
            let source = staging.appendingPathComponent(
                "source-\(index).wav",
                isDirectory: false
            )
            try Self.writeSilentWAV(to: source)
            let artifact = staging.appendingPathComponent(
                NotificationSoundSettings.stagedFileName(
                    forSourceURL: source,
                    destinationExtension: "wav"
                ),
                isDirectory: false
            )
            try Self.writeSilentWAV(to: artifact)
            let metadata = try #require(
                NotificationSoundSettings.currentMetadata(
                    for: source,
                    fileManager: fileManager
                )
            )
            try NotificationSoundSettings.saveMetadata(metadata, for: artifact)
            let staleDate = Date(timeIntervalSinceNow: -(31 * 24 * 60 * 60))
            try fileManager.setAttributes(
                [.modificationDate: staleDate],
                ofItemAtPath: artifact.path
            )
            try fileManager.setAttributes(
                [.modificationDate: staleDate],
                ofItemAtPath: artifact.appendingPathExtension("source-metadata").path
            )
        }

        NotificationSoundStagingArtifactCleaner().prune(
            in: staging,
            preserving: [generatedNamedSource]
        )
        #expect(fileManager.fileExists(atPath: userFile.path))
        #expect(fileManager.fileExists(atPath: generatedNamedSource.path))
        let remainingArtifacts = try fileManager.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter {
            $0.lastPathComponent.hasPrefix(NotificationSoundSettings.customSoundBaseName + "-")
                && !$0.lastPathComponent.hasSuffix(".source-metadata")
        }
        #expect(remainingArtifacts.count <= 3)
    }

    private static func writeSilentWAV(to url: URL) throws {
        let sampleRate: UInt32 = 8_000
        let samples = Data(repeating: 128, count: Int(sampleRate / 10))
        var data = Data("RIFF".utf8)
        data.append(littleEndian: UInt32(36 + samples.count))
        data.append(Data("WAVEfmt ".utf8))
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: sampleRate)
        data.append(littleEndian: sampleRate)
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: UInt16(8))
        data.append(Data("data".utf8))
        data.append(littleEndian: UInt32(samples.count))
        data.append(samples)
        try data.write(to: url, options: .atomic)
    }
}

private extension Result where Success == String {
    var successValueForTests: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}

/// Drives `playSelectedSound` against a scratch assertion store and scratch
/// defaults whose selected sound is "none", so the decision is observable
/// without audible output.
private struct ActiveFocusFixture {
    let directory: URL
    let assertionsFileURL: URL
    let defaults: UserDefaults
    private let suiteName: String

    init(
        createAssertionsFile: Bool = true,
        selectedSound: String = NotificationSoundOverride.noneValue
    ) throws {
        let fileManager = FileManager.default
        directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-dnd-play-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        assertionsFileURL = directory.appendingPathComponent("Assertions.json", isDirectory: false)
        if createAssertionsFile {
            try Data(#"{"data":[]}"#.utf8).write(to: assertionsFileURL)
        }
        suiteName = "cmux-tests-notification-sound-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(selectedSound, forKey: NotificationSoundSettings.key)
    }

    func writeAssertions(_ json: String) throws {
        try Data(json.utf8).write(to: assertionsFileURL)
    }

    func playOutcome() async -> Bool {
        await NotificationSoundSettings.playSelectedSound(
            defaults: defaults,
            assertionsFileURL: assertionsFileURL
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
