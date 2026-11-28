// The page side of `cmux.widget/1` (the New Tab widget grid). The daemon owns everything that is
// state or policy: which widgets the person can place, where each tile is and at which size
// (`apps.widgets.layout.edit`, saved and broadcast to every page), and each widget's refresh budget
// (ticks only while shown, held batches). This client only asks and draws:
//
// - `cmux.apps.panels.widgets.list {place}` gives the widgets and the place's tiles; it is read
//   again on every `cmux.apps.panels.widgets.changed`, so every open page follows an edit.
// - Each placed tile mounts its app's widget (`cmux.apps.panels.mount {surface:"widget",
//   context:{place, size, instance, locale, timeZone}}`). Nothing mounts while no tile is placed.
// - A tile scrolled out of view or a hidden page reports `widgets.visible {mount_id, visible:false}`,
//   so its widget gets no ticks; shown again, it gets one catch-up tick.
// - Let it crash: `cmux.apps.panels.widgets.health {mount_id, stale}` marks a tile stale. It keeps
//   its last scene (dimmed, "Updating...") while the daemon mounts it again with a backoff; one
//   tile's failure never touches another.
import { isPageError, type PageClient } from "../../pages/shared/pageClient";
import { AppSceneMount } from "./appSceneMount";

export type WidgetSize = "small" | "medium" | "large";
export type WidgetPlace = "newtab" | "sidebar";

/** A widget an installed app offers (`apps.widgets.list`). */
export type WidgetInfo = {
  readonly app: string;
  readonly title: string;
  readonly sizes: readonly WidgetSize[];
  readonly defaultSize: WidgetSize;
  readonly everySeconds?: number;
  readonly symbol?: string;
  readonly description?: string;
};

/** One placed tile, in the person's order. */
export type WidgetTilePlacement = { readonly instance: string; readonly app: string; readonly size: WidgetSize };

/** One edit of the person's layout (the daemon's `edit`). */
export type WidgetLayoutEdit =
  | { op: "add"; app: string; size?: WidgetSize; before?: string }
  | { op: "remove"; instance: string }
  | { op: "resize"; instance: string; size: WidgetSize }
  | { op: "move"; instance: string; before?: string };

/** A tile's health: stale after its widget threw, with the daemon's retry. */
export type WidgetHealth = { readonly stale: boolean; readonly reason?: string; readonly retryMs?: number };

/** The edit mode's meter of one tile (`apps.widgets.meters`). */
export type WidgetMeter = {
  readonly instance: string;
  readonly everySeconds?: number;
  readonly ticks: number;
  readonly held: number;
  readonly visible: boolean;
  readonly failures: number;
};

export type WidgetsView = {
  /** The host lists widgets (an older host without the ops: false, and the page draws nothing). */
  readonly supported: boolean;
  /** The first list answered. */
  readonly listed: boolean;
  readonly widgets: readonly WidgetInfo[];
  readonly tiles: readonly WidgetTilePlacement[];
};

export const WIDGET_OPS = {
  list: "cmux.apps.panels.widgets.list",
  edit: "cmux.apps.panels.widgets.layout.edit",
  visible: "cmux.apps.panels.widgets.visible",
  meters: "cmux.apps.panels.widgets.meters",
  changed: "cmux.apps.panels.widgets.changed",
  health: "cmux.apps.panels.widgets.health",
} as const;

const NO_HEALTH: WidgetHealth = { stale: false };
const EMPTY_VIEW: WidgetsView = { supported: false, listed: false, widgets: [], tiles: [] };

function isSize(value: unknown): value is WidgetSize {
  return value === "small" || value === "medium" || value === "large";
}

export function readWidgets(value: unknown): WidgetInfo[] {
  const rows = (value as { widgets?: unknown } | null)?.widgets;
  if (!Array.isArray(rows)) return [];
  const seen = new Set<string>();
  const out: WidgetInfo[] = [];
  for (const row of rows as Record<string, unknown>[]) {
    if (!row || typeof row.app !== "string" || !row.app || seen.has(row.app)) continue;
    const sizes = Array.isArray(row.sizes) ? row.sizes.filter(isSize) : [];
    if (sizes.length === 0) continue;
    seen.add(row.app);
    const every = (row.refresh as { everySeconds?: unknown } | null | undefined)?.everySeconds;
    out.push({
      app: row.app,
      title: typeof row.title === "string" && row.title ? row.title : row.app,
      sizes,
      defaultSize: isSize(row.defaultSize) && sizes.includes(row.defaultSize) ? row.defaultSize : sizes[0]!,
      ...(typeof every === "number" && { everySeconds: every }),
      ...(typeof row.symbol === "string" && { symbol: row.symbol }),
      ...(typeof row.description === "string" && row.description && { description: row.description }),
    });
  }
  return out;
}

