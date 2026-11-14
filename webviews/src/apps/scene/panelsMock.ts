// l10n-allow-file: browser mock app fixtures, not shipped UI.
import { pageError, type PageClient, type PageHandler } from "../../pages/shared/pageClient";
import { panelId, type AppPanel, type MountContext, type SceneEvent } from "./panelsClient";
import type { SceneOp } from "./store";

export const MOCK_APP_PANELS: readonly AppPanel[] = [
  { app: "samples/github-prs", section: "recent", title: "PRs in the last 24h", symbol: "arrow.triangle.pull" },
  { app: "samples/session", section: "details", title: "Session notes", symbol: "doc.text" },
];

/** The example widget the mock routes GitHub pull request calls to (examples/extensions/pr-card). */
export const MOCK_CHAT_WIDGET: AppPanel = {
  app: "local/pr-card",
  section: "cmux.chat.widget/1",
  title: "Pull request",
  symbol: "arrow.triangle.pull",
};

/** A pull request card's scene, as examples/extensions/pr-card draws it once loaded. */
export function mockChatWidgetScene(context?: Record<string, unknown>): SceneOp[] {
  const tool = (context?.tool ?? {}) as { input?: { owner?: string; repo?: string; pullNumber?: number } };
  const repo = tool.input?.owner && tool.input?.repo ? `${tool.input.owner}/${tool.input.repo}` : "acme/atlas";
  const number = tool.input?.pullNumber ?? 184;
  const rows = [
    {
      title: `${repo} #${number}`,
      subtitle: "Open · octo",
      symbol: "arrow.triangle.pull",
      tint: "success",
      onTap: true,
    },
    { title: "test (macos)", subtitle: "Failed", symbol: "xmark.circle", tint: "danger", onTap: true },
    { title: "lint", subtitle: "Passed", symbol: "checkmark.circle", tint: "success", onTap: true },
    { title: "test (linux)", subtitle: "Passed", symbol: "checkmark.circle", tint: "success", onTap: true },
  ];
  return [
    { op: "create", id: "root", type: "VStack", props: { spacing: 4 } },
    { op: "create", id: "title", type: "Text", props: { text: "Keep chat drafts on reconnect", font: "headline" } },
    ...rows.map((props, index): SceneOp => ({ op: "create", id: `row-${index}`, type: "Row", props })),
    { op: "create", id: "badge", type: "Badge", props: { text: "1 failed · 2 passed", tone: "danger" } },
    {
      op: "children",
      id: "root",
      children: ["title", "row-0", "badge", ...rows.slice(1).map((_, index) => `row-${index + 1}`)],
    },
    { op: "root", id: "root" },
  ];
}

export function mockPanelScene(panel: AppPanel, context?: MountContext): SceneOp[] {
  if (panel.section === MOCK_CHAT_WIDGET.section)
    return mockChatWidgetScene(context as Record<string, unknown> | undefined);
  const rows =
    panel.app === "samples/github-prs"
      ? [
          {
            title: "Keep chat drafts on reconnect",
            subtitle: "acme/atlas #184 · 12 min ago",
            symbol: "arrow.triangle.pull",
            onTap: true,
          },
          {
            title: "Show preview alongside the chat",
            subtitle: "acme/atlas #181 · 3 hours ago",
            symbol: "arrow.triangle.merge",
            onTap: true,
          },
          {
            title: "Refresh the repository list",
            subtitle: "acme/atlas #176 · 18 hours ago",
            symbol: "arrow.triangle.pull",
            onTap: true,
          },
        ]
      : [
          { title: "Project", subtitle: context?.cwd ?? "/projects/atlas", symbol: "folder" },
          { title: "Branch", subtitle: context?.branch ?? "feature/preview", symbol: "arrow.triangle.branch" },
          { title: "Next step", subtitle: "Review the preview layout", symbol: "checklist" },
        ];
  return [
    { op: "create", id: "root", type: "VStack", props: { spacing: 0 } },
    ...rows.map((props, index): SceneOp => ({ op: "create", id: `row-${index}`, type: "Row", props })),
    { op: "children", id: "root", children: rows.map((_, index) => `row-${index}`) },
    { op: "root", id: "root" },
  ];
}

/** A real PageClient-shaped mock, so ?mock exercises list, mount, subscription, scene reduction,
 * dispatch, and unmount through the production controller instead of injecting rendered rows. */
export class MockAppPanelsClient implements PageClient {
  panels: readonly AppPanel[] = MOCK_APP_PANELS;
  readonly dispatches: unknown[] = [];
  /** Every chat widget route the page asked for. */
  readonly routes: unknown[] = [];
  readonly reloads: string[] = [];
  readonly layouts: { mount_id: string; height: number }[] = [];
  private nextMount = 0;
  private seq = 0;
  private readonly mounts = new Map<string, { panel: AppPanel; context: MountContext }>();
  private readonly changed = new Set<(data: unknown, seq: number) => void>();
  private readonly scenes = new Map<string, Set<(data: unknown, seq: number) => void>>();

