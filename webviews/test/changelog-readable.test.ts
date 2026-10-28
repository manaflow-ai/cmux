// Leo's update to nightly 3913596493801 (2026-10-18) listed perf-split and perf-fanout commits
// under Improved, cut titles with "…", wrote "Cmux NEXT", and dumped 92 raw commit subjects with
// bead ids under All Changes. The fixture is the ten signed notes of that update's span, as
// published.
import { expect, test } from "bun:test";
import span from "../src/pages/changelog/fixtures/nightly-3913596493801-span.json";
import nightlies from "../src/pages/changelog/fixtures/nightly-next-50.json";
import { changeItems, mergedView, readableChanges } from "../src/pages/changelog/model";
import {
  INTERNAL_SCOPES,
  INTERNAL_TYPES,
  INTERNAL_WORDS,
  readableChange,
  shortTitle,
} from "../src/pages/changelog/readableChange";
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

// The 49-nightly gallery range (2026-10-19) showed these published commit subjects under Improved
// and Fixed: a tool name, PR numbers and history repair are work no user sees.
test("tool-name, PR-number and history-repair commits are internal work", () => {
  for (const subject of [
    "cmux-next: export-backdrop-art reads each entry's subject box and exports it",
    "cmux-next media: tour uploads stop naming the PR as #N",
    "fix(cmux-next): restore the URL chip hover card styles lost in the Chief Dock squash",
    "fix(cmux-next): restore #21369 and #21384, undone by the Chief Dock squash",
  ])
    expect(readableChange(subject).internal).toBe(true);
  for (const subject of [
    "fix(cmux-next): keep the sidebar up-to-date after a rename",
    "feat(cmux-next): drag-and-drop a file into a terminal",
    "feat: side-by-side diffs in the review pane",
  ])
    expect(readableChange(subject).internal).toBe(false);
});

// Leo's update to nightly 4037632091801 (2026-10-26) read "Fixed: validate release headings within
// their day": a change to the release-notes checker (notesCheck.ts and its test), published as news
// both as its subject and as the summary line made from it. Release and changelog tooling is
// internal by its scope and by its words; the What's New page's own changes stay news.
const RELEASE_TOOLING = [
  "fix(changelog): validate release headings within their day (#25533)",
  "Validate release headings within their day",
  "ci(changelog): validate nightly notes before publication (#25518)",
  "cx-oy6yl: Repair base release-notary fixtures and highlight metadata (#25272)",
  "What's New: the persistent goals highlight fits the validator",
  "fix(release-notes): the digest keeps its period",
  "fix(appcast): every item carries its notes link",
];
const RELEASE_USER_FACING = [
  "What's New: every change with a clip shows it whole, beside its caption (#25135)",
  "cmux NEXT composer: click outside releases focus (#24896)",
  "cmux NEXT (release blocker): the app raises its open-file limit at launch, before Chromium starts",
  "fix(next): a kernel memory pressure source is safe to release before it starts",
  "fix(updater): staged updates stay replaceable until the restart",
  // Review of this change: a validator in the app is news; only the release gate's is not.
  "fix(webviews): wire validator errors and the checkpoint and continuation labels come from the pane's table",
  "feat: add a searchable changelog page",
  "Redesign changelog page with feature highlights",
  // What's New has its own release headings; a fix to them is news.
  "fix(next): release headings show the day they belong to",
  "fix(changelog): the popup's footer counts the changes it shows",
  "fix(updates): channel tracks read verdicts and pulls beside the cmux NEXT appcast on DEV and legacy feeds",
];

test("release and changelog tooling is internal work; the What's New page's changes are not", () => {
  for (const subject of RELEASE_TOOLING) expect([subject, readableChange(subject).internal]).toEqual([subject, true]);
  for (const subject of RELEASE_USER_FACING)
    expect([subject, readableChange(subject).internal]).toEqual([subject, false]);
});

// The pipeline marks a commit internal when every file it touches is CI or tooling
// (release-notes.py tooling_only), whatever its subject says; the page and the card trust it.
test("a change the notes mark internal stays out, whatever its subject", () => {
  const { changes, internal, hidden } = readableChanges([
    { title: "Headings of one day stay in order", pr: 1, internal: true },
    { title: "fix(sidebar): rows keep their order", pr: 2 },
  ]);
  expect(changes.map((c) => c.title)).toEqual(["Rows keep their order"]);
  expect(internal).toBe(1);
  expect(hidden.map((c) => c.title)).toEqual(["Headings of one day stay in order"]);
});

