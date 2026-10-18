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
  /** Every change (titles with their pull requests), shown folded. */
  changes: ChangeItem[];
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

export function releaseView(notes: ReleaseNotes, language: string): ReleaseView {
  // The reviewed document first, then the highlights it does not carry (a nightly digest drops
  // an entry the validator refuses), then the summary lines no highlight already says.
  const items: ReleaseItem[] = (notes.whatsNew?.entries ?? []).map((e) => fromEntry(e, language));
  const ids = new Set(items.map((i) => i.id));
  const seen = new Set(items.map((i) => i.title.toLowerCase()));
  for (const highlight of notes.highlights) {
    if (ids.has(highlight.id) || seen.has(highlight.title.toLowerCase())) continue;
    seen.add(highlight.title.toLowerCase());
    items.push(fromHighlight(highlight));
  }
  for (const [index, line] of (notes.summary ?? []).entries()) {
    if (seen.has(line.title.toLowerCase())) continue;
    seen.add(line.title.toLowerCase());
    items.push({ id: `summary-${index}`, category: summaryCategory(line.group), title: line.title, summary: "" });
  }
  const hero = pickHero(items);
  const rest = items.filter((i) => i !== hero);
  const groups = CATEGORY_ORDER.map((category) => ({
    category,
    items: rest.filter((i) => i.category === category),
  })).filter((g) => g.items.length > 0);
  return { hero, groups, changes: changeItems(notes), count: items.length };
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
  const changeSeen = new Set<string>();
  const changes = views
    .flatMap((v) => v.changes)
    .filter((c) => {
      const key = c.pr ? `#${c.pr}` : c.title;
      if (changeSeen.has(key)) return false;
      changeSeen.add(key);
      return true;
    });
  return { hero, groups, changes, count: items.length };
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
