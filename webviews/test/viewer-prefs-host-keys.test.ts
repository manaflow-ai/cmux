// Every diff pref the page persists must be one the host accepts. The page sends `diff.*` keys
// one at a time (`cmux.diff.prefs.set`), and the host refuses a key it has no schema row for
// (`DiffPrefKey.accepts`) with `invalidParams`, which saveViewerPrefs swallows on purpose — so a
// key the two sides disagree about does not fail, it silently never persists. That is how
// `groupByKind` shipped as a toggle that reset itself on every reopen (2026-10-20 review of
// #22951). This test reads the host's own list, so adding a page pref without its schema row
// fails here instead of in a person's hands.
import { expect, test } from "bun:test";
import type { DiffViewerOptions } from "../src/pierre-options";
import { sanitizeViewerPrefs } from "../src/viewer-prefs";

const DIFF_PREFS_SWIFT = `${import.meta.dir}/../../Packages/macOS/CmuxNext/Sources/CmuxNextDiff/DiffPrefs.swift`;

/** The `diff.*` keys `DiffPrefKey` accepts: its booleans, its choices and `collapsedFiles`. */
async function hostKeys(): Promise<Set<string>> {
  const source = await Bun.file(DIFF_PREFS_SWIFT).text();
  const booleans = /static let booleans: Set<String> = \[([^\]]*)\]/.exec(source);
  const choices = /static let choices: \[String: Set<String>\] = \[([\s\S]*?)\n {4}\]/.exec(source);
  const collapsed = /static let collapsedFiles = "([A-Za-z]+)"/.exec(source);
  if (!booleans || !choices || !collapsed) throw new Error("DiffPrefs.swift no longer reads as expected");
  const quoted = (text: string) => [...text.matchAll(/"([A-Za-z]+)"/g)].map((match) => match[1]!);
  // Only the keys of `choices`, which are the names before each colon.
  const choiceKeys = [...choices[1]!.matchAll(/"([A-Za-z]+)":/g)].map((match) => match[1]!);
  return new Set([...quoted(booleans[1]!), ...choiceKeys, collapsed[1]!]);
}

/**
 * One of every display option the viewer has, with a valid value, for sanitizeViewerPrefs. Typed
 * so a new `DiffViewerOptions` key has to be listed here, where this guard can see it; untyped,
 * the next option sanitizeViewerPrefs persists would slip past the test.
 */
const EVERY_OPTION: Required<DiffViewerOptions> & { collapsedFiles: string[] } = {
  collapsed: true,
  collapsedFiles: ["/repo\u0000src/app.ts"],
  colors: "theme",
  diffIndicators: "bars",
  expandUnchanged: true,
  groupByKind: true,
  hideWhitespace: true,
  hideImports: true,
  loadFullFiles: true,
  richPreview: true,
  layout: "split",
  lineNumbers: true,
  showBackgrounds: true,
  showBulkActions: true,
  wordDiffs: true,
  wordWrap: true,
};

test("every diff pref the page persists is a key the host accepts", async () => {
  const accepted = await hostKeys();
  // The regexes still find the host's lists.
  expect(accepted.has("wordWrap")).toBe(true);
  expect(accepted.has("layout")).toBe(true);
  expect(accepted.has("collapsedFiles")).toBe(true);
  const persisted = Object.keys(sanitizeViewerPrefs(EVERY_OPTION)).sort();
  expect(persisted.length).toBeGreaterThan(0);
  expect(persisted.filter((key) => !accepted.has(key))).toEqual([]);
});

test("a session-local option is never persisted", async () => {
  const persisted = Object.keys(sanitizeViewerPrefs(EVERY_OPTION));
  // The collapse-all toggle is session-local by design: it is a way of reading this diff now, not
  // a preference about every diff.
  expect(persisted).not.toContain("collapsed");
  // Hide imports lasts for the tab: it has no settings row, and the host would refuse the key.
  expect(persisted).not.toContain("hideImports");
  expect(persisted).not.toContain("richPreview");
  expect(persisted).not.toContain("loadFullFiles");
});

test("the file grouping is kept, because the host now has a row for it", async () => {
  // It shipped as a toolbar toggle that reset itself on every reopen: the page sent
  // `diff.groupByKind`, the host had no schema row for it, and `saveViewerPrefs` swallowed the
  // refusal. Both halves are asserted here, because either one alone is the silent bug again.
  const accepted = await hostKeys();
  expect(accepted.has("groupByKind")).toBe(true);
  expect(sanitizeViewerPrefs(EVERY_OPTION).groupByKind).toBe(true);
  expect(sanitizeViewerPrefs({ groupByKind: "yes" })).toEqual({});
});

test("Hide white space is kept, because the host has a row for it", async () => {
  // The "..." menu's Hide white space writes `diff.hideWhitespace`; without its row in
  // DiffPrefKey.booleans the host would refuse it and the toggle would reset on every reopen.
  const accepted = await hostKeys();
  expect(accepted.has("hideWhitespace")).toBe(true);
  expect(sanitizeViewerPrefs(EVERY_OPTION).hideWhitespace).toBe(true);
});
