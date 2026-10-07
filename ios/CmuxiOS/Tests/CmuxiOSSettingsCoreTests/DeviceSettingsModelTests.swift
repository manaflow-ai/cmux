import CmuxiOSFeatureKit
import CmuxiOSSettingsCore
import CmuxLink
import Testing

@MainActor
@Suite struct DeviceSettingsModelTests {
    /// Starts observing and waits until the first registry snapshot and the
    /// link badges arrived.
    private func observing(_ model: DeviceSettingsModel, badges: Bool = true) async -> Task<Void, Never> {
        let task = Task { await model.observe() }
        while model.devices.isEmpty || (badges && model.badges.isEmpty) { await Task.yield() }
        return task
    }

    @Test func mirrorsRegistryAndBadges() async {
        let model = DeviceSettingsModel(registry: MockDeviceRegistry(), links: MockLinkDiagnosticsSource())
        let task = await observing(model)
        defer { task.cancel() }
        #expect(model.sections.first?.devices.first?.isThisDevice == true)
        let studio = MockFixtures.studio.rawValue
        #expect(model.badge(for: studio)?.path.kind == .direct)
        #expect(model.badge(for: studio)?.rttMilliseconds == 12)
        #expect(model.badge(for: MockFixtures.mini.rawValue)?.shouldShow == true)
    }

    @Test func renameCommitsTrimmedName() async {
        let registry = MockDeviceRegistry()
        let model = DeviceSettingsModel(registry: registry, links: nil)
        let task = await observing(model, badges: false)
        defer { task.cancel() }
        let studio = MockFixtures.studio.rawValue
        #expect(await model.rename(studio, to: "  Studio  "))
        #expect(await registry.hub.current.value.first { $0.id == studio }?.name == "Studio")
        #expect(model.actionError == nil)
    }

    @Test func invalidNameIsRejectedLocally() async {
        let model = DeviceSettingsModel(registry: MockDeviceRegistry(), links: nil)
        let task = await observing(model, badges: false)
        defer { task.cancel() }
        #expect(!(await model.rename(MockFixtures.studio.rawValue, to: "  ")))
        #expect(model.actionError == .invalidName(.empty))
    }

    @Test func revokeRemovesFromTheListButNotThisDevice() async {
        let registry = MockDeviceRegistry()
        let model = DeviceSettingsModel(registry: registry, links: nil)
        let task = await observing(model, badges: false)
        defer { task.cancel() }
        let mini = MockFixtures.mini.rawValue
        #expect(await model.revoke(mini))
        while model.device(mini) != nil { await Task.yield() }
        #expect(!model.sections.flatMap(\.devices).contains { $0.id == mini })
        #expect(!(await model.revoke("dev-phone")))
        #expect(model.actionError == .cannotRemoveThisDevice)
    }

    @Test func offlineRegistryRefusesWithoutSending() async {
        let registry = MockDeviceRegistry()
        let model = DeviceSettingsModel(registry: registry, links: nil)
        let task = await observing(model, badges: false)
        defer { task.cancel() }
        await registry.hub.setConnection(.offline(reason: nil))
        while model.connection.isLive { await Task.yield() }
        let before = await registry.hub.current.revision
        #expect(!(await model.revoke(MockFixtures.mini.rawValue)))
        #expect(model.actionError == .offline)
        #expect(await registry.hub.current.revision == before)
    }

    @Test func unknownDeviceIsNotFound() async {
        let registry = MockDeviceRegistry(devices: [
            DeviceRecord(id: "me", name: "iPhone", platform: .iPhone, trust: .trusted, isThisDevice: true),
        ])
        let model = DeviceSettingsModel(registry: registry, links: nil)
        let task = await observing(model, badges: false)
        defer { task.cancel() }
        #expect(!(await model.rename("ghost", to: "Name")))
        #expect(model.actionError == .notFound)
    }
}
