import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct BrowserWebExtensionDiscoveryServiceTests {
    @Test
    func concurrentDiscoveriesShareOnePluginkitRun() async {
        let runner = BrowserWebExtensionDiscoveryRunner()
        let service = BrowserWebExtensionDiscoveryService {
            await runner.run()
        }

        let firstDiscovery = Task {
            await service.discoverInstalledSafariExtensions()
        }
        await runner.waitUntilStarted()
        let secondDiscovery = Task {
            await service.discoverInstalledSafariExtensions()
        }
        await Task.yield()
        await runner.release()

        let firstCandidates = await firstDiscovery.value
        let secondCandidates = await secondDiscovery.value

        #expect(await runner.invocationCount() == 1)
        #expect(firstCandidates == secondCandidates)
        #expect(firstCandidates.map(\.id) == ["com.example.extension"])
    }

    @Test
    func pluginkitParserSelectsHighestRegisteredVersionDeterministically() {
        let output = """
        +    com.example.extension(1.9.0)  OLD  2026-01-01 00:00:00 +0000  /Applications/Example 1.9.app/Contents/PlugIns/Example.appex
        +    com.example.extension(1.10.0)  NEW  2026-07-01 00:00:00 +0000  /Applications/Example 1.10.app/Contents/PlugIns/Example.appex
        """

        let candidate = BrowserWebExtensionDiscoveryService.parse(pluginkitOutput: output).first

        #expect(candidate?.version == "1.10.0")
        #expect(candidate?.path == "/Applications/Example 1.10.app/Contents/PlugIns/Example.appex")
    }

    @Test
    func pluginkitParserHandlesVerboseSpaceSeparatedOutput() {
        let output = """
        +    com.bitwarden.desktop.safari(2026.7.0)  01234567-89AB-CDEF-0123-456789ABCDEF  2026-07-09 03:21:09 +0000  /Applications/Bitwarden.app/Contents/PlugIns/safari.appex
        -    com.example.disabled(1.2.3)\tAAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\t2026-07-09 03:22:09 +0000\t/Applications/Example App.app/Contents/PlugIns/Example Extension.appex
        """

        let candidates = BrowserWebExtensionDiscoveryService.parse(pluginkitOutput: output)

        #expect(candidates.map(\.id) == [
            "com.bitwarden.desktop.safari",
            "com.example.disabled",
        ])
        #expect(candidates.first?.version == "2026.7.0")
        #expect(candidates.first?.path == "/Applications/Bitwarden.app/Contents/PlugIns/safari.appex")
        #expect(candidates.last?.version == "1.2.3")
        #expect(candidates.last?.path == "/Applications/Example App.app/Contents/PlugIns/Example Extension.appex")
    }
}

private actor BrowserWebExtensionDiscoveryRunner {
    private var calls = 0
    private var didStart = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func run() async -> String {
        calls += 1
        didStart = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()

        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        return "+ com.example.extension(1.0) /Applications/Example.app/Contents/PlugIns/Example.appex"
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    func invocationCount() -> Int {
        calls
    }
}
