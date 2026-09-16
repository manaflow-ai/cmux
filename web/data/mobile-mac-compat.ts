/**
 * The minimum-Mac-version list served by GET /api/mobile-mac-compat.
 *
 * cmux iOS consumes this list to decide whether a connected Mac (stable or
 * nightly channel) is new enough to talk to. `entries` are tiers keyed by an
 * inclusive minimum iOS marketing version: the tier with the greatest
 * `minIOSVersion` <= the app's version wins, and an iOS version below every
 * tier is unconstrained (fail-open: an app whose version the server does not
 * cover gets NO Mac version limit rather than an accidental block-everything).
 * The first tier starts at 1.0.0 so it covers the App Store lane and older
 * TestFlight builds. The tiers track the protocol milestones in git history:
 * Tailscale pairing became usable with 0.64.17, authenticated Iroh with
 * 0.64.20, and the rebuilt Iroh transport with 0.64.23. The App Store
 * marketing version remains 1.0.0, so its build kind has to carry the
 * stricter floor while older TestFlight versions retain the Mac releases they
 * can actually use. In particular, BETA 1.0.4 build 20260817224846 is the
 * last build that works with older Macs, while the later INTERNAL 1.0.4 cut
 * uses the rebuilt transport and needs 0.64.23.
 * Binaries built before the gate shipped ignore this list entirely, so
 * covering their versions is harmless.
 *
 * Nightly builds are versioned `<base>-nightly.<run id><attempt>` by
 * .github/workflows/nightly.yml, so build counters are globally monotonic.
 *
 * Devices cache the last fetched list per origin and fall back to a
 * compiled-in default when they have never fetched. That fallback
 * (`MobileMacCompatPolicy.baked` in
 * Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileMacCompatPolicy.swift)
 * mirrors the initial entries here; keep the two in sync when editing.
 * Edits to this file are code-reviewed; the route validates it at module
 * load so a malformed entry fails the build, never the client.
 */

export interface MobileMacCompatNightlyRequirement {
  /** Nightly base marketing version (the X.Y.Z in X.Y.Z-nightly.N), dotted numeric. */
  minBaseVersion: string;
  /** Minimum nightly build counter N, digits only. Nightly builds stamp CFBundleShortVersionString as `<base>-nightly.<GITHUB_RUN_ID><2-digit attempt>`, so N is globally monotonic. */
  minBuild: string;
}

export interface MobileMacCompatRequirement {
  /** Minimums for one iOS distribution build kind. */
  stableMinVersion: string;
  nightly?: MobileMacCompatNightlyRequirement;
}

export interface MobileMacCompatEntry {
  /** Inclusive minimum iOS marketing version this tier applies to. The tier with the greatest minIOSVersion <= the app's version wins; an app below every tier is unconstrained (fail-open). */
  minIOSVersion: string;
  /**
   * Optional inclusive maximum iOS marketing version. Omitted = open-ended,
   * so ONE tier captures every current and future version from its minimum
   * upward without listing each patch release. Set it to bound a tier
   * (min "1.0.0" + max "1.0.99" covers all of 1.0.x; min == max pinpoints
   * one version). An app above the winning tier's maximum gets NO limit
   * (fail-open), same as an app below every tier.
   */
  maxIOSVersion?: string;
  /** Requirements keyed by iOS build kind (`dev`, `beta`, `internal`, `demo`, `prod`). */
  buildKinds?: Record<string, MobileMacCompatRequirement>;
  /** @deprecated legacy single-policy fields, accepted during rollout. */
  stableMinVersion?: string;
  nightly?: MobileMacCompatNightlyRequirement;
}

export interface MobileMacCompatList {
  downloads: {
    /** Where to get the newest stable Mac build. */
    stable: string;
    /** Where to get the newest nightly Mac build. */
    nightly: string;
  };
  entries: MobileMacCompatEntry[];
}

export const mobileMacCompatList: MobileMacCompatList = {
  downloads: {
    // Keep in sync with DOWNLOAD_URL in web/app/lib/download.ts (data/ does
    // not import from app/lib, so the value is duplicated deliberately).
    stable:
      "https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg",
    nightly: "https://github.com/manaflow-ai/cmux/releases/tag/nightly",
  },
  entries: [
    {
      minIOSVersion: "1.0.0",
      maxIOSVersion: "1.0.3",
      // Legacy fields mirror prod while older iOS clients are still deployed.
      stableMinVersion: "0.64.23",
      nightly: { minBaseVersion: "0.64.22", minBuild: "3345650013202" },
      buildKinds: {
        dev: { stableMinVersion: "0.64.0" },
        beta: {
          stableMinVersion: "0.64.17",
          nightly: { minBaseVersion: "0.64.22", minBuild: "3345650013202" },
        },
        internal: {
          stableMinVersion: "0.64.17",
          nightly: { minBaseVersion: "0.64.22", minBuild: "3345650013202" },
        },
        demo: { stableMinVersion: "0.64.17" },
        prod: {
          stableMinVersion: "0.64.23",
          nightly: { minBaseVersion: "0.64.22", minBuild: "3345650013202" },
        },
      },
    },
    {
      minIOSVersion: "1.0.4",
      maxIOSVersion: "1.0.4",
      stableMinVersion: "0.64.23",
      nightly: { minBaseVersion: "0.64.22", minBuild: "3345650013202" },
      buildKinds: {
        dev: { stableMinVersion: "0.64.0" },
        beta: {
          stableMinVersion: "0.64.20",
          nightly: { minBaseVersion: "0.64.22", minBuild: "3345650013202" },
        },
        internal: {
          stableMinVersion: "0.64.23",
          nightly: { minBaseVersion: "0.64.22", minBuild: "3345650013202" },
        },
        demo: { stableMinVersion: "0.64.20" },
        prod: {
          stableMinVersion: "0.64.23",
          nightly: { minBaseVersion: "0.64.22", minBuild: "3345650013202" },
        },
      },
    },
    {
      minIOSVersion: "1.0.5",
      stableMinVersion: "0.64.23",
      nightly: { minBaseVersion: "0.64.22", minBuild: "3345650013202" },
      buildKinds: {
        dev: { stableMinVersion: "0.64.0" },
        beta: {
          stableMinVersion: "0.64.23",
          nightly: { minBaseVersion: "0.64.22", minBuild: "3345650013202" },
        },
        internal: {
          stableMinVersion: "0.64.23",
          nightly: { minBaseVersion: "0.64.22", minBuild: "3345650013202" },
        },
        demo: { stableMinVersion: "0.64.23" },
        prod: {
          stableMinVersion: "0.64.23",
          nightly: { minBaseVersion: "0.64.22", minBuild: "3345650013202" },
        },
      },
    },
  ],
};