/** The place's tiles from a layout (`{revision, newtab: [...], sidebar: [...]}`). */
export function readTiles(value: unknown, place: WidgetPlace): WidgetTilePlacement[] {
  const items = (value as Record<string, unknown> | null | undefined)?.[place];
  if (!Array.isArray(items)) return [];
  const seen = new Set<string>();
  const out: WidgetTilePlacement[] = [];
  for (const item of items as Record<string, unknown>[]) {
    if (!item || typeof item.instance !== "string" || !item.instance || seen.has(item.instance)) continue;
    if (typeof item.app !== "string" || !item.app || !isSize(item.size)) continue;
    seen.add(item.instance);
    out.push({ instance: item.instance, app: item.app, size: item.size });
  }
  return out;
}

export function readMeters(value: unknown, tiles: ReadonlyMap<string, string>): WidgetMeter[] {
  const rows = (value as { meters?: unknown } | null)?.meters;
  if (!Array.isArray(rows)) return [];
  const out: WidgetMeter[] = [];
  for (const row of rows as Record<string, unknown>[]) {
    const instance = typeof row?.mount_id === "string" ? tiles.get(row.mount_id) : undefined;
    if (!instance) continue;
    out.push({
      instance,
      ...(typeof row.everySeconds === "number" && { everySeconds: row.everySeconds }),
      ticks: typeof row.ticks === "number" ? row.ticks : 0,
      held: typeof row.held === "number" ? row.held : 0,
      visible: row.visible !== false,
      failures: typeof row.failures === "number" ? row.failures : 0,
    });
  }
  return out;
}

/** A layout's tile order after moving `instance` to before `before` (the end when absent): what
 * the page draws until the daemon's answer comes back. */
function moved(tiles: readonly WidgetTilePlacement[], instance: string, before?: string): WidgetTilePlacement[] {
  const tile = tiles.find((t) => t.instance === instance);
  if (!tile) return [...tiles];
  const rest = tiles.filter((t) => t.instance !== instance);
  const at = before ? rest.findIndex((t) => t.instance === before) : -1;
  rest.splice(at < 0 ? rest.length : at, 0, tile);
  return rest;
}

/** One placed tile's mount and health. A resize is a new tile mount (the daemon remounts at the
 * new size), so the key is instance, app and size together. */
export class WidgetTileMount {
  readonly mount: AppSceneMount;
  private health: WidgetHealth = NO_HEALTH;
  private readonly listeners = new Set<() => void>();
  /** Shown on the page and in view; the last value sent for the live mount. */
  private visible = true;
  private sent: boolean | undefined;

  constructor(
    readonly placement: WidgetTilePlacement,
    private readonly client: PageClient | null,
    place: WidgetPlace,
    private readonly onMountId: (tile: WidgetTileMount, mountId: string | undefined) => void,
  ) {
    this.mount = new AppSceneMount(
      client,
      "widget",
      placement.app,
      { place, size: placement.size, instance: placement.instance, ...widgetLocaleContext() },
      (mountId) => {
        // The daemon starts a widget mount shown: only a hidden tile needs to say so.
        this.sent = mountId ? true : undefined;
        onMountId(this, mountId);
        if (mountId) this.sendVisible();
      },
    );
  }

  getHealth = (): WidgetHealth => this.health;
  subscribeHealth = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  setHealth(health: WidgetHealth): void {
    if (
      health.stale === this.health.stale &&
      health.reason === this.health.reason &&
      health.retryMs === this.health.retryMs
    )
      return;
    this.health = health.stale ? health : NO_HEALTH;
    for (const listener of this.listeners) listener();
  }

