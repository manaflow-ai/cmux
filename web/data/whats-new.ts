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
 * resolution on device, in order:
 * 1. `nativeEntryId` present in the installed binary's catalog: rendered
 *    natively.
 * 2. `webUrl` (cmux-owned https host only): rendered in an in-app webview,
 *    the fallback for binaries that predate the native page.
 * 3. Inline `features` rows (requires `title`).
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
  // binary catalog but stays hidden here until the per-computer connection
  // release it describes is actually out; add it to this list at release.
  visibleEntryIds: [],
  announcements: [],
};
