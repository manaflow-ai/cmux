// The pre-publish check of a nightly's notes (nightly.yml check-release-notes, Leo 2026-10-18):
// what the What's New page shows for the last 1 and 10 nightlies and what the update card shows
// for the build, before the notes are uploaded. The fixture is the 50 nightlies the nightly-next
// notes index listed on 2026-10-19, as published.
import { expect, test } from "bun:test";
import fixture from "../src/pages/changelog/fixtures/nightly-next-50.json";
import { blocksPublish, checkNightlyNotes } from "../src/pages/changelog/notesCheck";
import type { ReleaseNotes, WhatsNewEntry } from "../src/pages/changelog/types";

const nightlies = fixture as ReleaseNotes[];

function at(build: string): { notes: ReleaseNotes; previous: ReleaseNotes[] } {
  const index = nightlies.findIndex((n) => n.build === build);
  return { notes: nightlies[index]!, previous: nightlies.slice(index + 1, index + 10) };
}

function digestEntry(id: string, title: string, summary = title): WhatsNewEntry {
  return { id, category: "improved", title: { en: title }, summary: { en: summary } };
}

function withEntries(notes: ReleaseNotes, entries: WhatsNewEntry[]): ReleaseNotes {
  return { ...notes, whatsNew: { ...notes.whatsNew!, entries } };
}

/** 3917159104301 as the current pipeline writes it: its first entry under Fixed, and no
    tool-name summary line (export-backdrop-art is internal work). */
function clean(notes: ReleaseNotes): ReleaseNotes {
  return {
    ...withEntries(notes, [{ ...notes.whatsNew!.entries[0]!, category: "fixed" }]),
    summary: (notes.summary ?? []).filter((line) => !line.title.startsWith("Export-backdrop-art")),
  };
}

test("3917159104301 as published fails on its cut digest title and its tool-name line", () => {
  const { notes, previous } = at("3917159104301");
  const defects = checkNightlyNotes(notes, previous).map((d) => `${d.where} ${d.kind} ${d.text}`);
  expect(defects).toContain("notes truncated Export-backdrop-art reads each entry's subject box and…");
  expect(defects).toContain("notes internal Export-backdrop-art reads each entry's subject box and exports it");
  expect(defects.every((d) => d.startsWith("notes "))).toBe(true);
});

test("notes as the current pipeline writes them pass, alone and with the nine nightlies before them", () => {
  const { notes, previous } = at("3917159104301");
  const fixed = clean(notes);
  expect(checkNightlyNotes(fixed, previous)).toEqual([]);
});

test("published summary lines naming PR numbers or a squash fail as internal work", () => {
  const tour = at("3917061587901");
  expect(checkNightlyNotes(tour.notes, tour.previous).map((d) => `${d.where} ${d.kind} ${d.text}`)).toContain(
    "notes internal Tour uploads stop naming the PR as #N",
  );
  const squash = at("3914841887501");
  const defects = checkNightlyNotes(squash.notes, squash.previous).map((d) => `${d.where} ${d.kind} ${d.text}`);
  expect(defects).toContain("notes internal Restore the URL chip hover card styles lost in the Chief Dock squash");
  expect(defects).toContain("notes internal Restore #21369 and #21384, undone by the Chief Dock squash");
});

test("a leaked bead id, a cut title and internal work in the build's own lines fail", () => {
  const { notes, previous } = at("3917159104301");
  const bad: ReleaseNotes = {
    ...withEntries(notes, [
      digestEntry("summary-0", "Keep the Mac awake while agents work (cx-ab12)"),
      digestEntry("summary-1", "perf-gate: a switch budget of 0 sidebar row configures"),
    ]),
    summary: [
      { group: "fixed", title: "Keep the Mac awake while agents work (cx-ab12)" },
      { group: "changed", title: "Tabs reopen where they were..." },
    ],
  };
  const kinds = checkNightlyNotes(bad, previous).map((d) => `${d.where} ${d.kind} ${d.text}`);
  expect(kinds).toContain("notes bead Keep the Mac awake while agents work (cx-ab12)");
  expect(kinds).toContain("notes internal perf-gate: a switch budget of 0 sidebar row configures");
  expect(kinds).toContain("notes truncated Tabs reopen where they were...");
});