  /** The tile's view (in view and the page shown). Sent once per change, after the mount answers. */
  setVisible(visible: boolean): void {
    this.visible = visible;
    this.sendVisible();
  }

  private sendVisible(): void {
    const id = this.mount.id;
    if (!id || !this.client || this.sent === this.visible) return;
    this.sent = this.visible;
    void this.client.call(WIDGET_OPS.visible, { mount_id: id, visible: this.visible }).catch(() => undefined);
  }
}

const key = (tile: WidgetTilePlacement) => `${tile.instance}\n${tile.app}\n${tile.size}`;
let editSeq = 0;
/** The person's locale and time zone, for a widget's own formatting (a clock's hours, a calendar's
 * days); the mount context carries them so the widget never guesses from the daemon's machine. */
export function widgetLocaleContext(): { locale: string; timeZone: string } {
  return { locale: navigator.language, timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone };
}

/** A fresh idempotency key per edit: the daemon applies a retried edit once. */
export function widgetEditKey(): string {
  const random = globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  return `widget-edit-${random}-${++editSeq}`;
}

/** One page's widgets in one place: the listing, the placed tiles' mounts and their health. */
export class AppWidgetsClient {
  private view: WidgetsView = EMPTY_VIEW;
  private readonly listeners = new Set<() => void>();
  private readonly mounts = new Map<string, WidgetTileMount>();
  /** Daemon mount id to tile, for health and meters. */
  private readonly byMountId = new Map<string, WidgetTileMount>();
  private active = false;
  private lifetime = 0;
  private listing = 0;
  private edits = 0;
  /** Edits sent and not yet answered; a list read meanwhile may predate them. */
  private pending = 0;
  /** A list read while edits were pending kept its tiles out; read again once they settle. */
  private deferred = false;
  private stops: (() => void)[] = [];
  private healthWatch: Promise<void> | undefined;

  constructor(
    private readonly client: PageClient | null,
    readonly place: WidgetPlace = "newtab",
  ) {}

  getView = (): WidgetsView => this.view;
  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  /** The tile's mount (absent while the tile is not placed). */
  tile(instance: string): WidgetTileMount | undefined {
    for (const tile of this.mounts.values()) if (tile.placement.instance === instance) return tile;
    return undefined;
  }

  start(): void {
    if (this.active || !this.client) return;
    this.active = true;
    const lifetime = ++this.lifetime;
    void this.client
      .subscribe(WIDGET_OPS.changed, () => {
        if (this.live(lifetime)) void this.refresh();
      })
      .then((stop) => {
        if (!this.live(lifetime)) return stop();
        this.stops.push(stop);
        // A change between the eager list and the watch would be missed: read once more.
        void this.refresh();
      })
      .catch(() => undefined);
    void this.refresh();
  }

  stop(): void {
    this.active = false;
    ++this.lifetime;
    ++this.listing;
    for (const stop of this.stops) stop();
    this.stops = [];
    this.healthWatch = undefined;
    this.pending = 0;
    this.deferred = false;
    for (const tile of this.mounts.values()) tile.mount.stop();
    this.mounts.clear();
    this.byMountId.clear();
    this.view = EMPTY_VIEW;
    for (const listener of this.listeners) listener();
  }

  async refresh(): Promise<void> {
    if (!this.active || !this.client) return;
    const listing = ++this.listing;
    const edits = this.edits;
    let reply: unknown;
    let supported = true;
    try {
      reply = await this.client.call(WIDGET_OPS.list, { place: this.place });
    } catch (error) {
      // An older host without widget ops: the page shows no widgets and no edit affordance.
      supported = !(isPageError(error) && error.code === "cmux.protocol.unknown_op");
      reply = undefined;
      if (!this.active || listing !== this.listing) return;
      if (supported && this.view.listed) return; // A failed re-read keeps what is drawn.
    }
    if (!this.active || listing !== this.listing) return;
    // An edit sent while this list was in flight, or still unanswered, has a newer layout than the
    // list may hold: keep the drawn tiles, and read again once every edit has settled.
    if ((edits !== this.edits || this.pending > 0) && this.view.listed) {
      if (this.pending > 0) this.deferred = true;
      this.publish({ ...this.view, widgets: readWidgets(reply) });
      return;
    }
    const layout = (reply as { layout?: unknown } | undefined)?.layout;
    this.publish({ supported, listed: true, widgets: readWidgets(reply), tiles: readTiles(layout, this.place) });
  }

