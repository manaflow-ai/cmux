// The update highlights contract (cx-ncc.45.5, data and flow owned by the updater lane:
// .cmux-scratch/hq-ff/updates/highlights-contract.md). Swift's `UpdateHighlights` (Codable,
// camelCase) arrives as this JSON through the card and popover mount point. The Updated card
// (after an update) and the update-ready popover (before one) read the same shape.
import type { WhatsNewCategory } from "./types";

export interface UpdateHighlightItem {
  id: string;
  /** Already localized. */
  title: string;
  /** One line, already localized; absent when the source has none. */
  summary?: string | null;
  category: WhatsNewCategory;
  /** An SF Symbol name when the source names one; the web views do not draw it. */
  symbol?: string | null;
  /** The change's picture, inlined and checked by the host (`data:` URLs only); absent without one. */
  media?: UpdateHighlightMedia | null;
}

export interface UpdateHighlightMedia {
  light: string;
  dark: string;
  /** Already localized. */
  alt: string;
}

export interface UpdateHighlights {
  /** The staged (popover) or installed (card) display version. */
  version: string;
  build: string;
  fromVersion: string;
  fromBuild: string;
  date?: string | null;
  /** When the build was made, an ISO instant ("2026-10-26T19:38:52Z"); absent from an older host or
      notes, and then only `date` is known. */
  builtAt?: string | null;
  /** The commit the build was cut from (the notes' `head`); absent from older notes. */
  head?: string | null;
  /** Builds taken off the feed (its pulled.json): never counted as newer. Absent from an older host. */
  pulled?: string[] | null;
  source: "whatsNew" | "highlights" | "summary" | "appcast" | "none";
  language: string;
  /** At most 3, in display order. */
  items: UpdateHighlightItem[];
  /** Items not shown. */
  moreCount: number;
  /** Every change after `items` (the popover scrolls to the whole list); absent from an older host. */
  rest?: UpdateHighlightItem[] | null;
  changelog: { from: string; to: string };
}

/** What the card and popover ask the host to do (the mount point's bridge). */
export interface UpdateSurfaceActions {
  /** "See What's New" / "See all changes": `updates.openChangelog` (ChangelogPageTab.open(from, to)). */
  openChangelog(): void;
  /** The card's x: hides the card for this version. */
  dismiss?(): void;
}