// The generator keeps a menu command's ellipsis ("Rename Workspace…"); only a cut sentence fails.
test("a title ending in a menu command's ellipsis passes", () => {
  const { notes, previous } = at("3917159104301");
  const menu: ReleaseNotes = {
    ...clean(notes),
    summary: [...(clean(notes).summary ?? []), { group: "new", title: "Rename Workspace…" }],
  };
  expect(checkNightlyNotes(menu, previous)).toEqual([]);
});

test("a reviewed entry the page would show twice, or with its title as its description, fails", () => {
  const { notes, previous } = at("3917159104301");
  const twice = withEntries(notes, [
    { ...digestEntry("tabs", "Tabs reopen where they were", "Tabs reopen where they were"), category: "new" },
    { ...digestEntry("tabs-again", "Tabs reopen where they were", "After a relaunch."), category: "new" },
  ]);
  const defects = checkNightlyNotes(twice, previous).map((d) => `${d.where} ${d.kind} ${d.text}`);
  expect(defects).toContain("notes duplicate Tabs reopen where they were");
});

test("a defect only an older nightly has is not this build's to fix", () => {
  const { notes, previous } = at("3917159104301");
  const fixed = clean(notes);
  const older = previous.map((n, i) =>
    i === 0 ? { ...n, highlights: [{ id: "old", title: "An old highlight cut short…", body: "" }] } : n,
  );
  expect(checkNightlyNotes(fixed, older)).toEqual([]);
});

test("every one of the 50 published nightlies shows clean on the page and the card", () => {
  for (const [index, notes] of nightlies.entries()) {
    const shown = checkNightlyNotes(notes, nightlies.slice(index + 1, index + 10)).filter((d) => d.where !== "notes");
    expect([notes.build, shown]).toEqual([notes.build, []]);
  }
});

test("a summary line that starts with a brand passes, as the pipeline published it", () => {
  const { notes, previous } = at("3917159104301");
  const fixed = clean(notes);
  const branded: ReleaseNotes = {
    ...fixed,
    summary: [...(fixed.summary ?? []), { group: "fixed", title: "MacOS 26 window shadows match the system" }],
  };
  expect(checkNightlyNotes(branded, previous)).toEqual([]);
});

// The page shows a multi-line description as written (model.ts readableItem), so a highlight
// whose body opens with its title is not a title repeated as its description.
test("a highlight whose multi-line body opens with its title passes", () => {
  const { notes, previous } = at("3917159104301");
  const fixed = clean(notes);
  const highlighted: ReleaseNotes = {
    ...fixed,
    highlights: [
      { id: "rapid-switch", title: "Rapid switch", body: "Rapid switch keys move between tabs.\nThey follow focus." },
    ],
  };
  expect(checkNightlyNotes(highlighted, previous)).toEqual([]);
});

