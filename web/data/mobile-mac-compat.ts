/**
 * The minimum-Mac-version list served by GET /api/mobile-mac-compat.
 *
 * cmux iOS consumes this list to decide whether a connected Mac (stable or
 * nightly channel) is new enough to talk to. `entries` are tiers keyed by an
 * inclusive minimum iOS marketing version: the tier with the greatest
 * `minIOSVersion` <= the app's version wins, and an iOS version below every
 * tier is unconstrained (fail-open: an app whose version the server does not
 * cover gets NO Mac version limit rather than an accidental block-everything).
 * The initial tier starts at 1.0.0 so it covers every current lane — the
 * App Store app ships as 1.0.0 and the beta lane as 1.0.4 — and constrains
 * them to the next stable release (0.64.23; current stable is 0.64.22) and
 * the next nightly (the newest published nightly build at authoring time is
 * 3345650013201, so minBuild 3345650013202 means "any nightly published
 * after this was written"). Binaries built before the gate shipped ignore
 * this list entirely, so covering their versions is harmless.
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
  /** Inclusive minimum stable-channel Mac marketing version, dotted numeric. */
  stableMinVersion: string;
  /** Minimum nightly-channel Mac build. Omitted = nightly channel unconstrained for this tier. */
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
      stableMinVersion: "0.64.23",
      nightly: { minBaseVersion: "0.64.22", minBuild: "3345650013202" },
    },
  ],
};
