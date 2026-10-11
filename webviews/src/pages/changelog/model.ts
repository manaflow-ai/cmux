// One release as the page shows it (cx-urd.61): an optional hero (the release's lead change, with
// its media and action) and the rest grouped New / Improved / Fixed / Security, then the raw
// commit subjects. The notes carry up to three sources, best first: the release's What's New
// document, the human highlights, the short summary lines. Pure: no DOM, no state.
import type { Highlight, LocalizedText, ReleaseNotes, WhatsNewCategory, WhatsNewEntry } from "./types";

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
  /** Commit subjects (the full history), shown folded. */
  changes: string[];
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

function fromEntry(entry: WhatsNewEntry, language: string): ReleaseItem {
  const light = admissibleSource(entry.media?.light);
  const dark = admissibleSource(entry.media?.dark);
  return {
    id: entry.id,
    category: entry.category,
    title: localized(entry.title, language),
    summary: localized(entry.summary, language),
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
    category: "new",
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

/** The lead change: the first New with media, else any item with media, else the first New, else the first item. */
function pickHero(items: ReleaseItem[]): ReleaseItem | undefined {
  return (
    items.find((i) => i.category === "new" && i.media) ??
    items.find((i) => i.media) ??
    items.find((i) => i.category === "new") ??
    items[0]
  );
}

export function releaseView(notes: ReleaseNotes, language: string): ReleaseView {
  let items: ReleaseItem[] = [];
  if (notes.whatsNew?.entries.length) {
    items = notes.whatsNew.entries.map((e) => fromEntry(e, language));
  } else {
    items = notes.highlights.map(fromHighlight);
    const seen = new Set(items.map((i) => i.title.toLowerCase()));
    for (const [index, line] of (notes.summary ?? []).entries()) {
      if (seen.has(line.title.toLowerCase())) continue;
      seen.add(line.title.toLowerCase());
      items.push({ id: `summary-${index}`, category: summaryCategory(line.group), title: line.title, summary: "" });
    }
  }
  const hero = pickHero(items);
  const rest = items.filter((i) => i !== hero);
  const groups = CATEGORY_ORDER.map((category) => ({
    category,
    items: rest.filter((i) => i.category === category),
  })).filter((g) => g.items.length > 0);
  return { hero, groups, changes: notes.changes, count: items.length };
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
