// Wire types of `cmux.changelog.*` (R114, plans/cmux-next/updates-and-announcements.md 2). The
// Swift ChangelogPageProvider serves verified, signed release notes; actions are already filtered
// to the app's compiled-in allow-list.

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

export interface Highlight {
  id: string;
  title: string;
  body: string;
  action?: { id: string; title: string };
}

export interface ReleaseNotes {
  build: string;
  shortVersion: string;
  date: string;
  highlights: Highlight[];
  changes: string[];
}
