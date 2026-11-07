// The Updated card's hover preview (Leo 2026-11-07: "where is the hover for the What's New area? ...
// you hover over it and you get to, like, scroll through the thing if you want" / "Like a quick
// access scroll through of what's new. Right in that bottom left of the sidebar area."). Resting on
// the card opens a short, scrollable list of the update's changes inside the card's own glass, which
// grows upward from the card; a click on a row or on What's New opens the full page.
//
// This file holds the parts with no DOM: the rows the preview lists, and the hover intent that
// decides when it opens and closes.
import { changeItems, mergedView, readableChanges, readableUpdate } from "./model";
import type { ReleaseNotes, WhatsNewCategory } from "./types";
import type { UpdateHighlights } from "./updateHighlights";
import { hasCuratedChanges, isGenericEntry, isGenericWhatsNewEntry } from "./updateSummary";

/** One row of the preview: the change's title, and what its description adds (absent: none). */
export interface PreviewEntry {
  id: string;
  title: string;
  detail?: string;
  category?: WhatsNewCategory;
}

/** The rest on the card before the preview opens: the app's hover-card dwell
    (HoverCardTiming.showDelay), so passing over the card on the way to the footer opens nothing. */
export const PREVIEW_DWELL_MS = 400;
/** How long the preview stays after the pointer leaves the card, so a pointer that slips out over
    the card's edge and back does not close and reopen it. */
export const PREVIEW_GRACE_MS = 180;

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
    rows.push(entry);
  };
  if (span && span.length > 0) {
    // The generic entry leaves by its source identity before mergedView localizes its title: in
    // another language its title is not the English one (#37615 F1).
    const view = mergedView(span.map(withoutGenericEntry), language);
    const items = [...(view.hero ? [view.hero] : []), ...view.groups.flatMap((group) => group.items)];
    for (const item of items)
      add({ id: item.id, title: item.title, detail: item.summary || undefined, category: item.category });
    // A build with no reviewed entries reads its commits' readable titles, as the card's summary
    // does; one with reviewed entries reads those alone (#37615 F4).
    for (const build of span) {
      if (hasCuratedChanges(build)) continue;
      readableChanges(changeItems(build)).changes.forEach((change, index) =>
        add({ id: `${build.build}-${index}`, title: change.title, detail: change.description || undefined }),
      );
    }
    if (rows.length > 0) return rows;
  }
  const readable = readableUpdate(data);
  for (const item of [...readable.items, ...(readable.rest ?? [])]) {
    add({ id: item.id, title: item.title, detail: item.summary ?? undefined, category: item.category });
  }
  return rows;
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
    spoken, the host is the one source: the page's last word can be stale. */
export class PreviewIntent {
  private open = false;
  private hostKnown = false;
  private pageInside = false;
  private hostInside = false;
  private timer: unknown = undefined;

  constructor(
    private readonly onChange: (open: boolean) => void,
    private readonly timers: IntentTimers = realTimers,
    private readonly dwell = PREVIEW_DWELL_MS,
    private readonly grace = PREVIEW_GRACE_MS,
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
  }

  private get inside(): boolean {
    return this.hostKnown ? this.hostInside : this.pageInside;
  }

  private update(): void {
    this.cancel();
    if (this.inside === this.open) return;
    const next = this.inside;
    this.timer = this.timers.set(
      () => {
        this.timer = undefined;
        this.set(next);
      },
      next ? this.dwell : this.grace,
    );
  }

  private cancel(): void {
    if (this.timer === undefined) return;
    this.timers.clear(this.timer);
    this.timer = undefined;
  }

  private set(open: boolean): void {
    if (open === this.open) return;
    this.open = open;
    this.onChange(open);
  }
}
