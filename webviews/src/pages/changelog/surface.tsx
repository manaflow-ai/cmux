// The update surfaces as their own documents (cx-urd.61.2): the host opens the changelog bundle on
// `#/surface/ready` (the staged update card's highlights popover) or `#/surface/updated` (the
// "cmux Updated!" card) in a small transparent page view, draws the material around it, and sizes
// itself to the height this page reports. Data: `cmux.changelog.surface.get` and the stream
// `cmux.changelog.surface.changes` (UpdateHighlights, or null while there is nothing to show). The
// Updated card also reads the notes of every build the update spans (`cmux.changelog.list` and
// `get`, the page's own ChangelogStore), so it sums up skipped nightlies too.
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { languageDirection, UiProvider } from "../../ui/UiProvider";
import { routeChipHost } from "./ChangePullRequest";
import { CARD_SCROLL_ATTRIBUTE } from "../../scrollers";
import { NATIVE_GLASS_ATTRIBUTE } from "../../ui/glass/glassState";
import type { PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { ChangelogStore, compareVersions, type UpdateSpan } from "./store";
import type { ReleaseNotes } from "./types";
import type { ChangelogTarget, RecentBuildRow, UpdateHighlights, UpdateSurfaceActions } from "./updateHighlights";
import { UpdatedCard, UpdateReadyHighlights } from "./UpdateSurfaces";
import { UpdatedNotes } from "./UpdatedNotes";
import { rememberRow, type CardDragHost, type CardPlace, type CardRow } from "./updatedCardDrag";
import "../shared/pageBase.css";
import "../../ui/glass/composerMaterial.css";
import "./updateSurfaces.css";
import "./surface.css";

/** `updated-notes`: the Updated card's changes in a popover beside the sidebar (UpdatedNotes.tsx). */
export type SurfaceKind = "ready" | "updated" | "updated-notes";

export const SurfaceOps = {
  get: "cmux.changelog.surface.get",
  size: "cmux.changelog.surface.size",
  openChangelog: "cmux.changelog.surface.openChangelog",
  dismiss: "cmux.changelog.surface.dismiss",
  goBack: "cmux.changelog.surface.goBack",
  builds: "cmux.changelog.surface.builds",
  stream: "cmux.changelog.surface.changes",
  /** The sidebar host's word on where the pointer is: `{inside: boolean}` (the Updated card). */
  pointer: "cmux.changelog.surface.pointer",
  /** The Updated card's drag: `{x, y, anchor?}`, CSS px from its rest; `anchor` on its release. */
  cardDrag: "cmux.changelog.surface.card.drag",
  /** Where the host rests the card: `{anchor, above, below, zoom}` (updatedCardDrag.ts CardPlace). */
  cardPlace: "cmux.changelog.surface.card.place",
} as const;

function isCardPlace(value: unknown): value is CardPlace {
  const place = value as Partial<CardPlace> | null;
  return (
    (place?.anchor === "top" || place?.anchor === "bottom") &&
    typeof place.above === "number" &&
    typeof place.below === "number"
  );
}

/** `#/surface/ready` -> "ready"; null for any other route. */
export function parseSurface(hash: string): SurfaceKind | null {
  const match = /^#\/surface\/(ready|updated-notes|updated)\b/.exec(hash);
  return match ? (match[1] as SurfaceKind) : null;
}

export function mountUpdateSurface(root: HTMLElement, kind: SurfaceKind, client: PageClient | null): void {
  routeChipHost(client);
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.documentElement.dataset.surface = kind;
  // The sidebar draws the Updated card's glass natively under this page (SidebarUpdatedCardHost):
  // the lens draws no wallpaper copy over it, not even around a tooltip's glass.
  if (kind === "updated") document.documentElement.setAttribute(NATIVE_GLASS_ATTRIBUTE, "");
  const call = (op: string, params: unknown = {}) => void client?.call(op, params).catch(() => undefined);
  // A row (the card's list, or its changes beside the sidebar) opens What's New at its change. Only a
  // row's target goes to the host: a button's click event passed along is not one.
  const openChangelog = (target?: ChangelogTarget) =>
    call(SurfaceOps.openChangelog, {
      ...(typeof target?.area === "string" ? { area: target.area } : {}),
      ...(typeof target?.title === "string" ? { title: target.title } : {}),
    });
  // The Updated card's changes go back to an earlier build (GoBack.tsx); the host answers.
  const goBack = (build?: string) =>
    (client?.call<{ failure?: string | null }>(SurfaceOps.goBack, build ? { build } : {}) ?? Promise.resolve(null)).then(
      (answer) => answer?.failure ?? null,
    );
  const builds = () =>
    (client?.call<{ builds?: RecentBuildRow[] }>(SurfaceOps.builds, { limit: 6 }) ?? Promise.resolve(null)).then(
      (answer) => answer?.builds ?? [],
    );
  const actions: UpdateSurfaceActions =
    kind === "updated"
      ? { openChangelog, dismiss: () => call(SurfaceOps.dismiss) }
      : kind === "updated-notes"
        ? { openChangelog, goBack, builds }
        : { openChangelog };
  // The sidebar host draws the Updated card's x natively (SidebarUpdatedCardHost: WebKit shows no
  // hover and takes no first click while a Chromium page's window has the key). Escape closes the
  // card once the page has the keyboard (a click into it).
  if (kind === "updated") {
    document.addEventListener("keydown", (event) => {
      if (event.key !== "Escape" || event.defaultPrevented || event.isComposing || latest === null) return;
      event.preventDefault();
      actions.dismiss?.();
    });
  }
  const react = createRoot(root);
  // Every surface reads the notes of every build the update spans: the card sums them up, the
  // popovers list every change (Leo 2026-11-05: "i can't even scroll through the changes").
  const spans = client ? new SpanNotes(client, () => render(latest)) : null;
  let latest: UpdateHighlights | null = null;
  // The Updated card's hover preview: where the host says the pointer is, and the room the open
  // preview asks for above the card's slot (reported with the card's height).
  let hostPointer: boolean | undefined;
  let overlay = 0;
  let glass = 0;
  // The card's drag (updatedCardDrag.ts): the host says where the card rests and moves its view.
  let place: CardPlace | undefined;
  const drop = (row: CardRow, offset: { x: number; y: number }) =>
    call(SurfaceOps.cardDrag, { x: offset.x, y: offset.y, anchor: row });
  const drag: CardDragHost = {
    place: () => place,
    move: (offset) => call(SurfaceOps.cardDrag, { x: offset.x, y: offset.y }),
    drop,
    dismiss: () => actions.dismiss?.(),
  };
  const previewSize = (height: number) => {
    if (height === overlay) return;
    overlay = height;
    report();
  };
  const previewGlass = (height: number) => {
    if (height === glass) return;
    glass = height;
    report();
  };
  const render = (data: UpdateHighlights | null) => {
    latest = data;
    // Committed now, not on React's next task: the size below reads these rows. The host draws the
    // card's page only once it reports, so the report must not wait for an animation frame, and its
    // rows may already have their size (no resize to observe).
    flushSync(() =>
      react.render(
        <UiProvider container={root} dir={languageDirection(strings.language)} overlayPosition="fixed">
          {data === null ? null : kind === "ready" ? (
            <UpdateReadyHighlights
              data={data}
              span={spans?.notes(data.changelog)}
              strings={strings}
              actions={actions}
            />
          ) : kind === "updated-notes" ? (
            <UpdatedNotes data={data} span={spans?.notes(data.changelog)} strings={strings} actions={actions} />
          ) : (
            <UpdatedCard
              data={data}
              span={spans?.notes(data.changelog)}
              strings={strings}
              actions={actions}
              closeButton={false}
              glass={false}
              hostPointer={hostPointer}
              onPreviewSize={previewSize}
              onPreviewGlass={previewGlass}
              anchor={place?.anchor}
              drag={place ? drag : undefined}
              notesLoading={spans !== null && !spans.settled}
            />
          )}
        </UiProvider>,
      ),
    );
    observeCard();
    report();
  };
  // The host sizes the popover or the card slot to the content; 0 while there is nothing.
  // A scrolling card (the popover) reports its whole content, not the part the page view shows, up
  // to its hover-card cap (--wn-pop-max): a long update never makes it taller than that.
  // A short popover (`.wn-pop-brief`, no change list) also reports its own width, so the host is as
  // wide as its lines (Leo 2026-11-03: "stretched out wasted space"); 0 fills the host's width.
  // The Updated card reports its height as soon as it has its data: its title is final then, and
  // its change line holds its one line with a quiet indicator until the span's notes come (or the
  // load gives up and the host's items stand in), so the words swap in at the same height. The host
  // draws the card (its glass and this page) only from that first report, so the card never shows
  // as blank glass while this page loads (Leo 2026-11-09: "it should have the updated to Nightly
  // already loaded in, instead of just having a blank glass bit"). It once waited for the notes to
  // report at all, since the host's items and then the span's summary moved the sidebar's list twice
  // (Leo 2026-11-04); the held line keeps that fixed.
  // The changes beside the sidebar report once their list is final. The popover waits for nothing:
  // it opens on a hover with the host's items, and its list grows under the cap when the span's
  // notes come (they load as the update stages, before any hover).
  const settled = () => kind === "ready" || spans === null || spans.settled;
  let reported = "";
  const report = () => {
    if (kind === "updated") {
      // Nothing to show yet: the host keeps the card undrawn, not drawn and then emptied.
      if (latest === null && reported === "") return;
      // The card's own height, without its hover preview (the slot keeps the card's room while the
      // preview opens over the list), the room the open preview asks for (`overlay`, 0 closed), and
      // the preview's height once open (`preview`, 0 closing), the host's glass behind the page.
      // Rounded, not ceiled: mid-motion the preview's height is fractional, and a ceiled difference
      // read one pixel over the card's (49 for 48), so the slot grew a pixel and moved the list.
      const open = root.querySelector<HTMLElement>(".wn-preview")?.getBoundingClientRect().height ?? 0;
      const height = Math.round(root.getBoundingClientRect().height - open);
      const key = `${height}x0x${overlay}x${glass}`;
      if (key === reported) return;
      reported = key;
      call(SurfaceOps.size, { height, width: 0, overlay, preview: glass });
      return;
    }
    if (!settled()) return;
    const scroller = root.querySelector<HTMLElement>(`[${CARD_SCROLL_ATTRIBUTE}]`);
    const pop = root.querySelector<HTMLElement>(".wn-pop");
    // The whole content: what shows, plus what the scroller hides past its edge.
    const whole = root.getBoundingClientRect().height + (scroller ? scroller.scrollHeight - scroller.clientHeight : 0);
    // Read through the page's own window: the surface may mount in a document that isn't the global one.
    const style = pop ? root.ownerDocument.defaultView?.getComputedStyle(pop) : undefined;
    const cap = style ? Number.parseFloat(style.getPropertyValue("--wn-pop-max")) : Number.NaN;
    const height = Math.ceil(Number.isFinite(cap) ? Math.min(whole, cap) : whole);
    const width = pop?.classList.contains("wn-pop-brief") ? Math.ceil(pop.getBoundingClientRect().width) : 0;
    const key = `${height}x${width}`;
    if (key === reported) return;
    reported = key;
    call(SurfaceOps.size, { height, width });
  };
  const sizer = new ResizeObserver(report);
  sizer.observe(root);
  const observeCard = () => {
    const card = kind === "updated" ? null : root.querySelector<HTMLElement>(`[${CARD_SCROLL_ATTRIBUTE}]`);
    if (card) sizer.observe(card);
    for (const child of card?.children ?? []) sizer.observe(child);
  };
  if (!client) return;
  void client.call<UpdateHighlights | null>(SurfaceOps.get, {}).then(render, () => render(null));
  void client.subscribe<UpdateHighlights | null>(SurfaceOps.stream, (data) => render(data));
  if (kind === "updated") {
    // An older host has no pointer stream: the page's own pointer events decide.
    void client
      .subscribe<{ inside?: boolean } | null>(SurfaceOps.pointer, (event) => {
        if (typeof event?.inside !== "boolean" || event.inside === hostPointer) return;
        hostPointer = event.inside;
        render(latest);
      })
      .catch(() => undefined);
    // An older host sends no place: the card stays at the bottom and does not drag.
    void client
      .subscribe<unknown>(SurfaceOps.cardPlace, (event) => {
        if (!isCardPlace(event)) return;
        const moved = event.anchor !== place?.anchor;
        place = event;
        document.documentElement.dataset.cardAnchor = event.anchor;
        // The host's place is the card's: its copy (cmux.sidebar.updatedCard.anchor) outlives the
        // page, whose storage does not (a non-persistent website data store). The page's copy (the
        // toasts' anchorMemory) mirrors it and never moves the card (review F1 of #37669).
        rememberRow(event.anchor);
        if (moved) render(latest);
      })
      .catch(() => undefined);
  }
}

/** The notes of an update's span (after `from`, up to `to`), newest first, loaded once per span;
    undefined until every build in it has loaded or is unavailable, and when none loaded (an
    older host without `cmux.changelog.*` here): the card then reads the host's items. */
/** How long the Updated card's change line waits for its span's notes before the host's items stand in
    (its loading indicator never stays longer). */
export const SPAN_SETTLE_MS = 1500;

export class SpanNotes {
  private key = "";
  private store: ChangelogStore | null = null;
  private loaded: ReleaseNotes[] | undefined;
  /** The span's notes loaded, failed, came back empty or took too long: the card's words are final. */
  settled = false;

  constructor(
    private readonly client: PageClient,
    private readonly onChange: () => void,
  ) {}

  notes(span: UpdateSpan): ReleaseNotes[] | undefined {
    const key = `${span.from ?? ""}..${span.to}`;
    if (key !== this.key) this.load(key, span);
    return this.loaded;
  }

  /** The card's words are final now (the notes, or the host's items): it renders and reports. */
  settle(): void {
    if (this.settled) return;
    this.settled = true;
    this.onChange();
  }

  private load(key: string, span: UpdateSpan): void {
    this.key = key;
    this.loaded = undefined;
    // A new span's words are not final until its own notes answer.
    this.settled = false;
    const store = new ChangelogStore(this.client);
    this.store = store;
    // Notes that never answer leave the card showing the host's items after a while.
    setTimeout(() => {
      if (this.store === store) this.settle();
    }, SPAN_SETTLE_MS);
    // The build list the host kept on disk first: after a relaunch the network's answered after the
    // card had drawn, so the card reported the host's items and then the span's notes (two heights).
    void store
      .start(span, { cachedFirst: true })
      .then(() => store.firstScreen())
      .then(() => {
        if (this.store !== store) return;
        const snapshot = store.getSnapshot();
        const notes = snapshot.inSpan.flatMap((build) => snapshot.loaded[build] ?? []);
        if (notes.length > 0) this.loaded = notes.sort((a, b) => compareVersions(b.shortVersion, a.shortVersion));
      })
      .catch(() => undefined)
      .finally(() => {
        if (this.store !== store) return;
        if (this.settled) this.onChange();
        else this.settle();
      });
  }
}
