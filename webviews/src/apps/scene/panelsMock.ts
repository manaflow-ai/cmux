// l10n-allow-file: browser mock app fixtures, not shipped UI.
import { pageError, type PageClient, type PageHandler } from "../../pages/shared/pageClient";
import { panelId, type AppPanel, type MountContext, type SceneEvent } from "./panelsClient";
import type { SceneOp } from "./store";

export const MOCK_APP_PANELS: readonly AppPanel[] = [
  { app: "samples/github-prs", section: "recent", title: "PRs in the last 24h", symbol: "arrow.triangle.pull" },
  { app: "samples/session", section: "details", title: "Session notes", symbol: "doc.text" },
];

/** What `apps.composer.list` answers in the mock: one extension's slash commands. */
export const MOCK_COMPOSER_COMMANDS: readonly unknown[] = [
  {
    app: "samples/standup",
    extension: "Standup",
    name: "standup",
    description: "Ask for today's standup notes",
    insert: "Write my standup: what I did yesterday, what I do today, what blocks me.",
  },
  {
    app: "samples/standup",
    extension: "Standup",
    name: "retro",
    description: "Start a sprint retro",
    hint: "<sprint>",
    insert: "Run a retro for sprint ",
  },
];

/** What `apps.composer.list` and `apps.composer.mentions` answer in the mock: one `@pr` provider. */
export const MOCK_COMPOSER_MENTIONS: readonly {
  prefix: string;
  id: string;
  label: string;
  detail?: string;
  insert: string;
}[] = [
  {
    prefix: "pr",
    id: "441",
    label: "#441 Fix the login redirect",
    detail: "open, 2 checks failing",
    insert: "PR #441",
  },
  { prefix: "pr", id: "450", label: "#450 Faster startup", detail: "open, ready to merge", insert: "PR #450" },
];

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
  composerCommands: readonly unknown[] = MOCK_COMPOSER_COMMANDS;
  composerMentions: readonly { prefix: string; id: string; label: string; detail?: string; insert: string }[] =
    MOCK_COMPOSER_MENTIONS;
  readonly mentionAsks: unknown[] = [];
  readonly dispatches: unknown[] = [];
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
      case "cmux.apps.panels.composer":
        result = {
          commands: this.composerCommands,
          mentions: [...new Set(this.composerMentions.map((item) => item.prefix))].map((prefix) => ({
            app: "samples/team-flow",
            extension: "Team flow",
            prefix,
          })),
        };
        break;
      case "cmux.apps.panels.mentions": {
        // The daemon's match, cut down: a prefix narrows to its provider, the query matches id or label.
        this.mentionAsks.push(params);
        const query = String(params.query ?? "").toLowerCase();
        result = {
          mentions: this.composerMentions
            .filter((item) => params.prefix === undefined || item.prefix === params.prefix)
            .filter((item) => !query || item.id.includes(query) || item.label.toLowerCase().includes(query))
            .map((item) => ({ app: "samples/team-flow", extension: "Team flow", ...item })),
        };
        break;
      }
      case "cmux.apps.panels.mount": {
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

  /** A mock save of an extension's composer commands: the page lists them again on `changed`. */
  setComposerCommands(commands: readonly unknown[]): void {
    this.composerCommands = commands;
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