  /** The person's edit, from the click, drop or key handler itself (the host checks the gesture).
   * The page draws the daemon's answer; a move shows at once. A refused edit reads the layout again. */
  edit(edit: WidgetLayoutEdit): Promise<void> {
    if (!this.active || !this.client || !this.view.supported) return Promise.resolve();
    const lifetime = this.lifetime;
    const seq = ++this.edits;
    this.pending += 1;
    if (edit.op === "move") this.publish({ ...this.view, tiles: moved(this.view.tiles, edit.instance, edit.before) });
    if (edit.op === "remove")
      this.publish({ ...this.view, tiles: this.view.tiles.filter((t) => t.instance !== edit.instance) });
    return this.client
      .call<{ layout?: unknown }>(WIDGET_OPS.edit, { place: this.place, edit, idempotency_key: widgetEditKey() })
      .then(
        (reply) => {
          if (!this.live(lifetime)) return;
          this.settled();
          if (seq === this.edits && reply?.layout)
            this.publish({ ...this.view, tiles: readTiles(reply.layout, this.place) });
        },
        () => {
          if (!this.live(lifetime)) return;
          this.deferred = true;
          this.settled();
        },
      );
  }

  /** One edit answered; with none left, a list deferred meanwhile (or a refused edit) reads again. */
  private settled(): void {
    this.pending = Math.max(0, this.pending - 1);
    if (this.pending > 0 || !this.deferred) return;
    this.deferred = false;
    void this.refresh();
  }

  /** The edit mode's meter: this page's tiles with their interval, ticks and held batches. */
  async meters(): Promise<WidgetMeter[]> {
    if (!this.active || !this.client || this.byMountId.size === 0) return [];
    const tiles = new Map([...this.byMountId].map(([id, tile]) => [id, tile.placement.instance]));
    try {
      return readMeters(await this.client.call(WIDGET_OPS.meters, {}), tiles);
    } catch {
      return [];
    }
  }

  private live(lifetime: number): boolean {
    return this.active && lifetime === this.lifetime;
  }

  private publish(view: WidgetsView): void {
    this.reconcile(view.tiles);
    this.view = view;
    for (const listener of this.listeners) listener();
  }

  /** Mounts each placed tile once, ends a removed or resized one. No tile, no mount. */
  private reconcile(tiles: readonly WidgetTilePlacement[]): void {
    const wanted = new Set(tiles.map(key));
    for (const [k, tile] of this.mounts) {
      if (wanted.has(k)) continue;
      tile.mount.stop();
      this.mounts.delete(k);
    }
    for (const placement of tiles) {
      const k = key(placement);
      if (this.mounts.has(k)) continue;
      const tile = new WidgetTileMount(placement, this.client, this.place, (t, id) => this.mountIdChanged(t, id));
      this.mounts.set(k, tile);
      this.watchHealth();
      tile.mount.start();
    }
  }

  private mountIdChanged(tile: WidgetTileMount, mountId: string | undefined): void {
    for (const [id, t] of this.byMountId) if (t === tile) this.byMountId.delete(id);
    if (mountId) this.byMountId.set(mountId, tile);
  }

  /** The health stream, from the first tile on (no tile, no watch). */
  private watchHealth(): void {
    if (this.healthWatch || !this.client) return;
    const lifetime = this.lifetime;
    this.healthWatch = this.client
      .subscribe<{ mount_id?: unknown; stale?: unknown; reason?: unknown; retry_ms?: unknown }>(
        WIDGET_OPS.health,
        (event) => {
          if (!this.live(lifetime) || typeof event?.mount_id !== "string") return;
          this.byMountId.get(event.mount_id)?.setHealth({
            stale: event.stale === true,
            ...(typeof event.reason === "string" && { reason: event.reason }),
            ...(typeof event.retry_ms === "number" && { retryMs: event.retry_ms }),
          });
        },
      )
      .then((stop) => {
        if (this.live(lifetime)) this.stops.push(stop);
        else stop();
      })
      .catch(() => {
        // The next tile tries again.
        if (this.live(lifetime)) this.healthWatch = undefined;
      });
  }
}
