#if DEBUG
import CmuxAuthRuntime
import CmuxNextTransport
import Foundation
import IrohLib
import Observation
import OSLog
import Security

extension NextTransportDialClient {
    private static let pushedRelayDefaultsKey =
        "dev.cmux.nextTransport.ios.pushedRelayCredential"
    private static let pushedRelayKeychainAccount = "pushed-relay"

    /// A ctl-lane `opt.relay-credential` push applies IMMEDIATELY to the
    /// live endpoint (make-before-break) and persists, so neither a quiet
    /// session nor a relaunch waits for the next dial to use it.
    func storePushedCredential(url: String, token: String) async {
        guard IrohSubstrate().tokenEndpointId(token) == identity.publicKeyData else {
            log("pushed credential bound to a DIFFERENT device; ignoring")
            return
        }
        pendingRelay = (url, token)
        let generation = lifecycleGeneration
        let keychain = NextTransportIdentityKeychain(logger: Self.logger)
        let defaults = NextTransportDefaultsBox(defaults)
        let service = pushedRelayKeychainService
        let account = Self.pushedRelayKeychainAccount
        let legacyKey = Self.pushedRelayDefaultsKey
        let write = credentialPersistence.enqueue(key: account) {
            await keychain.persistRelay(
                url: url, token: token, service: service, account: account,
                defaults: defaults, legacyKey: legacyKey)
        }
        if !(await write.value) {
            log("pushed credential keychain write failed; keeping session-only")
        }
        guard generation == lifecycleGeneration, !Task.isCancelled,
            pendingRelay?.url == url, pendingRelay?.token == token else { return }
        await applyPendingRelayCredential()
    }

    func applyPendingRelayCredential() async {
        guard let pending = pendingRelay, pending.token != appliedRelayToken,
            let endpoint
        else { return }
        do {
            // Insert-alone handoff (never removeRelay first), so live
            // sessions ride the fresh credential zero-gap.
            try await endpoint.insertRelay(
                config: RelayConfig(url: pending.url, authToken: pending.token))
            appliedRelayToken = pending.token
            log("relay credential rotated in, zero-gap")
        } catch {
            log("credential rotation failed", error: error)
        }
    }

    static func persistedPushedCredential(
        defaults: UserDefaults, keychainService: String
    ) -> (url: String, token: String)? {
        let storedData = NextTransportIdentityKeychain(logger: Self.logger).read(
            service: keychainService, account: pushedRelayKeychainAccount)
        let stored: [String: String]?
        if let storedData {
            stored = try? JSONDecoder().decode([String: String].self, from: storedData)
        } else if let legacy = defaults.dictionary(forKey: pushedRelayDefaultsKey),
            let url = legacy["url"] as? String, let token = legacy["token"] as? String
        {
            // Migrate the legacy value only after a protected write succeeds.
            let candidate = ["url": url, "token": token]
            let migrated = if let data = try? JSONEncoder().encode(candidate),
                NextTransportIdentityKeychain(logger: Self.logger).write(
                    data, service: keychainService, account: pushedRelayKeychainAccount)
            { true } else { false }
            // Remove the legacy plaintext slot even if the protected store is
            // temporarily unavailable; retaining a secret in preferences is
            // a worse failure than requiring a fresh push next launch.
            defaults.removeObject(forKey: pushedRelayDefaultsKey)
            stored = migrated ? candidate : nil
        } else {
            stored = nil
        }
        guard let stored, let url = stored["url"], let token = stored["token"],
            let expiry = IrohSubstrate().tokenExpiry(token),
            expiry > Int64(Date().timeIntervalSince1970)
        else { return nil }
        return (url, token)
    }

    /// Self-minted rotation driven by the credentials' OWN expiries through
    /// `RelayCredentialSchedule` (earliest `expiresAt` minus lead, plus a
    /// small random jitter so a fleet of clients never re-mints in
    /// lockstep), mirroring the host runtime's renew loop: insert-alone
    /// handoff (never removeRelay first), so live sessions ride the fresh
    /// credential zero-gap. Also heals a LAN-only boot: once the web API is
    /// reachable and the session signed in, the first successful mint
    /// inserts the relay into the running endpoint.
    func startCredentialRenewal() {
        guard renewTask == nil, broker != nil else { return }
        let sleep = self.sleep
        renewTask = Task { [weak self] in
            while !Task.isCancelled {
                // Weak read for the schedule and NO strong self across the
                // sleep, so the loop ends on its own at the tick after the
                // client is released.
                guard let delay = await self?.nextRenewalDelay() else { return }
                do {
                    try await sleep(.seconds(delay))
                } catch {
                    return  // cancelled
                }
                guard let self, !Task.isCancelled else { return }
                await self.renewSelfMintedCredentials()
            }
        }
    }

    /// Seconds until the next renewal should fire, from the installed
    /// credentials' expiries (fallback cadence when none carry one).
    private func nextRenewalDelay() -> Int64 {
        if let renewalRetryDelaySeconds { return renewalRetryDelaySeconds }
        let now = Int64(Date().timeIntervalSince1970)
        let jitter = Int64.random(in: 0...30)
        guard
            let target = RelayCredentialSchedule().nextRefresh(
                credentials: mintedCredentials, now: now, jitterSeconds: jitter)
        else {
            // Nothing minted yet (LAN-only boot): retry on the fallback
            // cadence so the first reachable mint heals the relay map.
            return RelayCredentialSchedule.fallbackIntervalSeconds - jitter
        }
        return max(target - now, RelayCredentialSchedule.minimumDelaySeconds)
    }

    private func renewSelfMintedCredentials() async {
        guard let broker, let endpoint else { return }
        let renewStart = ContinuousClock.now
        do {
            let fresh = try await broker.mint(preferredUrl: hostRelayURL)
            for credential in fresh {
                try await endpoint.insertRelay(
                    config: RelayConfig(url: credential.relayUrl, authToken: credential.token))
            }
            mintedCredentials = fresh
            renewalRetryDelaySeconds = nil
            appliedRelayToken = fresh.first?.token ?? appliedRelayToken
            let expiry = fresh.first?.expiresAt
            log(
                """
                self-minted relay credentials rotated zero-gap (\(fresh.count) relays, \
                tokenExp \(expiry.map(String.init) ?? "unparsed"), \
                \(Self.elapsedMs(since: renewStart))ms)
                """)
        } catch {
            renewalRetryDelaySeconds = renewalRetryPolicy.nextDelay(
                after: renewalRetryDelaySeconds)
            log(
                "credential renewal failed after \(Self.elapsedMs(since: renewStart))ms",
                error: error)
        }
    }

}
#endif
