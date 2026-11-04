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
import type { UpdateHighlights, UpdateSurfaceActions } from "./updateHighlights";
import { UpdatedCard, UpdateReadyHighlights } from "./UpdateSurfaces";
import "../shared/pageBase.css";
import "./updateSurfaces.css";
import "./surface.css";

export type SurfaceKind = "ready" | "updated";

export const SurfaceOps = {
  get: "cmux.changelog.surface.get",
  size: "cmux.changelog.surface.size",
  openChangelog: "cmux.changelog.surface.openChangelog",
  dismiss: "cmux.changelog.surface.dismiss",
  stream: "cmux.changelog.surface.changes",
} as const;

/** `#/surface/ready` -> "ready"; null for any other route. */
export function parseSurface(hash: string): SurfaceKind | null {
  const match = /^#\/surface\/(ready|updated)\b/.exec(hash);
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
  const actions: UpdateSurfaceActions =
    kind === "updated"
      ? {
          openChangelog: () => call(SurfaceOps.openChangelog),
          dismiss: () => call(SurfaceOps.dismiss),
        }
      : { openChangelog: () => call(SurfaceOps.openChangelog) };
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
  const spans = kind === "updated" && client ? new SpanNotes(client, () => render(latest)) : null;
  let latest: UpdateHighlights | null = null;
  const render = (data: UpdateHighlights | null) => {
    latest = data;
    // Committed now, not on React's next task: the size below reads these rows. The card's page is
    // hidden until it reports (the host shows it once it has a height), so it gets no animation frame
    // to report from, and its rows may already have their size (no resize to observe).
    flushSync(() =>
      react.render(
        <UiProvider container={root} dir={languageDirection(strings.language)} overlayPosition="fixed">
          {data === null ? null : kind === "ready" ? (
            <UpdateReadyHighlights data={data} strings={strings} actions={actions} />
          ) : (
            <UpdatedCard
              data={data}
              span={spans?.notes(data.changelog)}
              strings={strings}
              actions={actions}
              closeButton={false}
              glass={false}
            />
          )}
        </UiProvider>,
      ),
    );
    observeCard();
    report();
  };
  // The host sizes the popover or the card slot to the content; 0 while there is nothing.
  // A scrolling card (the popover) reports its whole content, not the part the page view shows.
  // A short popover (`.wn-pop-brief`, no change list) also reports its own width, so the host is as
  // wide as its lines (Leo 2026-11-03: "stretched out wasted space"); 0 fills the host's width.
  // The Updated card reports its height once its words are final (the notes of the update's span
  // loaded, or none will): the host lays the card out at the first height it hears, so a first
  // report from the host's items, then the span's summary, moved the sidebar's list twice on a
  // relaunch (Leo 2026-11-04: "the restarted after nightly update does too many layout shifts").
  const settled = () => spans === null || spans.settled;
  let reported = "";
  const report = () => {
    if (!settled()) return;
    const card = root.querySelector<HTMLElement>(`[${CARD_SCROLL_ATTRIBUTE}]`);
    const height = Math.ceil(Math.max(root.getBoundingClientRect().height, card?.scrollHeight ?? 0));
    const width = card?.classList.contains("wn-pop-brief") ? Math.ceil(card.getBoundingClientRect().width) : 0;
    const key = `${height}x${width}`;
    if (key === reported) return;
    reported = key;
    call(SurfaceOps.size, { height, width });
  };
  const sizer = new ResizeObserver(report);
  sizer.observe(root);
  const observeCard = () => {
    const card = root.querySelector<HTMLElement>(`[${CARD_SCROLL_ATTRIBUTE}]`);
    if (card) sizer.observe(card);
    for (const child of card?.children ?? []) sizer.observe(child);
  };
  if (!client) return;
  void client.call<UpdateHighlights | null>(SurfaceOps.get, {}).then(render, () => render(null));
  void client.subscribe<UpdateHighlights | null>(SurfaceOps.stream, (data) => render(data));
}

/** The notes of an update's span (after `from`, up to `to`), newest first, loaded once per span;
    undefined until every build in it has loaded or is unavailable, and when none loaded (an
    older host without `cmux.changelog.*` here): the card then reads the host's items. */
/** How long the Updated card waits for its span's notes before it reports the host's items. */
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
    void store
      .start(span)
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
