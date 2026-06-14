import CMUXAuthCore
import Testing
@testable import cmuxFeature

@Test func mobileAuthCompositionDefaultsDevBuildsToProductionAuth() {
    #expect(MobileAuthComposition.resolvedAuthEnvironment(
        isDevelopmentBuild: true,
        overrides: [:]
    ) == .production)
}

@Test func mobileAuthCompositionAllowsLocalDevAuthOverride() {
    #expect(MobileAuthComposition.resolvedAuthEnvironment(
        isDevelopmentBuild: true,
        overrides: ["CMUXAuthEnvironment": "local"]
    ) == .development)
}
