import type { PageClient } from "../../pages/shared/pageClient";
import { bundleAssetURL, type MountSurface, type SceneEvent } from "./panelsClient";
import { SceneStore } from "./store";

/** One app's scene for one place that is no listed section: the host resolves `app`'s
 * implementation for `surface` (`cmux.apps.panels.mount`), and refuses an app that is missing,
 * disabled, hidden or implements nothing there. A refused mount, a failed render and a lost
 * connection all read as the store's `failed` or `disconnected` status, so the page can draw its
 * own content in their place. It stays mounted until `stop` (the page goes, or the tab becomes
 * something else), never on a visibility change. */
export class AppSceneMount {
  readonly store = new SceneStore();
  private mountId?: string;
  private assetBase?: string;
  private unsubscribe?: () => void;
  private active = false;
  private lifetime = 0;

  constructor(
    private readonly client: PageClient | null,
    private readonly surface: MountSurface,
    private readonly app: string,
    private readonly context: Record<string, unknown> = {},
  ) {}

  start(): void {
    if (this.active) return;
    this.active = true;
    const lifetime = ++this.lifetime;
    if (!this.client) {
      this.store.setStatus("failed", "No app host on this page");
      return;
    }
    void this.mount(this.client, lifetime);
  }

  stop(): void {
    this.active = false;
    ++this.lifetime;
    this.unsubscribe?.();
    this.unsubscribe = undefined;
    this.unmount();
  }

  /** A click or key in the scene: the host runs the node's handler with the app's own scopes. */
  dispatch = (node: string, event: string, payload?: unknown): void => {
    if (!this.active || !this.mountId) return;
    void this.client
      ?.call("cmux.apps.panels.dispatch", {
        mount_id: this.mountId,
        node,
        event,
        ...(payload !== undefined && { payload }),
      })
      .catch(() => undefined);
  };

  resolveAsset = (path: string): string | undefined =>
    this.assetBase ? bundleAssetURL(this.assetBase, path) : undefined;

  private live(lifetime: number): boolean {
    return this.active && lifetime === this.lifetime;
  }

  private async mount(client: PageClient, lifetime: number): Promise<void> {
    try {
      const result = await client.call<{ mount_id?: unknown; asset_base?: unknown }>("cmux.apps.panels.mount", {
        surface: this.surface,
        app: this.app,
        context: this.context,
      });
      if (typeof result?.mount_id !== "string" || !result.mount_id) {
        if (this.live(lifetime)) this.store.setStatus("failed", "The app host answered with no mount");
        return;
      }
      const mountId = result.mount_id;
      if (!this.live(lifetime)) {
        void client.call("cmux.apps.panels.unmount", { mount_id: mountId }).catch(() => undefined);
        return;
      }
      this.mountId = mountId;
      if (typeof result.asset_base === "string" && result.asset_base.endsWith("/")) this.assetBase = result.asset_base;
      const stop = await client.subscribe<SceneEvent>(
        "cmux.apps.panels.scene",
        (event) => {
          if (!this.live(lifetime) || event?.mount_id !== mountId) return;
          if ("status" in event) this.store.setStatus(event.status, event.reason);
          else if (Array.isArray(event.ops)) this.store.apply(event.ops, event.reset === true);
        },
        { mount_id: mountId },
      );
      if (this.live(lifetime)) this.unsubscribe = stop;
      else stop();
    } catch (error) {
      if (!this.live(lifetime)) return;
      this.store.setStatus("failed", error instanceof Error ? error.message : String(error));
      this.unmount(); // A failed scene subscription must not leave a daemon mount alive.
    }
  }

  private unmount(): void {
    const mountId = this.mountId;
    if (!mountId) return;
    this.mountId = undefined;
    void this.client?.call("cmux.apps.panels.unmount", { mount_id: mountId }).catch(() => undefined);
  }
}
