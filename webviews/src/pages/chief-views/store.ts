// The Chief view gallery's state owner. React reads it through `useSyncExternalStore`.
// - Agents: one `agents` read on start, then the app's `agents_changed` stream (no polling).
// - Fleet and Landing: read when a shown view needs them and on Refresh, never on a timer.
// - Layout: which views are turned on, the one in the pane and the one beside it (split or
//   sidebar). Client view state: kept in this page's localStorage, nothing reaches the app.
import { isPageError, type PageClient } from "../shared/pageClient";
import {
  ChiefViewsErrors,
  ChiefViewsOps,
  type ChiefAgent,
  type ChiefAgentsReply,
  type FleetReply,
  type LandingReply,
  type Placement,
} from "./types";

export type Load<T> =
  | { status: "idle" }
  | { status: "loading"; reply?: T }
  | { status: "ready"; reply: T }
  /** `configured` false: the person has not named a dashboard yet (Fleet only). */
  | { status: "unavailable"; configured?: boolean; message?: string; reply?: T }
  | { status: "failed"; reply?: T };

/** The data a view reads; the store loads only what a shown view names. */
export type ViewNeed = "agents" | "fleet" | "landing";

export type Layout = {
  /** The views turned on, in gallery order. */
  enabled: string[];
  /** The view in the pane; absent when every view is off. */
  main?: string;
  /** A second view beside it. */
  side?: { id: string; placement: Exclude<Placement, "pane"> };
};

export type ChiefViewsSnapshot = {
  agents: Load<ChiefAgent[]>;
  fleet: Load<FleetReply>;
  landing: Load<LandingReply>;
  layout: Layout;
  /** The gallery (every view, its description and where to open it) is showing. */
  catalog: boolean;
  /** The page has no host to ask. */
  offline: boolean;
};

/** What the store knows of the registry: ids in order and which start on. */
export type ViewDefaults = readonly { id: string; defaultOn: boolean }[];

export const LAYOUT_KEY = "cmux.chiefViews.layout";

function readLayout(views: ViewDefaults): Layout | undefined {
  try {
    const text = globalThis.localStorage?.getItem(LAYOUT_KEY);
    const value: unknown = text ? JSON.parse(text) : undefined;
    if (!value || typeof value !== "object") return undefined;
    const known = new Set(views.map((view) => view.id));
    const raw = value as Partial<Layout>;
    const enabled = Array.isArray(raw.enabled) ? raw.enabled.filter((id) => known.has(id)) : [];
    const main = raw.main && enabled.includes(raw.main) ? raw.main : enabled[0];
    const side =
      raw.side &&
      enabled.includes(raw.side.id) &&
      raw.side.id !== main &&
      ["split", "sidebar"].includes(raw.side.placement)
        ? raw.side
        : undefined;
    return { enabled: order(enabled, views), main, side };
  } catch {
    // No storage (a sandboxed page) or a malformed value: the defaults.
    return undefined;
  }
}

function writeLayout(layout: Layout) {
  try {
    globalThis.localStorage?.setItem(LAYOUT_KEY, JSON.stringify(layout));
  } catch {
    // No storage: the layout lasts as long as the page.
  }
}

const order = (ids: readonly string[], views: ViewDefaults) =>
  views.map((view) => view.id).filter((id) => ids.includes(id));

export function defaultLayout(views: ViewDefaults): Layout {
  const enabled = views.filter((view) => view.defaultOn).map((view) => view.id);
  return { enabled, main: enabled[0] };
}

export class ChiefViewsStore {
  private snapshot: ChiefViewsSnapshot;
  private listeners = new Set<() => void>();
  private unsubscribe?: () => void;
  private reads = { fleet: 0, landing: 0 };
  private readonly persist: boolean;

  constructor(
    private readonly client: PageClient | null,
    private readonly views: ViewDefaults,
    initial: { layout?: Layout; catalog?: boolean; persist?: boolean } = {},
  ) {
    this.persist = initial.persist ?? true;
    const layout = initial.layout ?? (this.persist ? readLayout(views) : undefined) ?? defaultLayout(views);
    this.snapshot = {
      agents: { status: "loading" },
      fleet: { status: "idle" },
      landing: { status: "idle" },
      layout,
      catalog: initial.catalog ?? layout.enabled.length === 0,
      offline: client === null,
    };
  }

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getSnapshot = () => this.snapshot;

  /** The first agents read, then the stream. */
  async start(): Promise<void> {
    if (!this.client) return this.set({ agents: { status: "unavailable" } });
    try {
      this.unsubscribe = await this.client.subscribe<ChiefAgentsReply>(ChiefViewsOps.agentsChanged, (reply) =>
        this.set({ agents: { status: "ready", reply: reply.agents ?? [] } }),
      );
    } catch {
      // An app without the stream still answers the read; the rows then show as of the read.
    }
    try {
      const reply = await this.client.call<ChiefAgentsReply>(ChiefViewsOps.agents, {});
      // A stream event that arrived first is as new as the read.
      if (this.snapshot.agents.status !== "ready") this.set({ agents: { status: "ready", reply: reply.agents ?? [] } });
    } catch {
      if (this.snapshot.agents.status !== "ready") this.set({ agents: { status: "failed" } });
    }
  }

