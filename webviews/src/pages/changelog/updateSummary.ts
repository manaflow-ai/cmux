// The Updated card's summary of an update (whats-new lane, 2026-10-20): what changed since the
// version the person had, grouped by area and in their words, "Sidebar: groups take a palette
// color; a click never drags · New Tab: … · +12 more". It said one title, the newest commit's
// subject, even when the update spanned several skipped nightlies. Every build after the previous
// version counts (the host serves their notes, ChangelogStore loads them); a build with reviewed
// entries counts those, any other its readable commits. Internal work stays out (readableChange).
// Pure: no DOM, no state.
import { areaOf, type AreaKey } from "./areas";
import { changeItems, localized, readableChanges } from "./model";
import { changeArea, readableChange, shortTitle, tidyTitle } from "./readableChange";
import type { ReleaseNotes, WhatsNewCategory } from "./types";
import type { UpdateHighlights } from "./updateHighlights";

/** One line of the card: a known area, else the category its changes share, and their phrases. */
export interface SummaryRow {
  area?: AreaKey;
  category?: WhatsNewCategory;
  phrases: string[];
}

export interface UpdateSummary {
  rows: SummaryRow[];
  /** User-visible changes not listed. */
  more: number;
}

/** At most three lines on the card, two changes each, each change at most one clause long. */
const ROWS = 3;
const PHRASES = 2;
const PHRASE_LIMIT = 48;

interface Change {
  title: string;
  category: WhatsNewCategory;
  area?: AreaKey;
  /** The commit subject the title came from, for its own casing. */
  raw?: string;
}

/** The change as it reads after "Sidebar:": its first clause when the title is long, lowercased
    where its subject wrote it so ("a click never drags", but "Return steers a running turn"). An
    English title with no subject is lowercased when it starts with a plain word ("Enroll Computer
    Use" keeps its capital); a localized one keeps its case (German nouns). Undefined when no
    clause is short enough. */
function phrase(change: Change, english: boolean): string | undefined {
  const short = shortTitle(change.title, PHRASE_LIMIT);
  if (!short) return undefined;
  const lower = short.charAt(0).toLowerCase() + short.slice(1);
  if (change.raw !== undefined) return change.raw.includes(lower) ? lower : short;
  return english && /^[A-Z][a-z]*\s+[^A-Z\s]/.test(short) ? lower : short;
}

function category(group: string): WhatsNewCategory {
  return group === "new" ? "new" : group === "fixed" ? "fixed" : "improved";
}

/** The rows: named areas first, then by how many changes each has, then newest first. */
function summarize(changes: Change[], language: string, unlisted = 0): UpdateSummary {
  const english = language === "en" || language.startsWith("en-");
  const buckets = new Map<string, { row: SummaryRow; changes: Change[]; first: number }>();
  changes.forEach((change, index) => {
    const key = change.area ?? `category:${change.category}`;
    const bucket = buckets.get(key) ?? {
      row: change.area ? { area: change.area, phrases: [] } : { category: change.category, phrases: [] },
      changes: [],
      first: index,
    };
    bucket.changes.push(change);
    buckets.set(key, bucket);
  });
  const ordered = [...buckets.values()].sort(
    (a, b) => Number(!a.row.area) - Number(!b.row.area) || b.changes.length - a.changes.length || a.first - b.first,
  );
  const rows: SummaryRow[] = [];
  let listed = 0;
  for (const bucket of ordered) {
    if (rows.length === ROWS) break;
    const phrases = bucket.changes.flatMap((c) => phrase(c, english) ?? []).slice(0, PHRASES);
    if (phrases.length === 0) continue;
    rows.push({ ...bucket.row, phrases });
    listed += phrases.length;
  }
  return { rows, more: changes.length + unlisted - listed };
}

/** A build's reviewed changes: its What's New entries (not the ones made from summary lines) and
    the highlights they do not carry. */
function curatedChanges(notes: ReleaseNotes, language: string): Change[] {
  const changes: Change[] = [];
  const ids = new Set<string>();
  for (const entry of notes.whatsNew?.entries ?? []) {
    if (entry.id.startsWith("summary-")) continue;
    ids.add(entry.id);
    const title = tidyTitle(localized(entry.title, language));
    changes.push({ title, category: entry.category, area: areaOf(title) });
  }
  for (const highlight of notes.highlights) {
    if (ids.has(highlight.id)) continue;
    const title = tidyTitle(highlight.title);
    changes.push({ title, category: highlight.category ?? "new", area: areaOf(title) });
  }
  return changes;
}

/** The summary of an update's builds (`notes` newest first), each change once. */
export function summarizeUpdate(notes: ReleaseNotes[], language: string): UpdateSummary {
  const changes: Change[] = [];
  const seen = new Set<string>();
  const add = (change: Change) => {
    const key = change.title.toLowerCase();
    if (seen.has(key)) return;
    seen.add(key);
    changes.push(change);
  };
  for (const build of notes) {
    const curated = curatedChanges(build, language);
    if (curated.length) {
      curated.forEach(add);
      continue;
    }
    const items = changeItems(build).map((item) => ({ ...item, raw: item.title, label: changeArea(item.title) }));
    for (const item of readableChanges(items).changes) {
      const group = readableChange(item.raw).group;
      add({ title: item.title, raw: item.raw, category: category(group), area: areaOf(item.title, item.label) });
    }
  }
  return summarize(changes, language);
}

/** The summary of what the host sent for the installed build alone, when the span's notes did not
    load (an older host, offline): the same rows, from its already readable items. */
export function summarizeHighlights(data: UpdateHighlights): UpdateSummary {
  const items = [...data.items, ...(data.rest ?? [])];
  const changes = items.map((item) => ({ title: item.title, category: item.category, area: areaOf(item.title) }));
  return summarize(changes, data.language, Math.max(0, data.moreCount - (data.rest?.length ?? 0)));
}
