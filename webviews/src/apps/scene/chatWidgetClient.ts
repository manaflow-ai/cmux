import type { PageClient } from "../../pages/shared/pageClient";
import { bundleAssetURL, type AppPanel, type MountedPanel, type MountSurface, type SceneEvent } from "./panelsClient";
import { SceneStore } from "./store";

/** The call a chat widget may draw under: its name and what it took and returned. */
export type ChatWidgetTool = { name: string; title?: string; status?: string; input?: unknown; output?: string };
/** What the page asks the daemon for: the widget of a tool call, or of a widget part an agent sent. */
export type ChatWidgetAsk =
  | { key: string; tool: ChatWidgetTool }
  | { key: string; app: string; props?: Record<string, unknown> };
/** The daemon's answer (`apps.chat_widgets.route`): which extension draws, and the context it gets. */
type RouteAnswer = { app: string; interface: string; title: string; symbol?: string; context: Record<string, unknown> };

function readAnswer(value: unknown): RouteAnswer | undefined {
  const widget = (value as { widget?: unknown } | null)?.widget as Partial<RouteAnswer> | null | undefined;
  if (!widget || typeof widget !== "object") return undefined;
  if (typeof widget.app !== "string" || !widget.app || typeof widget.title !== "string") return undefined;
  if (!widget.context || typeof widget.context !== "object") return undefined;
  return {
    app: widget.app,
    interface: String(widget.interface ?? ""),
    title: widget.title,
    ...(typeof widget.symbol === "string" && { symbol: widget.symbol }),
    context: widget.context,
  };
}

/**
 * One chat widget's mount. The daemon decides everything: which extension (if any) draws under this
 * call or part, and the context its render gets (`cmux.apps.panels.route`). The page mounts that
 * answer on the `chatWidget` surface and draws the scene it streams. No answer, an older host or a
 * failed route leaves the call as it always looked (`getSnapshot()` stays undefined).
 */
export class ChatWidgetMount {
  private snapshot: MountedPanel | undefined;
  private readonly listeners = new Set<() => void>();
  private active = false;
  private mountId?: string;
  private assetBase?: string;
  private height?: number;
  private sentHeight?: number;
  private unsubscribe?: () => void;
  private readonly store = new SceneStore();

  constructor(
    private readonly client: PageClient | null,
    private readonly ask: ChatWidgetAsk,
  ) {}

  getSnapshot = (): MountedPanel | undefined => this.snapshot;
  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  start(): void {
    if (this.active || !this.client) return;
    this.active = true;
    void this.run();
  }

  stop(): void {
    this.active = false;
    this.unsubscribe?.();
    this.unsubscribe = undefined;
    if (this.mountId) {
      const mountId = this.mountId;
      this.mountId = undefined;
      void this.client?.call("cmux.apps.panels.unmount", { mount_id: mountId }).catch(() => undefined);
    }
    if (this.snapshot) {
      this.snapshot = undefined;
      for (const listener of this.listeners) listener();
    }
  }

  private async run(): Promise<void> {
    const client = this.client!;
    let answer: RouteAnswer | undefined;
    try {
      answer = readAnswer(await client.call("cmux.apps.panels.route", this.ask));
    } catch {
      return; // An older host routes no widgets: the call looks as it always did.
    }
    if (!answer || !this.active) return;
    try {
      const result = await client.call<{ mount_id?: unknown; asset_base?: unknown }>("cmux.apps.panels.mount", {
        surface: "chatWidget" satisfies MountSurface,
        app: answer.app,
        context: answer.context,
      });
      if (typeof result?.mount_id !== "string" || !result.mount_id) return;
      this.mountId = result.mount_id;
      if (typeof result.asset_base === "string" && result.asset_base.endsWith("/")) this.assetBase = result.asset_base;
      if (!this.active) return this.stop();
      const mountId = result.mount_id;
      const stop = await client.subscribe<SceneEvent>(
        "cmux.apps.panels.scene",
        (event) => {
          if (!this.active || event?.mount_id !== mountId) return;
          if ("status" in event) this.store.setStatus(event.status, event.reason);
          else if (Array.isArray(event.ops)) this.store.apply(event.ops, event.reset === true);
        },
        { mount_id: mountId },
      );
      if (!this.active) {
        stop();
        return;
      }
      this.unsubscribe = stop;
      const panel: AppPanel = {
        app: answer.app,
        section: answer.interface,
        title: answer.title,
        ...(answer.symbol && { symbol: answer.symbol }),
      };
      this.snapshot = {
        panel,
        store: this.store,
        dispatch: (node, event, payload) => {
          if (!this.active || !this.mountId) return;
          void client
            .call("cmux.apps.panels.dispatch", {
              mount_id: this.mountId,
              node,
              event,
              ...(payload !== undefined && { payload }),
            })
            .catch(() => undefined);
        },
        reload: () => {
          if (!this.active || !this.mountId) return;
          void client.call("cmux.apps.panels.reload", { mount_id: this.mountId }).catch(() => undefined);
        },
        layout: (height) => {
          const rounded = Math.max(0, Math.ceil(height));
          if (!Number.isFinite(rounded)) return;
          this.height = rounded;
          this.sendLayout();
        },
        resolveAsset: (path) => (this.assetBase ? bundleAssetURL(this.assetBase, path) : undefined),
      };
      for (const listener of this.listeners) listener();
      this.sendLayout();
    } catch {
      // A refused mount (the extension went away between route and mount) shows nothing.
      this.stop();
    }
  }

  private sendLayout(): void {
    const { mountId, height } = this;
    if (!this.active || !mountId || height === undefined || height === this.sentHeight) return;
    this.sentHeight = height;
    void this.client?.call("cmux.apps.panels.layout", { mount_id: mountId, height }).catch(() => undefined);
  }
}
