// One release as the page shows it (cx-urd.61): an optional hero (the release's lead change, with
// its media and action) and the rest grouped New / Improved / Fixed / Security, then the raw
// commit subjects. The notes carry up to three sources, best first: the release's What's New
// document, the human highlights, the short summary lines. Pure: no DOM, no state.
import type {
  ChangeItem,
  Highlight,
  IndexEntry,
  LocalizedText,
  ReleaseNotes,
  WhatsNewCategory,
  WhatsNewEntry,
} from "./types";
import { readableChange, revertedSubject, shortTitle, tidyTitle, titleTail } from "./readableChange";

export const CATEGORY_ORDER: readonly WhatsNewCategory[] = ["new", "improved", "fixed", "security"];

export interface MediaRef {
  /** Per color scheme; a highlight's single picture serves both. */
  light: string;
  dark: string;
  alt: string;
  video: boolean;
}

export interface ReleaseItem {
  id: string;
  category: WhatsNewCategory;
  title: string;
  summary: string;
  media?: MediaRef;
  /** An allow-listed action id the page may ask the host to run, and its label (none: "Try it"). */
  action?: { id: string; title?: string };
  docs?: string;
}

export interface ReleaseView {
  hero?: ReleaseItem;
  groups: { category: WhatsNewCategory; items: ReleaseItem[] }[];
  /** Every change a person would notice (readable titles, each pull request once), shown folded. */
  changes: ChangeItem[];
  /** Changes left out of `changes` as internal work (CI, tests, perf measurement). */
  internalChanges: number;
  /** Every change the release lists (hero and groups), for counts. */
  count: number;
}

/** The text for `language` (exact, then without region or script), else English. */
export function localized(text: LocalizedText | undefined, language: string): string {
  if (!text) return "";
  const parts = language.split("-");
  for (let n = parts.length; n > 0; n--) {
    const value = text[parts.slice(0, n).join("-")];
    if (value) return value;
  }
  return text.en ?? Object.values(text)[0] ?? "";
}

/** A media source the page's CSP admits (img-src 'self' data:): data: or same origin (relative). Remote URLs are dropped. */
export function admissibleSource(src: string | undefined): string | undefined {
  if (!src) return undefined;
  if (/^data:/i.test(src)) return src;
  if (/^[a-z][a-z0-9+.-]*:/i.test(src) || src.startsWith("//")) return undefined;
  return src;
}

/** The summary, or "" when it only repeats the title: a digest built from summary lines
    carries each line as both (scripts/cmux-next/release-notes.py). */
export function distinctSummary(title: string, summary: string): string {
  const key = (text: string) =>
    text
      .trim()
      .replace(/[.!…\s]+$/u, "")
      .toLowerCase();
  return key(summary) === key(title) ? "" : summary;
}

function fromEntry(entry: WhatsNewEntry, language: string): ReleaseItem {
  const light = admissibleSource(entry.media?.light);
  const dark = admissibleSource(entry.media?.dark);
  const title = localized(entry.title, language);
  return {
    id: entry.id,
    category: entry.category,
    title,
    summary: distinctSummary(title, localized(entry.summary, language)),
    media:
      entry.media && (light || dark)
        ? {
            light: light ?? dark!,
            dark: dark ?? light!,
            alt: localized(entry.media.alt, language),
            video: entry.media.kind === "video",
          }
        : undefined,
    action: entry.tryIt?.action ? { id: entry.tryIt.action } : undefined,
    docs: entry.docs,
  };
}

function fromHighlight(highlight: Highlight): ReleaseItem {
  const media = highlight.media?.find((m) => admissibleSource(m.url));
  const src = media ? admissibleSource(media.url)! : undefined;
  return {
    id: highlight.id,
    category: highlight.category ?? "new",
    title: highlight.title,
    summary: highlight.body,
    media: media && src ? { light: src, dark: src, alt: media.alt, video: media.kind === "video" } : undefined,
    action: highlight.action ? { id: highlight.action.id, title: highlight.action.title } : undefined,
  };
}

function summaryCategory(group: string): WhatsNewCategory {
  if (group === "fixed") return "fixed";
  if (group === "new") return "new";
  if (group === "security") return "security";
  return "improved";
}

/** The lead change: the first New with media, else any item with media. A change without a
    picture stays a row: a paragraph-long headline would outweigh the list (2026-10-12 review). */
