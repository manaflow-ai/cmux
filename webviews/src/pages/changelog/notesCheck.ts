// The pre-publish check of a nightly's notes (Leo 2026-10-18; nightly.yml check-release-notes, run
// by scripts/cmux-next/check-release-notes.ts). Before the signed notes upload, it reads them as
// people will see them:
//  - the notes' own lines (What's New entries, summary lines, highlights): no title cut with "…",
//    no bead id, no title twice, and no internal work among the machine-made lines;
//  - the What's New page for an update of 1 nightly and of 10 (this build and the nine before it);
//  - the update card and popup for this build (the three items UpdateHighlights hands them).
// On the page and card a row may not repeat its title as its description either. Only this
// build's defects count: the 10-nightly page is compared with the same page without this build,
// so a defect an older nightly already published never blocks the notes after it.
import { localized, mergedView, readableUpdateItems, releaseTitle, type ReleaseView } from "./model";
import { readableChange } from "./readableChange";
import type { ReleaseNotes } from "./types";
import type { UpdateHighlightItem } from "./updateHighlights";

export type DefectKind = "duplicate" | "truncated" | "bead" | "internal";

export interface NotesDefect {
  kind: DefectKind;
  where: "notes" | "page (1 nightly)" | "page (10 nightlies)" | "card";
  text: string;
}

/** How many nightlies the wider page check spans, this build included. */
export const RANGE = 10;
/** Items the update card and popup get (UpdateHighlights.shownItems). */
const CARD_ITEMS = 3;
const BEAD = /\bcx-[a-z0-9]{3,}(?:\.\d+)*\b/i;
/** A sentence cut with "…" or "..."; a menu command keeps its ellipsis ("Rename Workspace…"), as
    release-notes.py writes it. */
const CUT = /(?<![A-Z][\w-]*)(?:…|\.\.\.)$/u;

interface Row {
  title: string;
  summary?: string;
  /** A machine-made line, judged by the commit rules. */
  machine?: boolean;
}

function key(text: string): string {
  return text
    .trim()
    .replace(/[.!…\s]+$/u, "")
    .toLowerCase();
}

/** Cut, bead and (for machine lines) internal-work defects of each row, and titles seen twice. */
function rowDefects(where: NotesDefect["where"], rows: Row[], shown: boolean): NotesDefect[] {
  const defects: NotesDefect[] = [];
  const titles = new Set<string>();
  for (const row of rows) {
    const title = row.title.trim();
    const summary = (row.summary ?? "").trim();
    if (CUT.test(title)) defects.push({ kind: "truncated", where, text: title });
    if (BEAD.test(title) || BEAD.test(summary)) defects.push({ kind: "bead", where, text: title });
    if (row.machine && readableChange(title).internal) defects.push({ kind: "internal", where, text: title });
    // The page and the card show the summary beside the title; the notes may carry both alike. A
    // multi-line description shows as written (model.ts readableItem), so only a one-line summary
    // that opens with the title echoes it.
    const opens = !summary.includes("\n") && key(summary).startsWith(`${key(title)} `);
    const echoes = summary && (key(summary) === key(title) || opens);
    if (titles.has(key(title)) || (shown && echoes)) defects.push({ kind: "duplicate", where, text: title });
    titles.add(key(title));
  }
  return defects;
}

/** The lines the notes carry for people. */
function noteRows(notes: ReleaseNotes, language: string): Row[][] {
  const entries = notes.whatsNew?.entries ?? [];
  const headline = notes.whatsNew?.entries.some((e) => !e.id.startsWith("summary-"))
    ? localized(notes.whatsNew?.headline, language)
    : "";
  return [
    [
      ...entries.map((e) => ({ title: localized(e.title, language), machine: e.id.startsWith("summary-") })),
      ...(headline ? [{ title: headline }] : []),
    ],
    (notes.summary ?? []).map((line) => ({ title: line.title, machine: true })),
    notes.highlights.map((h) => ({ title: h.title })),
  ];
}

/** The page's rows: the hero and New / Improved / Fixed / Security; All Changes only for bead ids. */
function pageDefects(where: NotesDefect["where"], view: ReleaseView, heading = ""): NotesDefect[] {
  const rows = [
    heading ? { title: heading, summary: "" } : undefined,
    view.hero,
    ...view.groups.flatMap((g) => g.items),
  ].filter((i) => i !== undefined);
  const changes = view.changes.filter((c) => BEAD.test(c.title));
  return [...rowDefects(where, rows, true), ...changes.map((c) => ({ kind: "bead" as const, where, text: c.title }))];
}

