// Wire types of `cmux.changelog.*` (R114, plans/cmux-next/updates-and-announcements.md 2). The
// Swift ChangelogPageProvider serves verified, signed release notes (`ReleaseNotes`, encoded as
// is); actions are already filtered to the app's compiled-in allow-list.

export const ChangelogOps = { list: "cmux.changelog.list", get: "cmux.changelog.get" } as const;
/** Runs a highlight's "Try it" (the host admits only allow-listed actions). */
export const ACTION_RUN = "cmux.app.action.run";

export interface IndexEntry {
  build: string;
  shortVersion: string;
  date: string;
  highlights: number;
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

/** The page design (Debug Settings `whatsNew.design`, route `design=`): the Ledger is the default
    (u5099, design/changelog-variations-gallery #01). */
export type ChangelogDesign = "ledger" | "journal" | "rail" | "digest";
