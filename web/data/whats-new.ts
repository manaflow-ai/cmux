/**
 * The remote What's New list served by GET /api/whats-new.
 *
 * This list is the authoritative visibility switch for the What's New pages
 * compiled into cmux iOS binaries: the app renders a binary page only when
 * its id appears in `visibleEntryIds`, so a bad or mistimed page can be
 * hidden remotely after release. Devices cache the last fetched list and the
 * cache wins while offline; a device that has never fetched the list shows
 * its binary pages (fail-open to binary truth).
 *
 * `announcements` are remote-only entries (service announcements, backend
 * news). `minVersion`/`maxVersion` are REQUIRED inclusive bounds compared
 * against the app's short version string (dotted-numeric compare). Content
 * resolution on device:
 * 1. `nativeEntryId` marks the announcement as a duplicate of that binary
 *    page: devices where the page is remotely visible drop the announcement
 *    (the content already shows natively), all others use the fallbacks.
 * 2. `webUrl` (cmux-owned https host only): rendered in an in-app webview.
 * 3. Inline `features` rows. A `title` is required whenever fallback
 *    content exists.
 *
 * Channel targeting: every entry and announcement has an audience of build
 * channels (`MobileBuildType.token` values). When `channels` /
 * `entryChannels` is omitted the client applies its default — the team lanes
 * only ("dev", "beta", "internal") — so nothing here reaches the official
 * App Store app ("prod") or demo builds unless it EXPLICITLY lists that
 * channel. What's New announces team-lane features and contributed to the
 * App Store app's Guideline 2.2 rejection (submission 591a59e6); listing
 * "prod" on a specific entry is the deliberate opt-in that re-enables it for
 * official builds, with no binary change. A declared list REPLACES the
 * default, so it can narrow as well as widen. Old clients (before channel
 * filtering shipped) ignore these fields and behave as before.
 *
 * Edits to this file are code-reviewed; the route validates it at module
 * load so a malformed entry fails the build, never the client.
 */

/**
 * One canonical vocabulary with the iOS client's `MobileBuildType.token`:
 * "prod" is the official App Store app (bundle id com.cmux.app), "beta" is
 * dev.cmux.app.beta, "internal" is dev.cmux.app.internal, "dev" is local
 * DEBUG builds, "demo" is the controlled-demo distribution.
 */
export type WhatsNewChannel = "dev" | "beta" | "internal" | "demo" | "prod";

export interface WhatsNewAnnouncementFeature {
  /** SF Symbol name; the app defaults to "megaphone" when omitted. */
  symbol?: string;
  title: string;
  detail: string;
}

export interface WhatsNewAnnouncement {
  id: string;
  minVersion: string;
  maxVersion: string;
  title?: string;
  releaseLabel?: string;
  features?: WhatsNewAnnouncementFeature[];
  nativeEntryId?: string;
  webUrl?: string;
  /**
   * Build channels this announcement targets. Omitted = the client default
   * (team lanes only, never "prod"/"demo").
   */
  channels?: WhatsNewChannel[];
}

export interface WhatsNewList {
  visibleEntryIds: string[];
  /**
   * Per-binary-entry channel targeting, keyed by a `visibleEntryIds` id.
   * When present for an entry it REPLACES that entry's compiled-in channel
   * declaration on device; absent means the compiled-in declaration
   * (usually the team-lanes default) applies. This is the remote switch
   * that can opt one binary page into the official App Store channel.
   */
  entryChannels?: Partial<Record<string, WhatsNewChannel[]>>;
  announcements: WhatsNewAnnouncement[];
}

export const whatsNewList: WhatsNewList = {
  // Binary catalog ids the app may show. "connections.v1" ships in the iOS
  // binary catalog, so only binaries that carry the page can render it; the
  // list needs no extra version gating for binary pages. Remove an id here
  // to hide its page remotely. With no `entryChannels` override, every id
  // keeps its compiled-in audience — team lanes only — so none of this
  // renders on the official App Store app. To show connections.v1 there:
  // entryChannels: { "connections.v1": ["dev", "beta", "internal", "prod"] }.
  visibleEntryIds: ["connections.v1"],
  announcements: [],
};