  async call<R>(op: string, input: unknown): Promise<R> {
    const params = input as Record<string, unknown>;
    let result: unknown = {};
    switch (op) {
      case "cmux.apps.panels.list":
        result = { panels: this.panels };
        break;
      case "cmux.apps.panels.route": {
        // As the daemon routes it: the example widget answers GitHub pull request calls only.
        const tool = params.tool as { name?: string } | undefined;
        const routed = typeof tool?.name === "string" && /^mcp__github__.*pull_request/.test(tool.name);
        result = {
          widget: routed
            ? {
                app: MOCK_CHAT_WIDGET.app,
                interface: MOCK_CHAT_WIDGET.section,
                title: MOCK_CHAT_WIDGET.title,
                symbol: MOCK_CHAT_WIDGET.symbol,
                context: { surface: "chatWidget", widget: { key: params.key }, tool: params.tool },
              }
            : null,
        };
        this.routes.push(params);
        break;
      }
      case "cmux.apps.panels.mount": {
        if (params.surface === "chatWidget") {
          if (params.app !== MOCK_CHAT_WIDGET.app) throw pageError("cmux.apps.not_found", "Unknown chat widget");
          const mountId = `mock-panel-${++this.nextMount}`;
          this.mounts.set(mountId, { panel: MOCK_CHAT_WIDGET, context: params.context as MountContext });
          result = { mount_id: mountId };
          break;
        }
        const panel = this.panels.find((entry) => entry.app === params.app && entry.section === params.section);
        if (!panel) throw pageError("cmux.apps.not_found", "Unknown app section");
        const mountId = `mock-panel-${++this.nextMount}`;
        this.mounts.set(mountId, { panel, context: params.context as MountContext });
        result = { mount_id: mountId };
        break;
      }
      case "cmux.apps.panels.unmount":
        this.mounts.delete(String(params.mount_id));
        break;
      case "cmux.apps.panels.dispatch":
        this.dispatches.push(params);
        break;
      case "cmux.apps.panels.reload":
        this.reloads.push(String(params.mount_id));
        break;
      case "cmux.apps.panels.layout":
        this.layouts.push({ mount_id: String(params.mount_id), height: Number(params.height) });
        break;
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
    return result as R;
  }

  async subscribe<E>(
    stream: string,
    receive: (data: E, seq: number) => void,
    filter?: Record<string, unknown>,
  ): Promise<() => void> {
    const listener = receive as (data: unknown, seq: number) => void;
    if (stream === "cmux.apps.panels.changed") {
      this.changed.add(listener);
      return () => {
        this.changed.delete(listener);
      };
    }
    if (stream !== "cmux.apps.panels.scene") throw pageError("cmux.protocol.unknown_op", stream);
    const mountId = String(filter?.mount_id);
    const mount = this.mounts.get(mountId);
    if (!mount) throw pageError("cmux.apps.not_found", "Unknown mount");
    let listeners = this.scenes.get(mountId);
    if (!listeners) this.scenes.set(mountId, (listeners = new Set()));
    listeners.add(listener);
    queueMicrotask(() => {
      if (listeners.has(listener))
        listener(
          { mount_id: mountId, ops: mockPanelScene(mount.panel, mount.context), reset: true } satisfies SceneEvent,
          ++this.seq,
        );
    });
    return () => {
      listeners.delete(listener);
      if (!listeners.size) this.scenes.delete(mountId);
    };
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => undefined;
  }

  setPanels(panels: readonly AppPanel[]): void {
    this.panels = panels;
    for (const listener of this.changed) listener(undefined, ++this.seq);
  }

  /** Sends a mount's status on its scene stream, as the host forwards its model's status. */
  status(mountId: string, status: "loading" | "ready" | "failed" | "disconnected", reason?: string): void {
    for (const listener of this.scenes.get(mountId) ?? [])
      listener({ mount_id: mountId, status, ...(reason !== undefined && { reason }) } satisfies SceneEvent, ++this.seq);
  }

  /** A mock local edit sends a replacement scene to every mount of the same contribution. */
  reload(panel: AppPanel, ops: SceneOp[]): void {
    for (const [mountId, mount] of this.mounts) {
      if (panelId(mount.panel) !== panelId(panel)) continue;
      for (const listener of this.scenes.get(mountId) ?? [])
        listener({ mount_id: mountId, ops, reset: true }, ++this.seq);
    }
  }
}
