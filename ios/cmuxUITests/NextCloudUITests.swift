import XCTest

/// Cloud tab (c12-cloud.md section 5) on `MockCloudMachineSource`: the
/// sample machines list, and New Machine creates one through the sheet.
@MainActor
final class NextCloudUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    /// The mock's running `devbox` and paused `scratch` machines are listed.
    func testMockMachinesList() {
        let app = NextUITest.launchShell(tab: "cloud")
        NextUITest.assertTabRoot(app, "cloud")
        XCTAssertTrue(NextUITest.element(app, "cloud.machine.vm_mockdevbox0000000001").waitForExistence(timeout: 10),
                      "devbox is not listed")
        XCTAssertTrue(NextUITest.element(app, "cloud.machine.vm_mockscratch00000002").exists, "scratch is not listed")
    }

    /// New Machine -> name -> Create closes the sheet and adds a row.
    func testCreateMachineOnMock() {
        let app = NextUITest.launchShell(tab: "cloud")
        NextUITest.assertTabRoot(app, "cloud")
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'cloud.machine.'"))
        XCTAssertTrue(NextUITest.element(app, "cloud.machine.vm_mockdevbox0000000001").waitForExistence(timeout: 10))
        let before = rows.count
        NextUITest.tap(app, "cloud.new")
        let name = NextUITest.element(app, "cloud.create.name")
        XCTAssertTrue(NextUITest.waitHittable(name), "create sheet did not open")
        name.tap()
        name.typeText("d3-uitest")
        NextUITest.tap(app, "cloud.create.confirm")
        XCTAssertTrue(NextUITest.waitGone(name), "create sheet did not close")
        XCTAssertTrue(NextUITest.wait(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'cloud.machine.' AND label CONTAINS 'd3-uitest'")).firstMatch,
            "exists == true"), "the new machine is not listed")
        XCTAssertGreaterThan(rows.count, before)
    }
}
