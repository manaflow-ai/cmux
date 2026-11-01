// Wire types of `cmux.changelog.*` (R114, plans/cmux-next/updates-and-announcements.md 2). The
// Swift ChangelogPageProvider serves verified, signed release notes (`ReleaseNotes`, encoded as
// is); actions are already filtered to the app's compiled-in allow-list.

export const ChangelogOps = {
  list: "cmux.changelog.list",
  get: "cmux.changelog.get",
  reel: "cmux.changelog.reel",
} as const;
/** Runs a highlight's "Try it" (the host admits only allow-listed actions). */
export const ACTION_RUN = "cmux.app.action.run";

export interface IndexEntry {
  build: string;
  shortVersion: string;
  date: string;
  highlights: number;
  /** The commit the build was cut from; older indexes lack it. */
  head?: string;
}

export interface ListResult {
  current: string;
  builds: IndexEntry[];
}

/** A highlight's picture or clip. The page shows it only from a source its CSP admits (data:, same origin). */
export interface HighlightMedia {
  url: string;
  sha256?: string;
  kind: string;
  alt: string;
}

export interface Highlight {
  id: string;
  title: string;
  body: string;
  media?: HighlightMedia[];
  action?: { id: string; title: string };
  /** The highlight file's category; absent reads as new. */
  category?: WhatsNewCategory;
}

/** Text per Apple language code (`WhatsNewText`); `en` is always there. */
export type LocalizedText = Record<string, string>;

export type WhatsNewCategory = "new" | "improved" | "fixed" | "security";

/** One entry of a release's What's New document (`schemas/whats-new/v1.schema.json`). */
export interface WhatsNewEntry {
  id: string;
  category: WhatsNewCategory;
  title: LocalizedText;
  summary: LocalizedText;
  media?: { kind: string; light: string; dark: string; alt: LocalizedText };
  tryIt?: { action?: string; deeplink?: string };
  /** Optional GitHub pull request URL shown as the shared colored PR chip. */
  pr?: string;
  docs?: string;
}

export interface WhatsNewDocument {
  version: string;
  channel: "stable" | "rc" | "nightly";
  date: string;
  headline: LocalizedText;
  entries: WhatsNewEntry[];
}

/** One line of the short user-facing changelog (`new`, `fixed`, `changed`). */
export interface SummaryLine {
  group: string;
  title: string;
}

/** One change of a build: its title, author and pull request (the provider fills these from the
    commit subjects when older notes carry none, `ReleaseNotes.changeItems`). */
export interface ChangeItem {
  title: string;
  author?: string;
  pr?: number;
  /** Every file the commit touches is CI or tooling (release-notes.py tooling_only): internal
      whatever its subject says. Absent in notes published before the flag. */
  internal?: boolean;
}

export interface ReleaseNotes {
  build: string;
  shortVersion: string;
  date: string;
  highlights: Highlight[];
  changes: string[];
  items?: ChangeItem[];
  whatsNew?: WhatsNewDocument;
  summary?: SummaryLine[];
}

/** `cmux.changelog.reel {build}`: the build's nightly reel, a video the page links (never in the
    signed notes; the host reads the build's reel.json, ReleaseMediaStore.swift), else null. */
export interface ReelResult {
  url: string | null;
}

/** The page design (Debug Settings `whatsNew.design`, route `design=`): the What's New sheet is the
    default (2026-10-31, msg 19251, cmux-shots/whatsnew-variations); the Ledger (u5099) before it. */
export type ChangelogDesign = "sheet" | "ledger" | "journal" | "rail" | "digest";
/** How the update's news shows its clips (SpanNews.tsx; the route's `news=`, for the gallery): each
    clip beside its words, alternating sides (default); one under another; two-up cards; or the
    lead row the clips replaced. */
export type NewsLayout = "alternate" | "stack" | "grid" | "lead";
