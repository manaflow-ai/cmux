// The update surface as its own document (cx-urd.61.2): the host opens the changelog bundle on
// `#/surface/ready` (the staged update card's highlights popover) in a small transparent page
// view, draws the material around it, and sizes itself to the height this page reports. Data:
// `cmux.changelog.surface.get` and the stream `cmux.changelog.surface.changes` (UpdateHighlights,
// or null while there is nothing to show). The popover also reads the notes of every build the
// update spans (`cmux.changelog.list` and `get`, the page's own ChangelogStore), so it lists the
// skipped nightlies' changes too.
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { languageDirection, UiProvider } from "../../ui/UiProvider";
import { routeChipHost } from "./ChangePullRequest";
import { CARD_SCROLL_ATTRIBUTE } from "../../scrollers";
import type { PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { ChangelogStore, compareVersions, type UpdateSpan } from "./store";
import type { ReleaseNotes } from "./types";
import type { ChangelogTarget, UpdateHighlights, UpdateSurfaceActions } from "./updateHighlights";
import { UpdateReadyHighlights } from "./UpdateSurfaces";
import "../shared/pageBase.css";
import "./updateSurfaces.css";
import "./surface.css";

export type SurfaceKind = "ready";

export const SurfaceOps = {
  get: "cmux.changelog.surface.get",
  size: "cmux.changelog.surface.size",
  openChangelog: "cmux.changelog.surface.openChangelog",
  stream: "cmux.changelog.surface.changes",
} as const;

/** `#/surface/ready` -> "ready"; null for any other route. */
export function parseSurface(hash: string): SurfaceKind | null {
  const match = /^#\/surface\/(ready)\b/.exec(hash);
  return match ? (match[1] as SurfaceKind) : null;
}

export function mountUpdateSurface(root: HTMLElement, kind: SurfaceKind, client: PageClient | null): void {
  routeChipHost(client);
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.documentElement.dataset.surface = kind;
  const call = (op: string, params: unknown = {}) => void client?.call(op, params).catch(() => undefined);
  // A row opens What's New at its change. Only a row's target goes to the host: a button's click
  // event passed along is not one.
  const openChangelog = (target?: ChangelogTarget) =>
    call(SurfaceOps.openChangelog, {
      ...(typeof target?.area === "string" ? { area: target.area } : {}),
      ...(typeof target?.title === "string" ? { title: target.title } : {}),
    });
  const actions: UpdateSurfaceActions = { openChangelog };
  const react = createRoot(root);
  // The popover reads the notes of every build the update spans and lists every change (Leo
  // 2026-11-05: "i can't even scroll through the changes").
  const spans = client ? new SpanNotes(client, () => render(latest)) : null;
  let latest: UpdateHighlights | null = null;
  const render = (data: UpdateHighlights | null) => {
    latest = data;
    // Committed now, not on React's next task: the size below reads these rows.
    flushSync(() =>
      react.render(
        <UiProvider container={root} dir={languageDirection(strings.language)} overlayPosition="fixed">
          {data === null ? null : (
            <UpdateReadyHighlights
              data={data}
              span={spans?.notes(data.changelog)}
              strings={strings}
              actions={actions}
            />
          )}
        </UiProvider>,
      ),
    );
    observeCard();
    report();
  };
  // The host sizes the popover to the content; 0 while there is nothing. A scrolling card reports
  // its whole content, not the part the page view shows, up to its hover-card cap (--wn-pop-max): a
  // long update never makes it taller than that. A short popover (`.wn-pop-brief`, no change list)
  // also reports its own width, so the host is as wide as its lines (Leo 2026-11-03: "stretched out
  // wasted space"); 0 fills the host's width. The popover waits for nothing: it opens on a hover
  // with the host's items, and its list grows under the cap when the span's notes come.
  let reported = "";
  const report = () => {
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
    older host without `cmux.changelog.*` here): the popover then reads the host's items. */
export class SpanNotes {
  private key = "";
  private store: ChangelogStore | null = null;
  private loaded: ReleaseNotes[] | undefined;

  constructor(
    private readonly client: PageClient,
    private readonly onChange: () => void,
  ) {}

  notes(span: UpdateSpan): ReleaseNotes[] | undefined {
    const key = `${span.from ?? ""}..${span.to}`;
    if (key !== this.key) this.load(key, span);
    return this.loaded;
  }

  private load(key: string, span: UpdateSpan): void {
    this.key = key;
    this.loaded = undefined;
    const store = new ChangelogStore(this.client);
    this.store = store;
    // The build list the host kept on disk first, then the network's.
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
        if (this.store === store) this.onChange();
      });
  }
}
