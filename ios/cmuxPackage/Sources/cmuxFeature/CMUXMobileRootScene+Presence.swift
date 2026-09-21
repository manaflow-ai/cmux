import CmuxMobileShell

extension CMUXMobileRootScene {
    @MainActor
    func makePresenceClient() -> PresenceClient? {
        guard let baseURL = PresenceClient.resolvedServiceBaseURL(isDevelopmentAuthChannel: auth.authEnvironment == .development) else { return nil }
        let coordinator = auth.coordinator
        let tokens = PresenceTokenSource(accessToken: { try? await coordinator.currentTokens().accessToken }, currentUserID: { await coordinator.currentUser?.id })
        return PresenceClient(serviceBaseURL: baseURL, tokenSource: tokens, teamIDProvider: { await coordinator.resolvedTeamID }, deviceIDProvider: { DeviceRegistryService.deviceID() }, instanceTagProvider: { MobileIOSBuildScope.current()?.value ?? "default" })
    }
}
