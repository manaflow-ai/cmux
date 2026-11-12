// l10n-allow-file: browser mock app fixtures, not shipped UI.
import { pageError, type PageClient, type PageHandler } from "../../pages/shared/pageClient";
import { panelId, type AppPanel, type MountContext, type SceneEvent } from "./panelsClient";
import type { SceneOp } from "./store";

export const MOCK_APP_PANELS: readonly AppPanel[] = [
  { app: "samples/github-prs", section: "recent", title: "PRs in the last 24h", symbol: "arrow.triangle.pull" },
  { app: "samples/session", section: "details", title: "Session notes", symbol: "doc.text" },
];

/** The New Tab widgets the mock lists (`cmux.newtab.widget/1`): the example clock
 * (examples/extensions/clock), a wide list, and one whose scene breaks the interface's node cap. */
export const NEW_TAB_WIDGET_INTERFACE = "cmux.newtab.widget/1";
export const MOCK_NEWTAB_WIDGETS: readonly AppPanel[] = [
  { app: "manaflow-ai/clock", section: NEW_TAB_WIDGET_INTERFACE, title: "Clock", symbol: "clock", size: "small" },
  {
    app: "samples/github-prs",
    section: NEW_TAB_WIDGET_INTERFACE,
    title: "Review requests",
    symbol: "arrow.triangle.pull",
    size: "wide",
  },
  { app: "samples/too-big", section: NEW_TAB_WIDGET_INTERFACE, title: "Stocks", symbol: "chart.line.uptrend.xyaxis" },
];

/** What the example clock app draws (examples/extensions/clock/src/main.ts): the time in one Text
 * node (the only node a tick updates), the date under it. */
export function mockClockScene(now: number): SceneOp[] {
  const time = new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit" }).format(now);
  const date = new Intl.DateTimeFormat("en-US", { weekday: "long", month: "long", day: "numeric" }).format(now);
  return [
    { op: "create", id: "clock", type: "VStack", props: { spacing: 0, alignment: "leading" } },
    {
      op: "create",
      id: "time",
      type: "Text",
      props: { text: time, font: "title2", weight: "semibold", monospaced: true },
    },
    { op: "create", id: "date", type: "Text", props: { text: date, font: "caption", color: "secondary" } },
    { op: "children", id: "clock", children: ["time", "date"] },
    { op: "root", id: "clock" },
  ];
}

/** The mock widget scenes: the clock at a fixed time, three review requests, and a 200-node scene. */
export function mockWidgetScene(panel: AppPanel, now = Date.UTC(2026, 10, 10, 17, 42)): SceneOp[] {
  if (panel.app === "manaflow-ai/clock") return mockClockScene(now);
  if (panel.app === "samples/too-big")
    return [
      { op: "create", id: "root", type: "VStack", props: { spacing: 0 } },
      ...Array.from({ length: 200 }, (_, index): SceneOp => ({
        op: "create",
        id: `t${index}`,
        type: "Text",
        props: { text: `Quote ${index}` },
      })),
      { op: "children", id: "root", children: Array.from({ length: 200 }, (_, index) => `t${index}`) },
      { op: "root", id: "root" },
    ];
  return mockPanelScene({ ...panel, section: "recent" });
}

export function mockPanelScene(panel: AppPanel, context?: MountContext): SceneOp[] {
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
  /** `cmux.newtab.widget/1`'s listing and the person's saved layout. */
  widgets: readonly AppPanel[] = MOCK_NEWTAB_WIDGETS;
  layout: string[] = [];
  /** A host like the current Mac bridge: it lists Session Info's sections whatever `interface` asks,
   * with no layout. */
  ignoresInterface = false;
  /** A host without `cmux.apps.panels.layout.set` (it answers unknown-op). */
  refusesLayout = false;
  /** Apps whose mount the mock refuses (a widget in its error state). */
  readonly failing = new Set<string>();
  readonly dispatches: unknown[] = [];
  /** Layouts the page saved (`cmux.apps.panels.layout.set`), in order. */
  readonly savedLayouts: string[][] = [];
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
        result =
          params?.interface === NEW_TAB_WIDGET_INTERFACE && !this.ignoresInterface
            ? { panels: this.widgets, layout: this.layout }
            : { panels: this.panels };
        break;
      case "cmux.apps.panels.layout.set":
        if (this.refusesLayout) throw pageError("cmux.protocol.unknown_op", op);
        this.layout = [...(params.layout as string[])];
        this.savedLayouts.push(this.layout);
        break;
      case "cmux.apps.panels.mount": {
        const panel = [...this.panels, ...this.widgets].find(
          (entry) => entry.app === params.app && entry.section === params.section,
        );
        if (!panel) throw pageError("cmux.apps.not_found", "Unknown app section");
        if (this.failing.has(panel.app)) throw pageError("cmux.apps.mount_failed", "render failed");
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
          {
            mount_id: mountId,
            ops:
              mount.panel.section === NEW_TAB_WIDGET_INTERFACE
                ? mockWidgetScene(mount.panel)
                : mockPanelScene(mount.panel, mount.context),
            reset: true,
          } satisfies SceneEvent,
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

  /** Mounts the mock holds now (a closed New Tab page holds none). */
  get mounted(): number {
    return this.mounts.size;
  }

  /** An app's scene batch (a clock tick: one `update` op) to every mount of its contribution. */
  push(panel: AppPanel, ops: SceneOp[]): void {
    for (const [mountId, mount] of this.mounts) {
      if (panelId(mount.panel) !== panelId(panel)) continue;
      for (const listener of this.scenes.get(mountId) ?? []) listener({ mount_id: mountId, ops }, ++this.seq);
    }
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
