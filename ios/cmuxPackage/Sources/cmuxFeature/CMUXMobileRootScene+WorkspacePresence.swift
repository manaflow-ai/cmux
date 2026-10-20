import CmuxMobileShell

extension CMUXMobileRootScene {
    @MainActor
    func makeWorkspacePresenceAnnouncer() -> MobileWorkspacePresenceAnnouncer? {
        guard let baseURL = PresenceClient.resolvedServiceBaseURL(isDevelopmentAuthChannel: auth.authEnvironment == .development) else { return nil }
        let coordinator = auth.coordinator
        let tokens = PresenceTokenSource(accessToken: { try? await coordinator.currentTokens().accessToken }, currentUserID: { await coordinator.currentUser?.id })
        return MobileWorkspacePresenceAnnouncer(serviceBaseURL: baseURL, tokenSource: tokens, teamIDProvider: { await coordinator.resolvedTeamID })
    }
}