// The nightly job runs the check as `bun scripts/cmux-next/check-release-notes.ts NOTES PREVIOUS…`.
test("the command fails with one annotation per defect, and passes clean notes", async () => {
  const { mkdtempSync, writeFileSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const dir = mkdtempSync(`${tmpdir()}/notes-check-`);
  const { notes, previous } = at("3917159104301");
  const files = [notes, ...previous].map((n) => {
    const path = `${dir}/${n.build}.json`;
    writeFileSync(path, JSON.stringify(n));
    return path;
  });
  const script = `${import.meta.dir}/../../scripts/cmux-next/check-release-notes.ts`;
  const bad = Bun.spawnSync([process.execPath, script, ...files]);
  expect(bad.exitCode).toBe(1);
  expect(bad.stdout.toString()).toContain(
    "::error title=Release notes::3917159104301 notes: a cut title: Export-backdrop-art reads each entry's subject box and…",
  );
  const fixed = clean(notes);
  writeFileSync(files[0]!, JSON.stringify(fixed));
  const good = Bun.spawnSync([process.execPath, script, ...files]);
  expect([good.exitCode, good.stdout.toString()]).toEqual([
    0,
    "3917159104301: notes, page (1 and 10 nightlies) and card read clean\n",
  ]);
});

// Review of #22099: the page re-reads a summary line release-notes.py already made readable, and
// a few such lines read as internal the second time ("Merge the green pull request…" from
// "cx-ncc.77.4: merge the green pull request…"; "Onboarding: …" from "onboarding (red): …").
// The page folds those lines, so no internal work reaches people; that must not withhold the
// night's notes (and every nightly after it, which carries the same line).
test("a summary line the page would fold warns but does not block the notes", () => {
  const { notes, previous } = at("3917159104301");
  const folded = [
    "Merge the green pull request from the PR chip",
    "Onboarding: the primary button must never be the theme's blue",
  ];
  const built = {
    ...clean(notes),
    summary: [...(clean(notes).summary ?? []), ...folded.map((title) => ({ title, group: "fixed" as const }))],
  };
  const defects = checkNightlyNotes(built, previous);
  expect(defects.filter((d) => d.kind === "internal").map((d) => d.text)).toEqual(folded);
  expect(defects.filter(blocksPublish)).toEqual([]);
});

test("a curated headline repeated by an entry is reported as a duplicate", () => {
  const { notes, previous } = at("3917159104301");
  const base = clean(notes);
  const headline = "Keep the Mac awake while agents work";
  const entries = [
    {
      ...base.whatsNew!.entries[0]!,
      id: "curated-a",
      title: { en: "Different Hero" },
      summary: { en: "A real feature" },
    },
    { ...base.whatsNew!.entries[0]!, id: "curated-b", title: { en: headline }, summary: { en: "Another detail" } },
  ];
  const duplicate = { ...base, whatsNew: { ...base.whatsNew!, headline: { en: headline }, entries } };
  expect(checkNightlyNotes(duplicate, previous).map((d) => `${d.where} ${d.kind} ${d.text}`)).toContain(
    `notes duplicate ${headline}`,
  );
});

test("a curated headline repeated by an older nightly in the page range is reported", () => {
  const { notes } = at("3917159104301");
  const headline = "A shared release title";
  const current = {
    ...clean(notes),
    date: "2026-10-19",
    whatsNew: {
      ...clean(notes).whatsNew!,
      headline: { en: headline },
      entries: [{ ...clean(notes).whatsNew!.entries[0]!, id: "curated-current", title: { en: "Current feature" } }],
    },
  };
  const older = {
    ...clean(notes),
    build: "3917061587901",
    date: "2026-10-19",
    whatsNew: {
      ...clean(notes).whatsNew!,
      headline: { en: "Older release" },
      entries: [{ ...clean(notes).whatsNew!.entries[0]!, id: "curated-older", title: { en: headline } }],
    },
  };
  expect(checkNightlyNotes(current, [older]).map((d) => `${d.where} ${d.kind} ${d.text}`)).toContain(
    `page (10 nightlies) duplicate ${headline}`,
  );
});

// JournalPage gives each release day its own heading; the update span has no
// curated heading. A heading from yesterday cannot duplicate today's row.
test("a previous-day heading does not block a current summary with the same title", () => {
  const { notes } = at("3917159104301");
  const title = "A shared release title";
  const empty = { ...clean(notes), highlights: [], changes: [], items: [], summary: [] };
  const current: ReleaseNotes = {
    ...empty,
    date: "2026-10-20",
    whatsNew: undefined,
    summary: [{ group: "fixed", title }],
  };
  const older = {
    ...withEntries(empty, [digestEntry("curated-older", "An older feature", "Its own detail.")]),
    build: "3917061587901",
    date: "2026-10-19",
  };
  older.whatsNew!.headline = { en: title };
  expect(checkNightlyNotes(current, [older])).toEqual([]);
});
