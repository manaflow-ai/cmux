// A nightly digest built from summary lines carries each line as both title and summary
// (scripts/cmux-next/release-notes.py). The page must show the line once, not "Title  Title".
import { expect, test } from "bun:test";
import { releaseView } from "../src/pages/changelog/model";
import type { ReleaseNotes, WhatsNewEntry } from "../src/pages/changelog/types";

function entry(id: string, title: string, summary: string): WhatsNewEntry {
  return { id, category: "new", title: { en: title }, summary: { en: summary } };
}

function notes(entries: WhatsNewEntry[]): ReleaseNotes {
  return {
    build: "3911762409401",
    shortVersion: "1.0.0-nightly.3911762409401",
    date: "2026-10-18",
    highlights: [],
    changes: [],
    whatsNew: {
      version: "1.0.0-nightly.3911762409401",
      channel: "nightly",
      date: "2026-10-18",
      headline: { en: "Add Apps update center" },
      entries,
    },
  };
}

function summaries(view: ReturnType<typeof releaseView>): Record<string, string> {
  const items = [view.hero, ...view.groups.flatMap((g) => g.items)].filter((i) => i !== undefined);
  return Object.fromEntries(items.map((i) => [i.id, i.summary]));
}

test("a summary that repeats its title is dropped", () => {
  const view = releaseView(
    notes([
      entry("summary-0", "Add Apps update center", "Add Apps update center"),
      entry("summary-1", "Paint bundled startup model immediately", "Paint bundled startup model immediately."),
    ]),
    "en",
  );
  expect(summaries(view)).toEqual({ "summary-0": "", "summary-1": "" });
});

test("a summary that says more than its title is kept", () => {
  const view = releaseView(
    notes([entry("tabs", "Tab groups", "Colored labels, icons, and pins that keep a group.")]),
    "en",
  );
  expect(summaries(view)).toEqual({ tabs: "Colored labels, icons, and pins that keep a group." });
});

// An older pipeline cut long titles with "…" and carried the whole line as the summary: the row
// shows the whole line once, as its title (Leo 2026-10-18: never cut a title mid-sentence).
test("a title cut with an ellipsis is made whole from its summary", () => {
  const long = "Keep favorite destinations within easy reach across all of your open windows";
  const view = releaseView(
    notes([entry("summary-0", "Keep favorite destinations within easy reach across all…", long)]),
    "en",
  );
  const [item] = view.groups.flatMap((g) => g.items);
  expect(item?.title).toBe(long);
  expect(item?.summary).toBe("");
});

// The digest of a new pipeline carries a shortened title and the rest of its line as the summary;
// an older one carries the whole line. Either way the row reads the line once.
test("a summary that continues its title shows only what it adds", () => {
  const view = releaseView(
    notes([
      entry(
        "summary-0",
        "Terminals in the keep-alive band keep drawing",
        "Terminals in the keep-alive band keep drawing, so a column scrolled in is never blank",
      ),
    ]),
    "en",
  );
  expect(summaries(view)).toEqual({ "summary-0": "So a column scrolled in is never blank" });
});

// A reviewed entry is a person's words: product names, a "Word:" lead and a long title stay, and
// a real summary is never replaced by the tail of a shortened title.
test("a reviewed entry keeps its words and its summary", () => {
  const view = releaseView(
    notes([
      entry("signin", "cmux NEXT: GitHub sign-in works on macOS (cx-8w027.3)", "Uses the iCloud Keychain."),
      entry("shortcut", "New shortcut: Cmd-K opens the palette", ""),
      entry(
        "restore",
        "Restore the sidebar width, the window frame, and the selected tab after a relaunch",
        "Everything comes back where you left it.",
      ),
    ]),
    "en",
  );
  const items = view.groups.flatMap((g) => g.items);
  expect(items.map((i) => [i.title, i.summary])).toEqual([
    ["GitHub sign-in works on macOS", "Uses the iCloud Keychain."],
    ["New shortcut: Cmd-K opens the palette", ""],
    [
      "Restore the sidebar width, the window frame, and the selected tab after a relaunch",
      "Everything comes back where you left it.",
    ],
  ]);
});
