import type { PageClient } from "../../pages/shared/pageClient";
import type { SceneAssetResolver } from "./SceneRenderer";
import { SceneStore, type SceneOp } from "./store";

export type AppPanel = { app: string; section: string; title: string; symbol?: string };
export type MountContext = { session_id: string; cwd?: string; branch?: string; harness?: string };
/** Where a mount shows (`cmux.apps.panels.mount {surface}`); the host resolves the app's implementation for it. */
export type MountSurface = "pane" | "sidebarSection" | "hoverCard" | "sessionInfoSection";
/** The scene stream's two events: an ops batch, or the mount's status (`loading`, `ready`,
 * `failed {reason}`, `disconnected {reason}`). */
export type SceneEvent =
  | { mount_id: string; ops: SceneOp[]; reset?: boolean }
  | { mount_id: string; status: "loading" | "ready" | "failed" | "disconnected"; reason?: string };
export const panelId = (panel: AppPanel): `app:${string}#${string}` => `app:${panel.app}#${panel.section}`;
/** One mounted scene as a host draws it (`SceneMount`). */
export type MountedScene = {
  store: SceneStore;
  dispatch: (node: string, event: string, payload?: unknown) => void;
  /** The failure row's Reload: runs the app's saved script again. Call it synchronously from the click. */
  reload: () => void;
  /** Reports the drawn height, so the host can size a native frame around the page (sent once per change). */
  layout: (height: number) => void;
  /** The mount's bundle images, once the host serves them (`asset_base` in the mount reply). */
  resolveAsset: SceneAssetResolver;
};
export type MountedPanel = MountedScene & { panel: AppPanel };
/** What `cmux.apps.panels.mount` takes: the surface, the app, the section of a sidebar or Session
 * Info mount, and the members the host adds to the mount's context. */
export type MountRequest = { surface: MountSurface; app: string; section?: string; context: object };

/** A bundle-relative path (already checked by the renderer) under the host's asset base, each
 * component encoded once, so a decoded `%2F` can never become a separator. */
export function bundleAssetURL(base: string, path: string): string | undefined {
  try {
    const parts = path.split("/").map((part) => decodeURIComponent(part));
    if (parts.some((part) => !part || part === "." || part === ".." || part.includes("/") || part.includes("\\")))
      return undefined;
    return base + parts.map(encodeURIComponent).join("/");
  } catch {
    return undefined;
  }
}
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

/** One mount's lifetime on the host: `start` mounts and subscribes to its scene, `release` ends
 * it. Events after `release`, or before the mount answers, go nowhere. */
export class AppSceneMount implements MountedScene {
  readonly store = new SceneStore();
  cancelled = false;
  /** The mount call failed or answered no id: the owner mounts again on its next list. */
  failed = false;
  private mountId?: string;
  private assetBase?: string;
  /** The drawn height the page measured last, and the one the host last heard. */
  private height?: number;
  private sentHeight?: number;
  private unsubscribe?: () => void;

  constructor(
    private readonly client: PageClient,
    private readonly request: MountRequest,
  ) {}

  dispatch = (node: string, event: string, payload?: unknown): void => {
    if (this.cancelled || !this.mountId) return;
    void this.client
      .call("cmux.apps.panels.dispatch", {
        mount_id: this.mountId,
        node,
        event,
        ...(payload !== undefined && { payload }),
      })
      .catch(() => undefined);
  };

  reload = (): void => {
    if (this.cancelled || !this.mountId) return;
    void this.client.call("cmux.apps.panels.reload", { mount_id: this.mountId }).catch(() => undefined);
  };

  layout = (height: number): void => {
    const rounded = Math.max(0, Math.ceil(height));
    if (this.cancelled || !Number.isFinite(rounded)) return;
    this.height = rounded;
    // Before the mount answers, the height waits for it (`start` sends it then).
    this.sendLayout();
  };

  resolveAsset: SceneAssetResolver = (path) => (this.assetBase ? bundleAssetURL(this.assetBase, path) : undefined);

