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
import { subjectArea, type AreaKey } from "./areas";
import type { UpdateHighlightItem, UpdateHighlights } from "./updateHighlights";
import {
  openParens,
  plainLine,
  readableChange,
  revertedSubject,
  shortTitle,
  tidyTitle,
  titleTail,
  withoutWorkCodes,
} from "./readableChange";

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
  /** Optional GitHub pull request URL for the shared PR chip. */
  pr?: string;
  docs?: string;
}

/** A change with the app area its subject names (areas.ts), none when it names no area. */
export interface AreaChange extends ChangeItem {
  area?: AreaKey;
}

export interface ReleaseView {
  hero?: ReleaseItem;
  groups: { category: WhatsNewCategory; items: ReleaseItem[] }[];
  /** Every change a person would notice (readable titles, each pull request once), listed by area. */
  changes: AreaChange[];
  /** How many changes were left out of `changes` as internal work (CI, tests, perf measurement). */
  internalChanges: number;
  /** Those changes, readable, each pull request once: "Under the hood". */
  underTheHood: ChangeItem[];
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
      .replace(/^["'“‘«]+|["'”’»]+$/gu, "")
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
    pr: entry.pr,
    docs: entry.docs,
  };
}

/** A highlight file's id as scripts/whats-new/digest.py writes it: lower case, other runs as "-".
    An id with no letter or digit to keep stays as it is, so two such ids never collide. */
function entryId(id: string): string {
  const normalized = id
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
  return normalized || id;
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
    the line it came from; a summary that repeats the title becomes the whole title; a long title
    with no summary ends at its first clause and the rest becomes the summary only when the rest
    reads as a sentence of its own.

    Leo 2026-11-02, on a What's New page of rows like "Fixes and improvements / This build brings
    fixes and improvements.", "Start the Native link in ad hoc builds / And name the check that
    refuses it" and "P0 RESIZE F1 part 1 of 2 / Closing a pane no longer …": "the 0 information
    density one". Every row says what changed: no filler row or line (GENERIC), no work-stream
    codes (WORK_CODES), no line that is a piece of its title (isFragment) or the title again. */
function readableItem(item: ReleaseItem, changes: ChangeItem[], machine: boolean): ReleaseItem | undefined {
  const clean = (text: string) => (machine ? readableChange(text).title : tidyTitle(text));
  let rawTitle = withoutWorkCodes(item.title);
  let rawSummary = item.summary.includes("\n") ? item.summary : withoutWorkCodes(item.summary);
  if (GENERIC_LINE.test(rawSummary.trim())) rawSummary = "";
  // A title that was only codes ("P0 RESIZE F1 part 1 of 2") or filler: its summary says the change.
  if ((!rawTitle || GENERIC_LINE.test(rawTitle)) && rawSummary && !rawSummary.includes("\n")) {
    rawTitle = rawSummary.replace(/[\s.]+$/u, "");
    rawSummary = "";
  }
  if (!rawTitle || GENERIC_LINE.test(rawTitle)) return undefined;
  if (machine && readableChange(rawTitle).internal) return undefined;
  let full = clean(rawTitle);
  let itemSummary = rawSummary;
  // An older pipeline cut a long title inside its parentheses and made the rest the summary
  // ("Routing follow-ups (trim recovered route" / "Prepared presets only, cap before split)."),
  // or at its first clause ("Bound the Feed" / "Its connect reads, Cloud chats and chat replay."):
  // the two read as the one line they were.
  const tail = itemSummary.trim();
  if (tail && !tail.includes("\n") && openParens(full) > 0 && openParens(`${full} ${tail}`) === 0) {
    full = `${full}, ${uncapitalized(tail).replace(/[\s.]+$/u, "")}`;
    itemSummary = "";
  } else if (
    machine &&
    tail &&
    !tail.includes("\n") &&
    isFragment(tail) &&
    // A line that says the title again is not its rest ("When you close a pane" / "When you close a
    // pane, its terminal keeps running…"): the echo rule below makes it the title.
    !echoKey(tail).startsWith(echoKey(full))
  ) {
    full = joinFragment(full, withoutWorkCodes(tail.replace(REF_TAIL, "")));
    itemSummary = "";
  }
  const stem = stemOf(full);
  const line = itemSummary && !itemSummary.includes("\n") ? clean(itemSummary) : "";
  // The summary repeats the title, maybe cut with "…" itself: the line the entry was made from.
  const echoes = !!line && (echoKey(line).startsWith(echoKey(full)) || echoKey(full).startsWith(echoKey(line)));
  const lineWhole = echoes && !line.endsWith("…");
  if (full.endsWith("…")) {
    const whole = lineWhole
      ? line
      : changes
          .map((c) => readableChange(c.title).title)
          .find((text) => !text.endsWith("…") && stemOf(text).startsWith(stem) && text.length > stem.length);
    full = whole ?? full.slice(0, -1).trim();
    // The cut title may have dropped the words that mark the line internal ("… the Chief Dock squash").
    if (machine && readableChange(full).internal) return undefined;
  } else if (lineWhole && echoKey(line).length > echoKey(full).length) {
    // "The host pressure warning is off by default" / "Host pressure warning is off by default;
    // turn it on from the Command Palette.": the summary is the whole line; it is the title.
    full = line.replace(/[\s.]+$/u, "");
  }
  let summary = echoes ? "" : itemSummary;
  let title = full;
  const short = shortTitle(full);
  if (short && short !== full && !distinctSummary(full, summary)) {
    const rest = capitalized(titleTail(full, short));
    if (!isFragment(rest)) {
      title = short;
      summary = rest;
    }
  }
  const category = machine && item.category === "improved" ? rowKind(title) : item.category;
  return { ...item, category, title, summary: distinctSummary(title, summary) };
}

/** The filler a build with nothing to say published (release-notes.py GENERIC_ENTRY and the PR
    description fallback): "Fixes and improvements", "This build brings fixes and improvements. …". */
const GENERIC_LINE =
  /^(?:fixes and improvements|this build brings fixes and improvements\b.*|maintenance and fixes)[.!]?$/iu;
/** Whether a line is only the filler a build with nothing to say published (GENERIC_LINE). */
export function isFiller(text: string): boolean {
  return GENERIC_LINE.test(text.trim());
}
/** A pull request or bead reference at the end of a cut summary. */
const REF_TAIL = /\s*\((?:[\w-]*#\d+|cx-[\w.]+)\)\s*$/u;
/** Words that only continue a sentence: a line that starts with one is the rest of its title. */
const JOINER =
  /^(?:and|or|but|nor|so|its|their|his|her|which|that|who|whose|with|without|because|while|even|then|to|for|from|in|on|of|by|plus|via|after|before|when|if|unless|until|as|also|than|into|at)\b/iu;

/** Whether `text` is a piece of a sentence rather than one: it starts lowercase, with a digit, a
    parenthesis or a joining word ("And name the check that refuses it", "(alternates) to Cloud",
    "8 under the run", "Its connect reads, …"), leaves a parenthesis unbalanced, or is under four
    words with no closing period ("Size and scale"). */
export function isFragment(text: string): boolean {
  const t = text.trim();
  if (!t) return false;
  if (/^(?:macOS|iOS|iPadOS|iCloud|iPhone|iPad)\b/u.test(t)) return false;
  if (/^[\p{Ll}\p{N}()[\]]/u.test(t) || JOINER.test(t)) return true;
  let depth = 0;
  for (const char of t) {
    if (char === "(") depth++;
    else if (char === ")" && --depth < 0) return true;
  }
  if (depth !== 0) return true;
  return t.split(/\s+/u).length < 4 && !/[.!?。！？]$/u.test(t);
}

/** The title with the piece of it its summary carried put back: "Bound the Feed" and "Its connect
    reads, Cloud chats and chat replay." read "Bound the Feed, its connect reads, Cloud chats and
    chat replay"; a piece that opens a parenthesis follows a space. */
function joinFragment(title: string, piece: string): string {
  const rest = piece.trim().replace(/[\s.]+$/u, "");
  if (!rest) return title;
  // short_title cuts at "," or ";", or before " (", " so ", " because " or " while ".
  return /^(?:\(|(?:so|because|while)\b)/iu.test(rest)
    ? `${title} ${uncapitalized(rest)}`
    : `${title}, ${uncapitalized(rest)}`;
}

/** The kind a machine line shows when the pipeline called it only "improved": a line that says what
    no longer goes wrong is Fixed, one that adds something is New, so the rows do not all carry the
    same arrow (Leo 2026-11-02: every row had the same icon). */
export function rowKind(title: string): WhatsNewCategory {
  if (
    /^(?:fix|fixes|fixed|repair|stop|stops)\b|\b(?:no longer|never|again|instead of|at once|not|(?:has|have|shows?|draws?|gets?) no)\b/iu.test(
      title,
    )
  )
    return "fixed";
  if (/^(?:add|adds|new|introduce|support|show|shows|star|let|lets|now|you can)\b/iu.test(title)) return "new";
  return "improved";
}

/** A line as two lines compare when one repeats the other: case and a leading article aside. */
function echoKey(text: string): string {
  return stemOf(text).replace(/^(?:the|a|an)\s+/u, "");
}

/** The update card's and popup's items (`UpdateHighlights`, at most three) as the page reads them:
    notes published before the readable rules (#21873) carry digest titles cut with "…",
    work-stream lines and titles repeated as their description. A summary or appcast line is
    machine-made; a What's New entry or highlight with its own id is a person's. */
export function readableUpdateItems(items: UpdateHighlightItem[]): UpdateHighlightItem[] {
  const seen = new Set<string>();
  return items.flatMap((item) => {
    const machine = /^(?:summary|appcast)-\d+$/.test(item.id);
    const readable = readableItem(
      { id: item.id, category: item.category, title: item.title, summary: item.summary ?? "" },
      [],
      machine,
    );
    const key = readable && titleKey(readable.title);
    if (!readable || !key || seen.has(key)) return [];
    seen.add(key);
    return [{ ...item, title: readable.title, summary: readable.summary || null }];
  });
}

/** The whole update as the card and popover read it: `items` and every change after them (`rest`)
    through the same rules, so no internal or cut line reaches the popover's list or the card's
    summary (review of #22099). A change in `rest` that repeats one shown above drops; `moreCount`
    keeps counting the changes the host did not send. */
export function readableUpdate(data: UpdateHighlights): UpdateHighlights {
  const items = readableUpdateItems(data.items);
  if (!data.rest) return { ...data, items };
  const rest = readableUpdateItems([...data.items, ...data.rest]).slice(items.length);
  return { ...data, items, rest, moreCount: Math.max(0, data.moreCount - (data.rest.length - rest.length)) };
}

function stemOf(text: string): string {
  return text.replace(/[.!…\s]+$/u, "").toLowerCase();
}

function capitalized(text: string): string {
  return text.charAt(0).toUpperCase() + text.slice(1);
}

/** "Prepared presets only" reads "prepared presets only"; a word with more capitals ("PR", "iOS") stays. */
function uncapitalized(text: string): string {
  const word = text.split(/\s/u)[0] ?? "";
  return /\p{Lu}/u.test(word.slice(1)) ? text : text.charAt(0).toLowerCase() + text.slice(1);
}

/** A subject without its "(#123)": how a revert names the change it undoes. */
function bareSubject(text: string): string {
  return text.replace(/\s*\(#\d+\)\s*$/u, "").trim();
}

/** The changes a person would notice, readable and each pull request (or title) once, and the
    internal ones left out (`hidden`, `internal` of them). A pull request reads as its human commit
    when it has one; a change reverted in the same span, and its revert, are left out. */
export function readableChanges<T extends ChangeItem>(items: T[]): { changes: T[]; internal: number; hidden: T[] } {
  const reverted = new Set(
    items.map((item) => revertedSubject(item.title)).flatMap((subject) => (subject ? [bareSubject(subject)] : [])),
  );
  const rows: { key: string; item: T; internal: boolean }[] = [];
  const byKey = new Map<string, number>();
  for (const item of items) {
    if (revertedSubject(item.title) || reverted.has(bareSubject(item.title))) continue;
    const readable = readableChange(item.title);
    const key = item.pr !== undefined ? `#${item.pr}` : readable.title.toLowerCase();
    // The notes mark a commit that touches only CI or tooling files internal, whatever its subject.
    const internal = readable.internal || item.internal === true;
    const row = {
      key,
      item: {
        ...item,
        title: readable.title,
        description: item.description ? distinctSummary(readable.title, item.description) : item.description,
      },
      internal,
    };
    const at = byKey.get(key);
    if (at === undefined) {
      byKey.set(key, rows.length);
      rows.push(row);
    } else if (rows[at]!.internal && !row.internal) rows[at] = row;
  }
  const hidden = rows.filter((r) => r.internal).map((r) => r.item);
  return { changes: rows.filter((r) => !r.internal).map((r) => r.item), internal: hidden.length, hidden };
}

/** The changes of `items` for the page: by area, internal work apart. */
function pageChanges(items: ChangeItem[]): Pick<ReleaseView, "changes" | "internalChanges" | "underTheHood"> {
  const { changes, internal, hidden } = readableChanges(
    items.map((item) => ({ ...item, area: subjectArea(item.title) })),
  );
  return { changes, internalChanges: internal, underTheHood: hidden };
}

export function releaseView(notes: ReleaseNotes, language: string): ReleaseView {
  // The reviewed document first, then the highlights it does not carry (a nightly digest drops
  // an entry the validator refuses), then the summary lines no highlight already says. Each as a
  // person reads it; internal work is left out.
  const raw = changeItems(notes);
  // A change the notes mark internal (release-notes.py tooling_only, backend plumbing) stays out of
  // the curated rows too, even from a digest or summary line published before that flag.
  const internal = new Set(
    raw.filter((c) => c.internal).map((c) => titleKey(plainLine(readableChange(c.title).title) || c.title)),
  );
  const items: ReleaseItem[] = [];
  const ids = new Set<string>();
  const seen = new Set<string>();
  // Ids compare as digest.py writes them, so a highlight file and its digest entry are one change
  // even when the entry's title is in another language.
  const add = (item: ReleaseItem, byId: boolean, machine: boolean) => {
    if (byId && ids.has(entryId(item.id))) return;
    const readable = readableItem(item, raw, machine);
    if (!readable) return;
    const key = titleKey(readable.title);
    if (seen.has(key) || (machine && [...internal].some((k) => k === key || k.startsWith(`${key} `)))) return;
    ids.add(entryId(item.id));
    seen.add(key);
    items.push(readable);
  };
  // A digest entry has no picture of its own in a nightly; its highlight file's picture (taken
  // from the change's pull request, release-notes.py) stands in. Ids match as digest.py makes them.
  const pictures = new Map(notes.highlights.map((h) => [entryId(h.id), fromHighlight(h).media]));
  // A digest the pipeline made from summary lines names its entries "summary-N".
  for (const entry of notes.whatsNew?.entries ?? []) {
    const item = fromEntry(entry, language);
    add(
      item.media ? item : { ...item, media: pictures.get(entryId(entry.id)) },
      false,
      entry.id.startsWith("summary-"),
    );
  }
  for (const highlight of notes.highlights) add(fromHighlight(highlight), true, false);
  for (const [index, line] of (notes.summary ?? []).entries()) {
    add(
      {
        id: `summary-${index}`,
        category: summaryCategory(line.group),
        title: line.title,
        summary: line.description ?? "",
      },
      true,
      true,
    );
  }
  uniqueIds(items, (item, n) => `${item.id}~${n}`);
  const hero = pickHero(items);
  const rest = items.filter((i) => i !== hero);
  const groups = CATEGORY_ORDER.map((category) => ({
    category,
    items: rest.filter((i) => i.category === category),
  })).filter((g) => g.items.length > 0);
  return { hero, groups, ...pageChanges(raw), count: items.length };
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
  const builds = new Map<ReleaseItem, string>();
  const seen = new Set<string>();
  const add = (item: ReleaseItem | undefined, build: string) => {
    const key = item && titleKey(item.title);
    if (!item || !key || seen.has(key)) return;
    seen.add(key);
    builds.set(item, build);
    items.push(item);
  };
  views.forEach((view, index) => {
    const build = notes[index]!.build;
    add(view.hero, build);
    view.groups.forEach((g) => g.items.forEach((item) => add(item, build)));
  });
  // Ids are per build: a digest names its entries "summary-0", "summary-1", … in every nightly, so
  // a day of nightlies repeats them. A repeated id gets its build, and the page's rows (keyed by
  // id) stay one per change; with keys repeated React kept stale rows and dropped others (Leo
  // 2026-11-01: the same changes listed twice on What's New).
  uniqueIds(items, (item, n) => `${item.id}@${builds.get(item)}${n > 2 ? `~${n}` : ""}`);
  const hero = pickHero(items);
  const rest = items.filter((i) => i !== hero);
  const groups = CATEGORY_ORDER.map((category) => ({
    category,
    items: rest.filter((i) => i.category === category),
  })).filter((g) => g.items.length > 0);
  return { hero, groups, ...pageChanges(notes.flatMap(changeItems)), count: items.length };
}

/** A title as two changes compare: case, runs of spaces and a closing period or ellipsis aside. */
export function titleKey(title: string): string {
  return title
    .normalize("NFKC")
    .replace(/[\u2018\u2019]/gu, "'")
    .replace(/\s+/gu, " ")
    .trim()
    .replace(/[.!…\s]+$/u, "")
    .toLowerCase();
}

/** Gives every item an id no earlier item has, in place: the first keeps its own, a repeat takes
    `renamed(item, n)` for n = 2, 3, … until one is free. */
function uniqueIds(items: ReleaseItem[], renamed: (item: ReleaseItem, n: number) => string): void {
  const used = new Set<string>();
  items.forEach((item, index) => {
    let id = item.id;
    for (let n = 2; used.has(id); n++) id = renamed(item, n);
    used.add(id);
    if (id !== item.id) items[index] = { ...item, id };
  });
}

/** A release day's title, Conductor style (2026-10-20): the curated headline of its newest build
    that has curated entries. A digest made from summary lines ("summary-N") is not curated: the
    pipeline heads it with its first line, a commit subject. Undefined when none has one: such a
    day lists its readable changes, or says "Maintenance and fixes" when it has none. */
export function releaseTitle(notes: ReleaseNotes[], language: string): string | undefined {
  for (const n of notes) {
    if (!n.whatsNew?.entries.some((e) => !e.id.startsWith("summary-"))) continue;
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