  stop() {
    this.unsubscribe?.();
    this.unsubscribe = undefined;
  }

  /** Loads what the shown views need and has not been read yet. */
  need(needs: readonly ViewNeed[]) {
    if (needs.includes("fleet") && this.snapshot.fleet.status === "idle") void this.load("fleet");
    if (needs.includes("landing") && this.snapshot.landing.status === "idle") void this.load("landing");
  }

  /** Reads again what the shown views need (the Refresh button). */
  refresh(needs: readonly ViewNeed[]) {
    for (const need of ["fleet", "landing"] as const) {
      const status = this.snapshot[need].status;
      if (needs.includes(need) && status !== "loading") void this.load(need);
    }
  }

  private async load(kind: "fleet" | "landing"): Promise<void> {
    if (!this.client) return this.set({ [kind]: { status: "unavailable" } });
    const id = ++this.reads[kind];
    const previous = this.snapshot[kind];
    const reply = "reply" in previous ? previous.reply : undefined;
    this.set({ [kind]: { status: "loading", reply } });
    try {
      const op = kind === "fleet" ? ChiefViewsOps.fleet : ChiefViewsOps.landing;
      const value = await this.client.call<FleetReply | LandingReply>(op, {});
      if (id === this.reads[kind]) this.set({ [kind]: { status: "ready", reply: value } });
    } catch (error) {
      if (id !== this.reads[kind]) return;
      const unavailable =
        isPageError(error) &&
        (error.code === ChiefViewsErrors.fleetUnavailable || error.code === ChiefViewsErrors.landingUnavailable);
      if (unavailable) {
        const configured = (error.details as { configured?: unknown } | undefined)?.configured;
        this.set({
          [kind]: {
            status: "unavailable",
            configured: configured !== false,
            message: error.message,
            reply,
          },
        });
      } else this.set({ [kind]: { status: "failed", reply } });
    }
  }

  /** The person names the CI dashboard (Fleet's empty state); then Fleet reads it. */
  async setFleetURL(url: string): Promise<boolean> {
    if (!this.client) return false;
    try {
      await this.client.call(ChiefViewsOps.setFleetURL, { url: url.trim() });
    } catch {
      return false;
    }
    void this.load("fleet");
    return true;
  }

  /** Reveals the agent's chat or terminal (a row's click). */
  open(agent: ChiefAgent) {
    void this.client?.call(ChiefViewsOps.open, { kind: agent.kind, id: agent.id }).catch(() => {});
  }

  /** Opens a pull request on Home's right side (a card's click). */
  openURL(url: string) {
    void this.client?.call(ChiefViewsOps.openURL, { url }).catch(() => {});
  }

  setCatalog(open: boolean) {
    if (open !== this.snapshot.catalog) this.set({ catalog: open });
  }

  /** Turns a view on or off in the gallery. Off also takes it out of the pane and the side. */
  toggle(id: string) {
    const { layout } = this.snapshot;
    if (layout.enabled.includes(id)) {
      const enabled = layout.enabled.filter((other) => other !== id);
      const side = layout.side?.id === id ? undefined : layout.side;
      let main = layout.main === id ? enabled.find((other) => other !== side?.id) : layout.main;
      if (!main && side) main = side.id;
      this.setLayout({ enabled, main, side: side && side.id !== main ? side : undefined });
    } else {
      const enabled = order([...layout.enabled, id], this.views);
      this.setLayout({ ...layout, enabled, main: layout.main ?? id });
    }
  }

  /** Opens `id` in the pane, or beside the pane's view as a split or a sidebar (turning it on). */
  show(id: string, placement: Placement) {
    const { layout } = this.snapshot;
    const enabled = layout.enabled.includes(id) ? layout.enabled : order([...layout.enabled, id], this.views);
    if (placement === "pane" || !layout.main || layout.main === id) {
      // The view that was in the pane moves beside it when the new one was the side view.
      const side = layout.side?.id === id && layout.main ? { ...layout.side, id: layout.main } : layout.side;
      this.setLayout({ enabled, main: id, side: side?.id === id ? undefined : side });
    } else {
      this.setLayout({ enabled, main: layout.main, side: { id, placement } });
    }
  }

  /** Closes the view beside the pane. */
  closeSide() {
    if (this.snapshot.layout.side) this.setLayout({ ...this.snapshot.layout, side: undefined });
  }

  private setLayout(layout: Layout) {
    if (this.persist) writeLayout(layout);
    this.set({ layout });
  }

  private set(change: Partial<ChiefViewsSnapshot>) {
    this.snapshot = { ...this.snapshot, ...change };
    for (const listener of this.listeners) listener();
  }
}
