import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SchedulerPersistenceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-scheduler-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Save empty list creates file

    func testSaveEmptyListCreatesFile() {
        let fileURL = tempDir.appendingPathComponent("scheduler.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        let result = SchedulerPersistenceStore.save([], fileURL: fileURL)
        XCTAssertTrue(result)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSaveEmptyListCreatesValidJSON() throws {
        let fileURL = tempDir.appendingPathComponent("scheduler.json")
        SchedulerPersistenceStore.save([], fileURL: fileURL)

        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode([ScheduledTask].self, from: data)
        XCTAssertTrue(decoded.isEmpty)
    }

    // MARK: - Save/load round-trip

    func testSaveLoadRoundTrip() {
        let fileURL = tempDir.appendingPathComponent("scheduler.json")
        let tasks = [
            ScheduledTask(
                name: "backup",
                cronExpression: "0 3 * * *",
                command: "/usr/bin/backup.sh",
                workingDirectory: "/home/user",
                environment: ["MODE": "full"],
                isEnabled: true,
                allowOverlap: false,
                useWorktree: true,
                onSuccess: "echo done",
                onFailure: "echo failed",
                createdAt: Date(timeIntervalSince1970: 1700000000)
            ),
            ScheduledTask(
                name: "cleanup",
                cronExpression: "*/10 * * * *",
                command: "rm -rf /tmp/cache",
                isEnabled: false,
                createdAt: Date(timeIntervalSince1970: 1700000060)
            ),
        ]

        XCTAssertTrue(SchedulerPersistenceStore.save(tasks, fileURL: fileURL))

        let loaded = SchedulerPersistenceStore.load(fileURL: fileURL)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].name, "backup")
        XCTAssertEqual(loaded[0].cronExpression, "0 3 * * *")
        XCTAssertEqual(loaded[0].command, "/usr/bin/backup.sh")
        XCTAssertEqual(loaded[0].workingDirectory, "/home/user")
        XCTAssertEqual(loaded[0].environment, ["MODE": "full"])
        XCTAssertTrue(loaded[0].isEnabled)
        XCTAssertFalse(loaded[0].allowOverlap)
        XCTAssertEqual(loaded[0].useWorktree, true)
        XCTAssertEqual(loaded[0].onSuccess, "echo done")
        XCTAssertEqual(loaded[0].onFailure, "echo failed")
        XCTAssertEqual(loaded[0].createdAt, Date(timeIntervalSince1970: 1700000000))

        XCTAssertEqual(loaded[1].name, "cleanup")
        XCTAssertFalse(loaded[1].isEnabled)
        XCTAssertNil(loaded[1].workingDirectory)
        XCTAssertNil(loaded[1].environment)

        XCTAssertEqual(tasks, loaded)
    }

    func testSaveLoadPreservesTaskIds() {
        let fileURL = tempDir.appendingPathComponent("scheduler.json")
        let task = ScheduledTask(
            name: "test",
            cronExpression: "* * * * *",
            command: "echo",
            createdAt: Date(timeIntervalSince1970: 1700000000)
        )

        SchedulerPersistenceStore.save([task], fileURL: fileURL)
        let loaded = SchedulerPersistenceStore.load(fileURL: fileURL)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, task.id)
    }

    // MARK: - Load missing file returns empty array

    func testLoadMissingFileReturnsEmptyArray() {
        let fileURL = tempDir.appendingPathComponent("nonexistent.json")
        let loaded = SchedulerPersistenceStore.load(fileURL: fileURL)
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - Load corrupt JSON returns empty array

    func testLoadCorruptJSONReturnsEmptyArray() throws {
        let fileURL = tempDir.appendingPathComponent("corrupt.json")
        try "not valid json {{{".data(using: .utf8)!.write(to: fileURL)

        let loaded = SchedulerPersistenceStore.load(fileURL: fileURL)
        XCTAssertTrue(loaded.isEmpty)
    }

    func testLoadWrongSchemaReturnsEmptyArray() throws {
        let fileURL = tempDir.appendingPathComponent("wrong-schema.json")
        try "{\"key\": \"value\"}".data(using: .utf8)!.write(to: fileURL)

        let loaded = SchedulerPersistenceStore.load(fileURL: fileURL)
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - Default file URL

    func testDefaultSchedulerFileURLContainsBundleId() {
        let url = SchedulerPersistenceStore.defaultSchedulerFileURL(
            bundleIdentifier: "com.cmuxterm.app.dev",
            appSupportDirectory: tempDir
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.path.contains("scheduler-com.cmuxterm.app.dev.json"))
        XCTAssertTrue(url!.path.contains("/cmux/"))
    }

    func testDefaultSchedulerFileURLSanitizesBundleId() {
        let url = SchedulerPersistenceStore.defaultSchedulerFileURL(
            bundleIdentifier: "com.example/unsafe id",
            appSupportDirectory: tempDir
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.path.contains("scheduler-com.example_unsafe_id.json"))
    }

    func testDefaultSchedulerFileURLFallsBackForEmptyBundleId() {
        let url = SchedulerPersistenceStore.defaultSchedulerFileURL(
            bundleIdentifier: "",
            appSupportDirectory: tempDir
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.path.contains("scheduler-com.cmuxterm.app.json"))
    }

    func testDefaultSchedulerFileURLFallsBackForNilBundleId() {
        let url = SchedulerPersistenceStore.defaultSchedulerFileURL(
            bundleIdentifier: nil,
            appSupportDirectory: tempDir
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.path.contains("scheduler-com.cmuxterm.app.json"))
    }

    // MARK: - Overwrite behavior

    func testSaveOverwritesPreviousData() {
        let fileURL = tempDir.appendingPathComponent("scheduler.json")
        let original = [
            ScheduledTask(name: "old", cronExpression: "* * * * *", command: "echo old",
                          createdAt: Date(timeIntervalSince1970: 1700000000)),
        ]
        let replacement = [
            ScheduledTask(name: "new", cronExpression: "0 * * * *", command: "echo new",
                          createdAt: Date(timeIntervalSince1970: 1700000060)),
        ]

        SchedulerPersistenceStore.save(original, fileURL: fileURL)
        SchedulerPersistenceStore.save(replacement, fileURL: fileURL)

        let loaded = SchedulerPersistenceStore.load(fileURL: fileURL)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "new")
    }
}
