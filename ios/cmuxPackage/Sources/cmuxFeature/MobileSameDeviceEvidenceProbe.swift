import CmuxMobileShell
import Foundation

/// Same-device evidence for device-registry id resolution (see
/// `SameDeviceEvidence.swift` in CmuxMobileShell for the upgrade/restore
/// matrix). The artifacts probed are LEGACY iroh-era install markers: they
/// prove "this install continues on the same hardware" for devices that ran
/// an iroh build, which is exactly the population whose device-id mirror may
/// be adopted. Fresh installs never consult evidence.
enum MobileSameDeviceEvidenceProbe {
    /// Production resolves through the ThisDeviceOnly Keychain marker; DEBUG
    /// builds kept identities in a development FILE store instead (unsigned
    /// dev builds cannot always read Keychain), so continuity there is any
    /// record in that store.
    nonisolated static func current(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> any SameDeviceEvidenceProbing {
        #if DEBUG
        DevelopmentFileEvidenceProbe(bundleIdentifier: bundleIdentifier)
        #else
        IrohEndpointIdentityEvidenceProbe()
        #endif
    }
}

#if DEBUG
/// DEBUG same-device evidence: any record in the legacy development identity
/// file store proves continuity. The filesystem is always readable, so the
/// verdict is two-state (never `.unavailable`).
struct DevelopmentFileEvidenceProbe: SameDeviceEvidenceProbing {
    let bundleIdentifier: String?

    func probe() -> SameDeviceEvidence {
        #if targetEnvironment(simulator)
        // The dev launcher seeds a deterministic UserDefaults mirror because
        // unsigned Simulator apps cannot read Keychain. A Simulator cannot be
        // the destination of an iPhone backup restore, so that mirror is local
        // same-device evidence even before any identity file exists.
        return .present
        #else
        let directory = Self.legacyIdentityDirectory(bundleIdentifier: bundleIdentifier)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return entries.isEmpty ? .absent : .present
        #endif
    }

    /// Mirrors the iroh-era `developmentStoreDirectory(service: "identity")`
    /// layout so upgrading dev installs keep their device id.
    static func legacyIdentityDirectory(bundleIdentifier: String?) -> URL {
        let rawBundleScope = bundleIdentifier ?? "dev.cmux.ios.debug"
        let bundleScope = String(rawBundleScope.map { character in
            character.isASCII
                && (character.isLetter
                    || character.isNumber
                    || ["-", ".", "_"].contains(character))
                ? character
                : "_"
        })
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport
            .appendingPathComponent("iroh-debug", isDirectory: true)
            .appendingPathComponent(bundleScope, isDirectory: true)
            .appendingPathComponent("identity", isDirectory: true)
    }
}
#endif