/** The update span has no curated heading. The journal's ledger gives each day
    its own heading and view, even across a ten-nightly range. */
function pageRangeDefects(where: NotesDefect["where"], notes: ReleaseNotes[], language: string): NotesDefect[] {
  const days = new Map<string, ReleaseNotes[]>();
  for (const note of notes) {
    const day = days.get(note.date) ?? [];
    day.push(note);
    days.set(note.date, day);
  }
  return [
    ...pageDefects(where, mergedView(notes, language)),
    ...[...days.values()].flatMap((day) => pageDefects(where, mergedView(day, language), releaseTitle(day, language))),
  ];
}

/** UpdateHighlights.pick: the What's New entries (New, Improved, Fixed, Security), else the
    highlights, else the summary lines; the first three, as the card and popup read them. */
export function cardItems(notes: ReleaseNotes, language: string): UpdateHighlightItem[] {
  const firstLine = (text: string) => text.split(/\r?\n/u)[0]?.trim() || null;
  const order = ["new", "improved", "fixed", "security"];
  const entries = [...(notes.whatsNew?.entries ?? [])].sort(
    (a, b) => order.indexOf(a.category) - order.indexOf(b.category),
  );
  const picked: UpdateHighlightItem[] = entries.length
    ? entries.map((e) => ({
        id: e.id,
        title: localized(e.title, language),
        summary: firstLine(localized(e.summary, language)),
        category: e.category,
      }))
    : notes.highlights.length
      ? notes.highlights.map((h) => ({ id: h.id, title: h.title, summary: firstLine(h.body), category: "new" }))
      : (notes.summary ?? []).map((line, index) => ({
          id: `summary-${index}`,
          title: line.title,
          summary: null,
          category: line.group === "fixed" ? "fixed" : line.group === "new" ? "new" : "improved",
        }));
  return readableUpdateItems(picked.slice(0, CARD_ITEMS));
}

/** Whether a defect withholds the notes. Internal work among the machine lines only warns: the
    page and the card fold those lines (model.ts readableItem, readableUpdateItems), so none reaches
    people, and a line the page reads as internal on a second pass ("Merge the green pull request…")
    would otherwise withhold this nightly and every nightly after it. */
export function blocksPublish(defect: NotesDefect): boolean {
  return defect.kind !== "internal";
}

function same(a: NotesDefect, b: NotesDefect): boolean {
  return a.kind === b.kind && a.text === b.text;
}

/** Every defect of `notes` (one nightly) as people will see it; `previous` are the nightlies
    published before it, newest first (the first RANGE - 1 are read). */
export function checkNightlyNotes(notes: ReleaseNotes, previous: ReleaseNotes[], language = "en"): NotesDefect[] {
  const before = previous.filter((n) => n.build !== notes.build).slice(0, RANGE - 1);
  const older = pageRangeDefects("page (10 nightlies)", before, language);
  const defects = [
    ...noteRows(notes, language).flatMap((rows) => rowDefects("notes", rows, false)),
    ...pageRangeDefects("page (1 nightly)", [notes], language),
    ...pageRangeDefects("page (10 nightlies)", [notes, ...before], language).filter(
      (d) => !older.some((o) => same(o, d)),
    ),
    ...rowDefects(
      "card",
      cardItems(notes, language).map((i) => ({ title: i.title, summary: i.summary ?? "" })),
      true,
    ),
  ];
  return defects.filter((d, i) => defects.findIndex((o) => o.where === d.where && same(o, d)) === i);
}

const LABELS: Record<DefectKind, string> = {
  duplicate: "a title shown twice or as its own description",
  truncated: "a cut title",
  bead: "a bead id",
  internal: "internal work in New, Improved or Fixed",
};

/** One GitHub Actions annotation: an error for a defect that withholds the notes, else a warning. */
export function annotation(build: string, defect: NotesDefect): string {
  const level = blocksPublish(defect) ? "error" : "warning";
  return `::${level} title=Release notes::${build} ${defect.where}: ${LABELS[defect.kind]}: ${defect.text}`;
}