function pickHero(items: ReleaseItem[]): ReleaseItem | undefined {
  return items.find((i) => i.category === "new" && i.media) ?? items.find((i) => i.media);
}

/** The item as a person reads it, or undefined for internal work. A machine-made line (a summary
    line, or a digest entry made from one) gets the commit rules; a human-written title only loses
    bead ids and the product's own label. A title an older pipeline cut with "…" is made whole from
    the line it came from; a summary that repeats the title keeps only what it adds; a long title
    with no summary ends at its first clause and the rest becomes the summary. */
function readableItem(item: ReleaseItem, changes: ChangeItem[], machine: boolean): ReleaseItem | undefined {
  const clean = (text: string) => (machine ? readableChange(text).title : tidyTitle(text));
  if (machine && readableChange(item.title).internal) return undefined;
  let full = clean(item.title);
  const stem = stemOf(full);
  const line = item.summary && !item.summary.includes("\n") ? clean(item.summary) : "";
  // The summary repeats the title, maybe cut with "…" itself: the line the entry was made from.
  const echoes = !!line && (stemOf(line).startsWith(stem) || stem.startsWith(stemOf(line)));
  const lineWhole = echoes && !line.endsWith("…");
  if (full.endsWith("…")) {
    const whole = lineWhole
      ? line
      : changes
          .map((c) => readableChange(c.title).title)
          .find((text) => !text.endsWith("…") && stemOf(text).startsWith(stem) && text.length > stem.length);
    full = whole ?? full.slice(0, -1).trim();
  }
  let summary = !echoes ? item.summary : lineWhole ? capitalized(titleTail(line, full)) : "";
  let title = full;
  const short = shortTitle(full);
  if (short && short !== full && !distinctSummary(full, summary)) {
    title = short;
    summary = capitalized(titleTail(full, short));
  }
  return { ...item, title, summary: distinctSummary(title, summary) };
}

function stemOf(text: string): string {
  return text.replace(/[.!…\s]+$/u, "").toLowerCase();
}

function capitalized(text: string): string {
  return text.charAt(0).toUpperCase() + text.slice(1);
}