// Review of #22099 (2026-10-19): user-facing titles the tool-name, PR-number and squash rules
// must leave alone, a hyphenated name with a non-ASCII letter included.
const USER_FACING = [
  "feat(cmux-next): two-finger-swipe goes back in the browser",
  "feat(cmux-next): cmd-shift-t reopens the last closed tab",
  "feat(cmux-next): do-not-disturb holds notifications while you present",
  "fix(cmux-next): the pop-up-menu closes on Escape",
  "feat(cmux-next): a follow-up-question chip under each answer",
  "feat(cmux-next): per-tab-zoom remembers each tab's zoom",
  "fix(cmux-next): utf-8-encoded file names open",
  "fix(cmux-next): the #1 crash on wake is gone",
  "feat(cmux-next): tabs #1 to #9 have shortcuts",
  "feat(cmux-next): squash commits from the review pane",
  "feat(cmux-next): end-to-end-encrypted sync of settings",
  "fix(cmux-next): right-to-left-text lines wrap correctly",
  "feat(cmux-next): side-by-side-diff view for changed files",
  "feat: a naïve-mode-switch for the prompt",
];

// The 49-nightly range showed "Restore the URL chip hover card styles lost in the Chief Dock squash"
// under Fixed: its digest title was cut before "squash", and only the whole line reads as internal.
test("no internal line of the 50 published nightlies reaches New, Improved or Fixed", () => {
  const all = nightlies as ReleaseNotes[];
  for (const notes of [all, ...all.map((n) => [n])]) {
    const view = mergedView(notes, "en");
    for (const row of [view.hero, ...view.groups.flatMap((g) => g.items)].filter((i) => i !== undefined))
      expect(`${row.title} ${row.summary}`).not.toMatch(/export-backdrop-art|#N\b|#21369|Chief Dock squash/i);
  }
});

test("hyphenated feature names, small numbers and squash commits stay user-facing", () => {
  for (const subject of USER_FACING) expect([subject, readableChange(subject).internal]).toEqual([subject, false]);
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

// The 49-nightly update (3839629140701 to 3917159104301, gallery range-huge) showed "(hq#1957)"
// and "(review)" in New and All Changes, and "Feat-cmux-next base reds…" and "Compile fixes…" as
// changes a person would notice.
test("tracker and review references come off a title", () => {
  expect(readableChange("cmux-next: workspace name source and revision, like tab names (hq#1957)")).toMatchObject({
    title: "Workspace name source and revision, like tab names",
    internal: false,
  });
  expect(readableChange("cmux-next: the stage log keeps its first 16 and newest 32 entries (review)").title).toBe(
    "The stage log keeps its first 16 and newest 32 entries",
  );
});

test("agent and Unicode tracker references match the release-notes pipeline", () => {
  expect(readableChange("fix: foo (a123)").title).toBe("Foo");
  expect(readableChange("fix: foo (é#123)").title).toBe("Foo");
});

test("base reds, branch names and compile fixes are internal work", () => {
  expect(readableChange("fix: feat-cmux-next base reds in react-apps-check and cmux-next checks").internal).toBe(true);
  expect(readableChange("cmux-next: compile fixes (replay entry shadowing Location trail content name)").internal).toBe(
    true,
  );
});

// A subject that starts with a brand keeps its casing ("macOS", not "MacOS"), and notes that
// already carry "MacOS" (published before this rule) are not internal work.
test("a title that starts with a brand keeps the brand's casing", () => {
  expect(readableChange("fix: macOS 26 window shadows match the system")).toMatchObject({
    title: "macOS 26 window shadows match the system",
    internal: false,
  });
  expect(readableChange("MacOS 26 window shadows match the system").internal).toBe(false);
  expect(readableChange("iPhone pairing shows the Mac's name").title).toBe("iPhone pairing shows the Mac's name");
});

// The page reads notes published before the pipeline's rules (scripts/cmux-next/release-notes.py
// summary_entry and short_title) the same way the pipeline reads new ones: every subject of the
// medium span and of the 50 nightlies the gallery shows.
test("the page and the pipeline read every subject of the span alike", () => {
  const subjects = [
    ...new Set([
      ...(span as ReleaseNotes[]).flatMap((n) => n.changes),
      ...(nightlies as ReleaseNotes[]).flatMap((n) => changeItems(n).map((c) => c.title)),
      "fix: macOS 26 window shadows match the system",
      "iPhone pairing shows the Mac's name",
      ...USER_FACING,
      ...RELEASE_TOOLING,
      ...RELEASE_USER_FACING,
      "cmux-next: export-backdrop-art reads each entry's subject box and exports it",
      "fix(cmux-next): restore #21369 and #21384, undone by the Chief Dock squash",
    ]),
  ];
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

// The two readers share their word lists, not only their answers on today's subjects: a scope or a
// word added to one and not the other is a test failure, not a line that leaks on the next build.
test("the page and the pipeline share their internal types, scopes and words", () => {
  const script = `
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("notes", sys.argv[1])
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)
print(json.dumps([sorted(notes.INTERNAL_TYPES), sorted(notes.INTERNAL_SCOPES), notes.INTERNAL_WORDS.pattern]))
`;
  const run = Bun.spawnSync(["python3", "-c", script, `${import.meta.dir}/../../scripts/cmux-next/release-notes.py`]);
  expect(run.stderr.toString()).toBe("");
  expect(JSON.parse(run.stdout.toString())).toEqual([
    [...INTERNAL_TYPES].sort(),
    [...INTERNAL_SCOPES].sort(),
    INTERNAL_WORDS.source,
  ]);
});
