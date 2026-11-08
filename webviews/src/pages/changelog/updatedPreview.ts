// The Updated card's hover preview (Leo 2026-11-07: "where is the hover for the What's New area? ...
// you hover over it and you get to, like, scroll through the thing if you want" / "Like a quick
// access scroll through of what's new. Right in that bottom left of the sidebar area."). Resting on
// the card opens a short, scrollable list of the update's changes inside the card's own glass, which
// grows upward from the card; a click on a row or on What's New opens the full page.
//
// This file holds the parts with no DOM: the rows the preview lists, and the hover intent that
// decides when it opens and closes.
import { areaOf, byArea, subjectArea, type AreaKey } from "./areas";
import { changeItems, echoKey, mergedView, readableChanges, readableUpdate } from "./model";
import { curatedArea } from "./SheetPage";
import type { ReleaseNotes, WhatsNewCategory } from "./types";
import type { UpdateHighlights } from "./updateHighlights";
import { GENERIC_ENTRY_ID, hasCuratedChanges, isGenericEntry, isGenericWhatsNewEntry } from "./updateSummary";

/** One row of the preview: the change's title, and what its description adds (absent: none). */
export interface PreviewEntry {
  id: string;
  title: string;
  detail?: string;
  category?: WhatsNewCategory;
  /** The app area the change is in (areas.ts), as What's New groups it; absent: Other. */
  area?: AreaKey;
}

/** The preview's rows under their areas, in What's New's order (``byArea``): Leo 2026-11-08, "the
    sections should be more obvious what's what". */
export function previewSections(entries: PreviewEntry[]): { area?: AreaKey; items: PreviewEntry[] }[] {
  return byArea(entries);
}

/** The rest on the card before the preview opens: the app's hover-card dwell
    (HoverCardTiming.showDelay), so passing over the card on the way to the footer opens nothing. */
export const PREVIEW_DWELL_MS = 400;
/** How long the preview stays after the pointer leaves the card, so a pointer that slips out over
    the card's edge and back does not close and reopen it. */
export const PREVIEW_GRACE_MS = 180;
/** How long the preview's close runs before the card hands its room back (the card's own curve,
    `--wn-preview-motion` in updateSurfaces.css); a pointer back on it within that reopens at once. */
export const PREVIEW_CLOSE_MS = 265;

/** The update's changes as the preview lists them: the notes of every build the update spans (each
    change once, newest build first), else what the host sent for the installed build. Internal work
    and the generic "Fixes and improvements" entry stay out, as on the card. Every change is listed
    (the list scrolls; #37615 F5): the preview promises the whole update. */
export function previewEntries(
  data: UpdateHighlights,
  span: ReleaseNotes[] | undefined,
  language: string,
): PreviewEntry[] {
  const rows: PreviewEntry[] = [];
  const seen = new Set<string>();
  const add = (entry: PreviewEntry) => {
    const key = entry.title.trim().toLowerCase();
    if (!key || seen.has(key) || isGenericEntry(entry.id, entry.title)) return;
    seen.add(key);
    const area = entry.area ?? areaOf(entry.title);
    const row = { ...entry, ...(area ? { area } : {}) };
    rows.push(row.detail && repeatsTitle(row.title, row.detail) ? { ...row, detail: undefined } : row);
  };
  if (span && span.length > 0) {
    // The generic entry leaves by its source identity before mergedView localizes its title: in
    // another language its title is not the English one (#37615 F1).
    const view = mergedView(span.map(withoutGenericEntry), language);
    const items = [...(view.hero ? [view.hero] : []), ...view.groups.flatMap((group) => group.items)];
    for (const item of items)
      add({
        id: item.id,
        title: item.title,
        detail: item.summary || undefined,
        category: item.category,
        area: curatedArea(item.title, item.summary),
      });
    // A build with no reviewed entries reads its commits' readable titles, as the card's summary
    // does; one with reviewed entries reads those alone (#37615 F4).
    for (const build of span) {
      if (hasCuratedChanges(build)) continue;
      // Each change's area from its commit subject, before the subject reads as a title, as the
      // page files it (model.ts pageChanges; review F2 of #38332).
      const items = changeItems(build).map((item) => ({ ...item, area: subjectArea(item.title) }));
      readableChanges(items).changes.forEach((change, index) =>
        add({
          id: `${build.build}-${index}`,
          title: change.title,
          detail: change.description || undefined,
          area: change.area,
        }),
      );
    }
    if (rows.length > 0) return rows;
  }
  const readable = readableUpdate(data);
  for (const item of [...readable.items, ...(readable.rest ?? [])]) {
    // The host's items come in the page's language: the generic entry leaves by its id alone, as
    // its title is the English one only in English (review F1 of #37894).
    if (item.id === GENERIC_ENTRY_ID) continue;
    add({ id: item.id, title: item.title, detail: item.summary ?? undefined, category: item.category });
  }
  return rows;
}