/** A subject without its "(#123)": how a revert names the change it undoes. */
function bareSubject(text: string): string {
  return text.replace(/\s*\(#\d+\)\s*$/u, "").trim();
}

/** The changes a person would notice, readable and each pull request (or title) once, and how
    many internal ones were left out. A pull request reads as its human commit when it has one; a
    change reverted in the same span, and its revert, are left out. */
export function readableChanges(items: ChangeItem[]): { changes: ChangeItem[]; internal: number } {
  const reverted = new Set(
    items.map((item) => revertedSubject(item.title)).flatMap((subject) => (subject ? [bareSubject(subject)] : [])),
  );
  const rows: { key: string; item: ChangeItem; internal: boolean }[] = [];
  const byKey = new Map<string, number>();
  for (const item of items) {
    if (revertedSubject(item.title) || reverted.has(bareSubject(item.title))) continue;
    const readable = readableChange(item.title);
    const key = item.pr !== undefined ? `#${item.pr}` : readable.title.toLowerCase();
    const row = { key, item: { ...item, title: readable.title }, internal: readable.internal };
    const at = byKey.get(key);
    if (at === undefined) {
      byKey.set(key, rows.length);
      rows.push(row);
    } else if (rows[at]!.internal && !readable.internal) rows[at] = row;
  }
  return {
    changes: rows.filter((r) => !r.internal).map((r) => r.item),
    internal: rows.filter((r) => r.internal).length,
  };
}

export function releaseView(notes: ReleaseNotes, language: string): ReleaseView {
  // The reviewed document first, then the highlights it does not carry (a nightly digest drops
  // an entry the validator refuses), then the summary lines no highlight already says. Each as a
  // person reads it; internal work is left out.
  const raw = changeItems(notes);
  const items: ReleaseItem[] = [];
  const ids = new Set<string>();
  const seen = new Set<string>();
  const add = (item: ReleaseItem, byId: boolean, machine: boolean) => {
    if (byId && ids.has(item.id)) return;
    const readable = readableItem(item, raw, machine);
    if (!readable) return;
    const key = readable.title.toLowerCase();
    if (seen.has(key)) return;
    ids.add(item.id);
    seen.add(key);
    items.push(readable);
  };
  // A digest the pipeline made from summary lines names its entries "summary-N".
  for (const entry of notes.whatsNew?.entries ?? [])
    add(fromEntry(entry, language), false, entry.id.startsWith("summary-"));
  for (const highlight of notes.highlights) add(fromHighlight(highlight), true, false);
  for (const [index, line] of (notes.summary ?? []).entries()) {
    add({ id: `summary-${index}`, category: summaryCategory(line.group), title: line.title, summary: "" }, false, true);
  }
  const hero = pickHero(items);
  const rest = items.filter((i) => i !== hero);
  const groups = CATEGORY_ORDER.map((category) => ({
    category,
    items: rest.filter((i) => i.category === category),
  })).filter((g) => g.items.length > 0);
  const { changes, internal } = readableChanges(raw);
  return { hero, groups, changes, internalChanges: internal, count: items.length };
}

/** The notes' structured changes, else one item per commit subject (no PR without the provider). */
export function changeItems(notes: ReleaseNotes): ChangeItem[] {
  return notes.items?.length ? notes.items : notes.changes.map((title) => ({ title }));
}

/** Several builds read as one (an update's span, or one day of nightlies): one hero, every human
    change once (deduplicated by title), every commit once. `notes` newest first. */
export function mergedView(notes: ReleaseNotes[], language: string): ReleaseView {
  const views = notes.map((n) => releaseView(n, language));
  const items: ReleaseItem[] = [];
  const seen = new Set<string>();
  const add = (item: ReleaseItem | undefined) => {
    const key = item?.title.trim().toLowerCase();
    if (!item || !key || seen.has(key)) return;
    seen.add(key);
    items.push(item);
  };
  for (const view of views) {
    add(view.hero);
    view.groups.forEach((g) => g.items.forEach(add));
  }
  const hero = pickHero(items);
  const rest = items.filter((i) => i !== hero);
  const groups = CATEGORY_ORDER.map((category) => ({
    category,
    items: rest.filter((i) => i.category === category),
  })).filter((g) => g.items.length > 0);
  const { changes, internal } = readableChanges(notes.flatMap(changeItems));
  return { hero, groups, changes, internalChanges: internal, count: items.length };
}

/** A release day's title, Conductor style (2026-10-20): the curated headline of its newest build
    that has curated entries. Undefined when none has one: such a day says "Maintenance and fixes". */
export function releaseTitle(notes: ReleaseNotes[], language: string): string | undefined {
  for (const n of notes) {
    if (!n.whatsNew || n.whatsNew.entries.length === 0) continue;
    const title = localized(n.whatsNew.headline, language).trim();
    if (title) return title;
  }
  return undefined;
}

/** Builds (newest first) in runs of one release day. */
export function groupByDay(builds: IndexEntry[]): { day: string; builds: IndexEntry[] }[] {
  const days: { day: string; builds: IndexEntry[] }[] = [];
  for (const build of builds) {
    const last = days[days.length - 1];
    if (last && last.day === build.date) last.builds.push(build);
    else days.push({ day: build.date, builds: [build] });
  }
  return days;
}

/** "Today", "Yesterday" (in the page's language), else the release date. */
export function dayLabel(date: string, language: string, now: Date = new Date()): string {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
  if (!match) return date;
  const day = Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
  // Release dates are UTC days (the nightly job's `date -u`).
  const today = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  const diff = Math.round((day - today) / 86_400_000);
  if (diff === 0 || diff === -1) {
    try {
      const text = new Intl.RelativeTimeFormat(language, { numeric: "auto" }).format(diff, "day");
      return text.charAt(0).toLocaleUpperCase(language) + text.slice(1);
    } catch {
      return formatReleaseDate(date, language, now);
    }
  }
  return formatReleaseDate(date, language, now);
}

/** "Oct 11" (this year) or "Oct 11, 2025" in the page's language; the raw string when it is not a date. */
export function formatReleaseDate(date: string, language: string, now: Date = new Date()): string {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
  if (!match) return date;
  const value = new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3])));
  const sameYear = value.getUTCFullYear() === now.getUTCFullYear();
  try {
    return new Intl.DateTimeFormat(language, {
      month: "short",
      day: "numeric",
      year: sameYear ? undefined : "numeric",
      timeZone: "UTC",
    }).format(value);
  } catch {
    return date;
  }
}
