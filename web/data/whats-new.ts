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
 * Edits to this file are code-reviewed; the route validates it at module
 * load so a malformed entry fails the build, never the client.
 */

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
}

export interface WhatsNewList {
  visibleEntryIds: string[];
  announcements: WhatsNewAnnouncement[];
}

export const whatsNewList: WhatsNewList = {
  // Binary catalog ids the app may show. "connections.v1" ships in the iOS
  // binary catalog, so only binaries that carry the page can render it; the
  // list needs no extra version gating for binary pages. Remove an id here
  // to hide its page remotely.
  visibleEntryIds: ["connections.v1"],
  announcements: [],
};
