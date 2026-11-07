import type { PageClient } from "../../pages/shared/pageClient";
import { SceneStore, type SceneOp } from "./store";

export type AppPanel = { app: string; section: string; title: string; symbol?: string };
export type MountContext = { session_id: string; cwd?: string; branch?: string; harness?: string };
export type SceneEvent = { mount_id: string; ops: SceneOp[]; reset?: boolean };
export const panelId = (panel: AppPanel): `app:${string}#${string}` => `app:${panel.app}#${panel.section}`;
export type MountedPanel = {
  panel: AppPanel;
  store: SceneStore;
  dispatch: (node: string, event: string, payload?: unknown) => void;
};
type Entry = MountedPanel & { cancelled: boolean; failed: boolean; mountId?: string; unsubscribe?: () => void };
const EMPTY: readonly MountedPanel[] = [];

function readPanels(value: unknown): AppPanel[] {
  const panels = (value as { panels?: unknown } | null)?.panels;
  if (!Array.isArray(panels)) return [];
  const seen = new Set<string>();
  return panels
    .filter((panel): panel is AppPanel => {
      if (
        !panel ||
        typeof panel !== "object" ||
        typeof panel.app !== "string" ||
        !panel.app ||
        typeof panel.section !== "string" ||
        !panel.section ||
        typeof panel.title !== "string"
      )
        return false;
      const id = panelId(panel);
      if (seen.has(id)) return false;
      seen.add(id);
      return true;
    })
    .map(({ app, section, title, symbol }) => ({ app, section, title, ...(typeof symbol === "string" && { symbol }) }));
}

/** One pane/context's mount lifetime. Scene events notify the touched scene nodes only, never the
 * panel list. Entries exist before mount starts so concurrent list updates cannot mount twice. */
export class AppPanelsClient {
  private snapshot: readonly MountedPanel[] = EMPTY;
  private readonly listeners = new Set<() => void>();
  private readonly entries = new Map<ReturnType<typeof panelId>, Entry>();
  private active = false;
  private lifetime = 0;
  private listing = 0;
  private unwatch?: () => void;

  constructor(
    private readonly client: PageClient | null,
    private readonly context: MountContext | undefined,
  ) {}
  getSnapshot = (): readonly MountedPanel[] => this.snapshot;
  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  start(): void {
    if (this.active || !this.client || !this.context?.session_id) return;
    this.active = true;
    const lifetime = ++this.lifetime;
    void this.client
      .subscribe("cmux.apps.panels.changed", () => {
        if (this.active && lifetime === this.lifetime) void this.refresh();
      })
      .then((stop) => {
        if (!this.active || lifetime !== this.lifetime) stop();
        else {
          this.unwatch = stop;
          // The eager list may have answered before the host installed this subscription.
          // Read once with the watch active so a change in that gap cannot be missed.
          void this.refresh();
        }
      })
      .catch(() => undefined);
    void this.refresh();
  }

  stop(): void {
    this.active = false;
    ++this.lifetime;
    ++this.listing;
    this.unwatch?.();
    this.unwatch = undefined;
    for (const entry of this.entries.values()) this.release(entry);
    this.entries.clear();
    this.snapshot = EMPTY;
  }

  async refresh(): Promise<void> {
    if (!this.active || !this.client) return;
    const listing = ++this.listing;
    let panels: AppPanel[];
    try {
      panels = readPanels(await this.client.call("cmux.apps.panels.list", {}));
    } catch {
      panels = [];
    } // An older host offers no sections and no user-facing error.
    if (!this.active || listing !== this.listing) return;
    const wanted = new Set(panels.map(panelId));
    for (const [id, entry] of this.entries) {
      if (wanted.has(id)) continue;
      this.release(entry);
      this.entries.delete(id);
    }
    const next = panels.map((panel) => {
      const id = panelId(panel);
      let entry = this.entries.get(id);
      if (entry?.failed) {
        this.release(entry);
        this.entries.delete(id);
        entry = undefined;
      }
      if (!entry) {
        const created: Entry = {
          panel,
          store: new SceneStore(),
          cancelled: false,
          failed: false,
          dispatch: (node, event, payload) => {
            if (!this.active || created.cancelled || !created.mountId) return;
            void this.client
              ?.call("cmux.apps.panels.dispatch", {
                mount_id: created.mountId,
                node,
                event,
                ...(payload !== undefined && { payload }),
              })
              .catch(() => undefined);
          },
        };
        entry = created;
        this.entries.set(id, entry);
        void this.mount(entry);
      } else if (entry.panel.title !== panel.title || entry.panel.symbol !== panel.symbol) {
        entry.panel = panel;
      }
      // A separate snapshot prevents later metadata updates mutating a prior render's value.
      return { panel: entry.panel, store: entry.store, dispatch: entry.dispatch };
    });
    if (
      next.length === this.snapshot.length &&
      next.every((entry, index) => {
        const old = this.snapshot[index];
        return old?.panel === entry.panel && old.store === entry.store;
      })
    )
      return;
    this.snapshot = next;
    for (const listener of this.listeners) listener();
  }

  private async mount(entry: Entry): Promise<void> {
    const client = this.client!;
    try {
      const result = await client.call<{ mount_id?: unknown }>("cmux.apps.panels.mount", {
        app: entry.panel.app,
        section: entry.panel.section,
        context: this.context,
      });
      if (typeof result?.mount_id !== "string" || !result.mount_id) {
        entry.failed = true;
        return;
      }
      entry.mountId = result.mount_id;
      if (entry.cancelled) {
        this.unmount(entry);
        return;
      }
      const mountId = result.mount_id;
      const stop = await client.subscribe<SceneEvent>(
        "cmux.apps.panels.scene",
        (event) => {
          if (entry.cancelled || event?.mount_id !== mountId || !Array.isArray(event.ops)) return;
          entry.store.apply(event.ops, event.reset === true);
        },
        { mount_id: mountId },
      );
      if (entry.cancelled) stop();
      else entry.unsubscribe = stop;
    } catch {
      entry.failed = true;
      this.unmount(entry); // A failed scene subscription must not leave a daemon mount alive.
    }
  }

  private unmount(entry: Entry): void {
    if (!entry.mountId) return;
    const mountId = entry.mountId;
    entry.mountId = undefined;
    void this.client?.call("cmux.apps.panels.unmount", { mount_id: mountId }).catch(() => undefined);
  }

  private release(entry: Entry): void {
    entry.cancelled = true;
    entry.unsubscribe?.();
    entry.unsubscribe = undefined;
    this.unmount(entry);
  }
}

let devClient: PageClient | null = null;
/** The browser dev entry installs its mock before React mounts. Production never selects a mock
 * from a URL, and tests/gallery can inject their own PageClient directly. */
export function installAppPanelsDevClient(client: PageClient): void {
  devClient = client;
}
export function appPanelsDevClient(): PageClient | null {
  return devClient;
}
