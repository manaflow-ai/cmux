import XCTest

/// Hosts (c9-ssh.md) on the mock HostsStore: the fixture SSH host lists,
/// and Add SSH Host saves a new host into the list.
@MainActor
final class NextHostsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testFixtureHostsList() {
        let app = NextUITest.launchShell(tab: "hosts")
        NextUITest.assertTabRoot(app, "hosts")
        XCTAssertTrue(NextUITest.element(app, "ssh.host.ssh-devbox").waitForExistence(timeout: 10))
    }

    func testAddSSHHostForm() {
        let app = NextUITest.launchShell(tab: "hosts")
        NextUITest.tap(app, "ssh.hosts.add")
        let addHost = app.buttons["Add SSH Host"].firstMatch
        XCTAssertTrue(addHost.waitForExistence(timeout: 5), "add menu has no Add SSH Host")
        addHost.tap()

        let save = NextUITest.element(app, "ssh.editor.save")
        XCTAssertTrue(save.waitForExistence(timeout: 10), "host editor did not open")
        XCTAssertFalse(save.isEnabled, "Add is enabled on an empty form")
        type("d3box", into: "ssh.editor.name", app)
        type("d3box.local", into: "ssh.editor.address", app)
        type("dev", into: "ssh.editor.user", app)
        XCTAssertTrue(NextUITest.wait(save, "enabled == true"), "Add stays disabled with name and address")
        save.tap()

        XCTAssertTrue(NextUITest.waitGone(save), "editor did not close after Add")
        let row = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'ssh.host.' AND label CONTAINS 'd3box'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the new host is not listed")
    }

    func testKeysScreenOpens() {
        let app = NextUITest.launchShell(tab: "hosts")
        NextUITest.tap(app, "ssh.hosts.keys")
        XCTAssertTrue(NextUITest.element(app, "ssh.keys.list").waitForExistence(timeout: 10))
    }

    private func type(_ text: String, into identifier: String, _ app: XCUIApplication) {
        let field = NextUITest.element(app, identifier)
        XCTAssertTrue(NextUITest.waitHittable(field), "\(identifier) missing")
        field.tap()
        field.typeText(text)
    }
}
