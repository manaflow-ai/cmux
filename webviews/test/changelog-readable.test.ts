// Leo's update to nightly 3913596493801 (2026-10-18) listed perf-split and perf-fanout commits
// under Improved, cut titles with "…", wrote "Cmux NEXT", and dumped 92 raw commit subjects with
// bead ids under All Changes. The fixture is the ten signed notes of that update's span, as
// published.
import { expect, test } from "bun:test";
import span from "../src/pages/changelog/fixtures/nightly-3913596493801-span.json";
import { mergedView, readableChanges } from "../src/pages/changelog/model";
import { readableChange, shortTitle } from "../src/pages/changelog/readableChange";
import type { ReleaseNotes } from "../src/pages/changelog/types";

const view = mergedView(span as ReleaseNotes[], "en");
const rows = [view.hero, ...view.groups.flatMap((g) => g.items)].filter((i) => i !== undefined);

test("work-stream commits never reach New, Improved or Fixed", () => {
  for (const row of rows) {
    expect(row.title).not.toMatch(/\bperf-|cmux next|review:/i);
    expect(row.summary).not.toMatch(/\bperf-|cmux next/i);
  }
});

test("no title is cut mid-sentence", () => {
  for (const row of rows) {
    expect(row.title.endsWith("…")).toBe(false);
    expect(row.summary.endsWith("…")).toBe(false);
  }
  const text = rows.map((r) => `${r.title} ${r.summary}`);
  expect(text.some((t) => t.includes("drops its loading spinner after 8 s"))).toBe(true);
  expect(text.some((t) => /never pinned to the traffic lights while the camera scrolls/i.test(t))).toBe(true);
});

test("All Changes lists each human change once and folds internal work into a count", () => {
  expect(view.changes.length).toBeGreaterThan(0);
  expect(view.internalChanges).toBeGreaterThan(0);
  for (const change of view.changes) {
    expect(change.title).not.toMatch(/\(cx-|\bcx-\w|^(fix|feat|perf|test|docs|ci)\b.*:|perf-gate|perf-split|^Revert/i);
  }
  const prs = view.changes.flatMap((c) => (c.pr === undefined ? [] : [c.pr]));
  expect(new Set(prs).size).toBe(prs.length);
  expect(view.changes.find((c) => c.pr === 21592)?.title).toBe("Restore workspace title motion tunable");
});

test("readable change titles", () => {
  expect(readableChange("cmux NEXT perf-split: snapshot sources name a new pane's first runs (cx-8w027.14)")).toEqual({
    title: "Snapshot sources name a new pane's first runs",
    internal: true,
    group: "changed",
  });
  expect(
    readableChange("cmux-next strip: a moving column keeps the larger traffic-light inset until it rests"),
  ).toEqual({
    title: "A moving column keeps the larger traffic-light inset until it rests",
    internal: false,
    group: "changed",
  });
  expect(readableChange("fix(ci): pin the runner").internal).toBe(true);
  expect(readableChange("perf-gate: a switch budget of 0 sidebar row configures (cx-8w027.17)").internal).toBe(true);
  expect(readableChange("test(cmux-next): CSI 996 reports dark").internal).toBe(true);
  expect(readableChange("fix(cmux-next): restore workspace title motion tunable").title).toBe(
    "Restore workspace title motion tunable",
  );
  // A label is a work stream only by its shape; "crash:" and "release:" are not.
  expect(readableChange("fix: crash: closing the last tab no longer quits the window")).toMatchObject({
    title: "Closing the last tab no longer quits the window",
    internal: false,
  });
  // Product names are not code.
  expect(readableChange("fix: GitHub sign-in works on macOS with iCloud Keychain").internal).toBe(false);
  expect(readableChange("fix: the sidebar reads workspace.title again").internal).toBe(true);
  // Agent plumbing and its tests never read as news (Leo 2026-10-21: "Ctrl-B after an adoption
  // waits for the restored turn" and "… meets D13 first" were listed as Improved).
  expect(readableChange("acpmux test: Ctrl-B after an adoption waits for the restored turn").internal).toBe(true);
  expect(readableChange("acpmux test: a Web answer to a Claude chat's trust card meets D13 first").internal).toBe(true);
  expect(
    readableChange("fix(acpmux): a log read pages within a byte limit; raw Claude stream events are not logged")
      .internal,
  ).toBe(true);
  expect(
    readableChange("fix(cmux-git): a submodule whose .git points nowhere is skipped with newer git too").internal,
  ).toBe(true);
  expect(readableChange("fix(cmux-tui-core): a local app under a symlinked folder reloads on macOS").internal).toBe(
    true,
  );
  // An agent chat change people see stays news; only its plumbing and tests are internal.
  expect(readableChange("fix(acpmux): the queue band is glass and one tone with its fold").internal).toBe(false);
  // A label that only names an app area stays news.
  expect(readableChange("Agent chat: new lines in the composer leave the transcript's scrollbar still").internal).toBe(
    false,
  );
});

test("short titles end at the first clause, never inside one or on a joining word", () => {
  expect(
    shortTitle("Restore the sidebar width, the window frame, and the selected tab after a relaunch of the app"),
  ).toBe("Restore the sidebar width");
  expect(
    shortTitle("Pinned tabs stay put and, when the strip scrolls past the end of the window, snap back"),
  ).toBeUndefined();
  expect(shortTitle("Terminals in the keep-alive band keep drawing, so a column scrolled in is never blank")).toBe(
    "Terminals in the keep-alive band keep drawing",
  );
  expect(shortTitle("An agent page that never paints drops its loading spinner after 8 s")).toBeUndefined();
  expect(shortTitle("A tab dropped on a strip lands by the pointer")).toBe(
    "A tab dropped on a strip lands by the pointer",
  );
});

test("All Changes drops a change reverted in the span and reads a pull request as its human commit", () => {
  const { changes, internal } = readableChanges([
    { title: "Fix tab drag", pr: 1 },
    { title: 'Revert "Fix tab drag (#1)"', pr: 2 },
    { title: "test(cmux-next): sidebar order", pr: 3 },
    { title: "fix: sidebar rows keep their order", pr: 3 },
    { title: "ci: pin the runner", pr: 4 },
  ]);
  expect(changes).toEqual([{ title: "Sidebar rows keep their order", pr: 3 }]);
  expect(internal).toBe(1);
});

// The page reads notes published before the pipeline's rules (scripts/cmux-next/release-notes.py
// summary_entry and short_title) the same way the pipeline reads new ones.
test("the page and the pipeline read every subject of the span alike", () => {
  const subjects = [...new Set((span as ReleaseNotes[]).flatMap((n) => n.changes))];
  const script = `
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("notes", sys.argv[1])
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)
out = []
for subject in json.load(sys.stdin):
    entry = notes.summary_entry(subject)
    out.append(None if entry is None else [entry[1], notes.short_title(entry[1], 60)])
print(json.dumps(out))
`;
  const run = Bun.spawnSync(["python3", "-c", script, `${import.meta.dir}/../../scripts/cmux-next/release-notes.py`], {
    stdin: new TextEncoder().encode(JSON.stringify(subjects)),
  });
  expect(run.stderr.toString()).toBe("");
  const python = JSON.parse(run.stdout.toString()) as ([string, string | null] | null)[];
  const page = subjects.map((subject) => {
    const readable = readableChange(subject);
    return readable.internal ? null : [readable.title, shortTitle(readable.title) ?? null];
  });
  expect(page.map((row, i) => [subjects[i], row])).toEqual(python.map((row, i) => [subjects[i], row]));
});