  async start(): Promise<void> {
    const client = this.client;
    try {
      const result = await client.call<{ mount_id?: unknown; asset_base?: unknown }>("cmux.apps.panels.mount", {
        surface: this.request.surface,
        app: this.request.app,
        ...(this.request.section !== undefined && { section: this.request.section }),
        context: this.request.context,
      });
      if (typeof result?.mount_id !== "string" || !result.mount_id) {
        this.failed = true;
        return;
      }
      this.mountId = result.mount_id;
      if (typeof result.asset_base === "string" && result.asset_base.endsWith("/")) this.assetBase = result.asset_base;
      if (this.cancelled) {
        this.unmount();
        return;
      }
      const mountId = result.mount_id;
      const stop = await client.subscribe<SceneEvent>(
        "cmux.apps.panels.scene",
        (event) => {
          if (this.cancelled || event?.mount_id !== mountId) return;
          if ("status" in event) this.store.setStatus(event.status, event.reason);
          else if (Array.isArray(event.ops)) this.store.apply(event.ops, event.reset === true);
        },
        { mount_id: mountId },
      );
      if (this.cancelled) stop();
      else {
        this.unsubscribe = stop;
        this.sendLayout();
      }
    } catch (error) {
      this.failed = true;
      // The row says why, as the host's model does when its mount call fails.
      if (!this.cancelled) this.store.setStatus("failed", error instanceof Error ? error.message : String(error));
      this.unmount(); // A failed scene subscription must not leave a daemon mount alive.
    }
  }

  release(): void {
    this.cancelled = true;
    this.unsubscribe?.();
    this.unsubscribe = undefined;
    this.unmount();
  }

  private sendLayout(): void {
    const { mountId, height } = this;
    if (this.cancelled || !mountId || height === undefined || height === this.sentHeight) return;
    this.sentHeight = height;
    void this.client.call("cmux.apps.panels.layout", { mount_id: mountId, height }).catch(() => undefined);
  }

  private unmount(): void {
    if (!this.mountId) return;
    const mountId = this.mountId;
    this.mountId = undefined;
    void this.client.call("cmux.apps.panels.unmount", { mount_id: mountId }).catch(() => undefined);
  }
}

type Entry = { panel: AppPanel; mount: AppSceneMount };

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
    for (const entry of this.entries.values()) entry.mount.release();
    this.entries.clear();
    this.snapshot = EMPTY;
  }

  async refresh(): Promise<void> {
    if (!this.active || !this.client) return;
    const client = this.client;
    const listing = ++this.listing;
    let panels: AppPanel[];
    try {
      panels = readPanels(await client.call("cmux.apps.panels.list", {}));
    } catch {
      panels = [];
    } // An older host offers no sections and no user-facing error.
    if (!this.active || listing !== this.listing) return;
    const wanted = new Set(panels.map(panelId));
    for (const [id, entry] of this.entries) {
      if (wanted.has(id)) continue;
      entry.mount.release();
      this.entries.delete(id);
    }
    const next = panels.map((panel) => {
      const id = panelId(panel);
      let entry = this.entries.get(id);
      if (entry?.mount.failed) {
        entry.mount.release();
        this.entries.delete(id);
        entry = undefined;
      }
      if (!entry) {
        const mount = new AppSceneMount(client, {
          surface: "sessionInfoSection",
          app: panel.app,
          section: panel.section,
          context: this.context ?? {},
        });
        entry = { panel, mount };
        this.entries.set(id, entry);
        void mount.start();
      } else if (entry.panel.title !== panel.title || entry.panel.symbol !== panel.symbol) {
        entry.panel = panel;
      }
      // A separate snapshot prevents later metadata updates mutating a prior render's value.
      const { mount } = entry;
      return {
        panel: entry.panel,
        store: mount.store,
        dispatch: mount.dispatch,
        reload: mount.reload,
        layout: mount.layout,
        resolveAsset: mount.resolveAsset,
      };
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