/** How many leading characters two lines share before they read as the same line: about what
    one cut row of the preview shows ("Show in Mini points the fl…"). */
const ECHO_PREFIX = 20;

/** Whether `detail` says `title` again, so the row would show the same words twice: each line is
    cut to one line, and a pull request's changelog sentence often restates its title ("Show in
    Mini points the floating mini at any chat, …" / "Show in Mini points the floating mini at any
    agent chat (…)"). Case, punctuation and spacing aside, the two lines repeat each other when one
    starts with the other or they open with the same ECHO_PREFIX characters. A leading article does
    not count, as in the notes' own comparison (``echoKey``). */
export function repeatsTitle(title: string, detail: string): boolean {
  const plain = (text: string) =>
    echoKey(text)
      .replace(/[^\p{L}\p{N}]+/gu, " ")
      .trim();
  const a = plain(title);
  const b = plain(detail);
  if (!a || !b) return false;
  let shared = 0;
  while (shared < a.length && shared < b.length && a[shared] === b[shared]) shared++;
  return shared >= Math.min(ECHO_PREFIX, a.length, b.length);
}

/** A build's notes without the generic What's New entry (``isGenericWhatsNewEntry``). */
function withoutGenericEntry(notes: ReleaseNotes): ReleaseNotes {
  const document = notes.whatsNew;
  if (!document?.entries.some(isGenericWhatsNewEntry)) return notes;
  return { ...notes, whatsNew: { ...document, entries: document.entries.filter((e) => !isGenericWhatsNewEntry(e)) } };
}

export interface IntentTimers {
  set(run: () => void, ms: number): unknown;
  clear(handle: unknown): void;
}

const realTimers: IntentTimers = {
  set: (run, ms) => setTimeout(run, ms),
  clear: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

/** When the preview opens: the pointer has rested on the card for the dwell; and when it closes:
    the pointer has been off it for the grace. Two sources say where the pointer is: the page's own
    pointer events, and the sidebar host's (its native tracking area; WebKit sends a page no pointer
    moves while another of the app's windows, a Chromium page's, has the key). Once the host has
    spoken, the host is the one source: the page's last word can be stale.

    A pointer that comes back while the close still runs reopens it at once, with no dwell: the list
    is still there under it, so leaving and coming back reads as one stay, never as close, wait, open
    (Leo 2026-11-08: "flicker upon hovering over what's new"). */
export class PreviewIntent {
  private open = false;
  /** The close the grace started is still running (``reopen``): a return skips the dwell. */
  private closing: unknown = undefined;
  private hostKnown = false;
  private pageInside = false;
  private hostInside = false;
  private timer: unknown = undefined;

  constructor(
    private readonly onChange: (open: boolean) => void,
    private readonly timers: IntentTimers = realTimers,
    private readonly dwell = PREVIEW_DWELL_MS,
    private readonly grace = PREVIEW_GRACE_MS,
    /** How long a close runs on screen (the card's 265 ms curve, `--wn-preview-motion`). */
    private readonly reopen = PREVIEW_CLOSE_MS,
  ) {}

  get isOpen(): boolean {
    return this.open;
  }

  /** The pointer is on the card, as the page sees it. */
  page(inside: boolean): void {
    this.pageInside = inside;
    this.update();
  }

  /** The pointer is on the card, as the sidebar host sees it. */
  host(inside: boolean): void {
    this.hostKnown = true;
    this.hostInside = inside;
    this.update();
  }

  /** Closes at once (Escape, a click that opens the full page, the card going away). */
  close(): void {
    this.cancel();
    this.set(false);
  }

  dispose(): void {
    this.cancel();
    this.endClosing();
  }

  private get inside(): boolean {
    return this.hostKnown ? this.hostInside : this.pageInside;
  }

  private update(): void {
    this.cancel();
    if (this.inside === this.open) return;
    const next = this.inside;
    if (next && this.closing !== undefined) return this.set(true);
    this.timer = this.timers.set(
      () => {
        this.timer = undefined;
        this.set(next);
        if (!next) this.closing = this.timers.set(() => (this.closing = undefined), this.reopen);
      },
      next ? this.dwell : this.grace,
    );
  }

  private cancel(): void {
    if (this.timer === undefined) return;
    this.timers.clear(this.timer);
    this.timer = undefined;
  }

  private endClosing(): void {
    if (this.closing === undefined) return;
    this.timers.clear(this.closing);
    this.closing = undefined;
  }

  private set(open: boolean): void {
    this.endClosing();
    if (open === this.open) return;
    this.open = open;
    this.onChange(open);
  }
}
