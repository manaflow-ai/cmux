// l10n-allow-file: mock widget scenes (sample app content), not shipped UI.
// A page host for `cmux.widget/1` in tests, the gallery and the browser dev page: it answers the
// widget ops as the daemon does (list, edit with idempotency keys, visible, meters, the changed and
// health streams) and mounts sample widgets whose scenes are what a widget built on the SDK's
// WidgetFrame draws (16 pt inset, a title, a big number, a row list).
import { pageError, type PageClient } from "../../pages/shared/pageClient";
import type { SceneOp } from "./store";
import { WIDGET_OPS, type WidgetPlace, type WidgetSize, type WidgetTilePlacement } from "./widgetsClient";
import { intl } from "../../ui/intl";

type MockWidget = {
  app: string;
  title: string;
  sizes: WidgetSize[];
  defaultSize: WidgetSize;
  refresh?: { everySeconds: number };
  symbol?: string;
  description?: string;
};

export const MOCK_WIDGETS: readonly MockWidget[] = [
  {
    app: "cmux/clock",
    title: "Clock",
    sizes: ["small", "medium", "large"],
    defaultSize: "small",
    refresh: { everySeconds: 60 },
    symbol: "clock",
    description: "The time and date, and the time in other cities.",
  },
  {
    app: "cmux/weather",
    title: "Weather",
    sizes: ["small", "medium"],
    defaultSize: "small",
    refresh: { everySeconds: 900 },
    symbol: "cloud.sun",
    description: "Current conditions and the next hours.",
  },
  {
    app: "cmux/todo",
    title: "To Do",
    sizes: ["medium", "large"],
    defaultSize: "medium",
    symbol: "checklist",
    description: "Your list, checked off from here.",
  },
];

const FIXED_NOW = Date.UTC(2026, 10, 16, 17, 41);

/** The scene a sample widget draws at `size` (`preview`: the gallery's sample data). */
export function mockWidgetScene(app: string, size: WidgetSize, now = FIXED_NOW): SceneOp[] {
  const ops: SceneOp[] = [];
  let n = 0;
  const node = (type: string, props: Record<string, unknown>, children: string[] = []): string => {
    const id = `n${++n}`;
    ops.push({ op: "create", id, type, props });
    if (children.length) ops.push({ op: "children", id, children });
    return id;
  };
  const text = (value: string, props: Record<string, unknown> = {}) => node("Text", { text: value, ...props });
  const frame = (children: string[]) =>
    node(
      "VStack",
      { spacing: 4, alignment: "leading", padding: 16, frame: { maxWidth: "infinity", maxHeight: "infinity" } },
      children,
    );
  let root: string;
  if (app === "cmux/clock") {
    const time = intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit", timeZone: "UTC" }).format(now);
    const day = intl
      .DateTimeFormat("en-US", {
        weekday: "long",
        month: "short",
        day: "numeric",
        timeZone: "UTC",
      })
      .format(now);
    // Apple's clock: the time on one line, its AM/PM smaller beside it.
    const [digits, meridiem] = time.split(" ");
    const big = node("HStack", { spacing: 3, alignment: "bottom" }, [
      text(digits!, { font: size === "small" ? 36 : 48, weight: "semibold" }),
      text(meridiem ?? "", { font: size === "small" ? 15 : 20, weight: "semibold", color: "secondary" }),
    ]);
    const date = text(day.toUpperCase(), { font: 11, weight: "semibold", color: "secondary" });
    const kids = [date, big];
    if (size !== "small") {
      const cities = [
        ["Cupertino", "9:41 AM"],
        ["New York", "12:41 PM"],
        ["London", "5:41 PM"],
        ["Lisbon", "5:41 PM"],
        ["Tokyo", "2:41 AM"],
        ["Sydney", "4:41 AM"],
      ].map(([city, at]) =>
        node("HStack", { spacing: 8 }, [
          text(city!, { font: size === "large" ? 15 : 13 }),
          node("Spacer", {}),
          text(at!, { font: size === "large" ? 15 : 13, color: "secondary" }),
        ]),
      );
      // The large tile lists the world clock down to its bottom edge, a row per city.
      const list = node(
        "VStack",
        { spacing: size === "large" ? 10 : 4, alignment: "leading" },
        size === "large" ? cities : cities.slice(0, 1),
      );
      kids.push(node("Spacer", {}), list);
    }
    root = frame(kids);
  } else if (app === "cmux/weather") {
    const kids = [
      text("Lisbon", { font: 13, weight: "semibold" }),
      text("19°", { font: 40, weight: "light" }),
      node("Spacer", {}),
      node("Icon", { symbol: "sun.max", size: 14, color: "warning" }),
      text("Sunny", { font: 12, weight: "semibold" }),
      text("H:22° L:14°", { font: 12, color: "secondary" }),
    ];
    if (size === "medium")
      kids.splice(
        3,
        0,
        node(
          "HStack",
          { spacing: 18 },
          ["6PM 18°", "7PM 17°", "8PM 16°", "9PM 15°"].map((hour) => text(hour, { font: 11, color: "secondary" })),
        ),
      );
    root = frame(kids);
  } else if (app === "cmux/todo") {
    const items = ["Water the plants", "Book the flights", "Call the bank", "Review PR 412", "Buy coffee"];
    const rows = items.slice(0, size === "large" ? 5 : 3).map((item, index) =>
      node("HStack", { spacing: 8 }, [
        node("Icon", {
          symbol: index === 0 ? "checkmark.circle.fill" : "circle",
          size: 14,
          color: index === 0 ? "accent" : "tertiary",
        }),
        text(item, { font: 13, color: index === 0 ? "secondary" : "primary", strikethrough: index === 0 }),
      ]),
    );
    root = frame([
      node("HStack", { spacing: 6 }, [
        text("To Do", { font: 15, weight: "semibold" }),
        node("Spacer", {}),
        text("4", { font: 15, weight: "semibold", color: "warning" }),
      ]),
      ...rows,
    ]);
  } else {
    root = frame([text("A widget", { font: 13 })]);
  }
  ops.push({ op: "root", id: root });
  return ops;
}

type Listener = (data: unknown, seq: number) => void;

/** The daemon's widget ops on a page, in memory. */
export class MockWidgetsHost implements PageClient {
  widgets: readonly MockWidget[] = MOCK_WIDGETS;
  tiles: WidgetTilePlacement[] = [];
  revision = 1;
  /** An older host: the widget ops are unknown. */
  unsupported = false;
  /** While set, an edit waits for it before the daemon applies and answers it. */
  holdEdits: Promise<void> | undefined;
  /** Every edit is refused (a daemon that turned the person's edit down). */
  refuseEdits = false;
  /** Apps whose mount is refused (an uninstalled widget). */
  readonly refused = new Set<string>();
  /** Every call, in order (`op` and its params). */
  readonly calls: { op: string; params: Record<string, unknown> }[] = [];
  readonly mounts = new Map<string, { app: string; context: Record<string, unknown> }>();
  readonly visible = new Map<string, boolean>();
  private readonly keys = new Map<string, unknown>();
  private readonly streams = new Map<string, Set<{ listener: Listener; filter?: Record<string, unknown> }>>();
  private nextMount = 0;
  private nextInstance = 1;
  private seq = 0;

  constructor(tiles: WidgetTilePlacement[] = []) {
    this.tiles = tiles;
    this.nextInstance = tiles.length + 1;
  }

  get mountCalls(): number {
    return this.calls.filter((call) => call.op === "cmux.apps.panels.mount").length;
  }

  async call<R>(op: string, raw: unknown): Promise<R> {
    const params = (raw ?? {}) as Record<string, unknown>;
    this.calls.push({ op, params });
    if (this.unsupported && op.startsWith("cmux.apps.panels.widgets."))
      throw pageError("cmux.protocol.unknown_op", `unknown op ${op}`);
    switch (op) {
      case WIDGET_OPS.list:
        return { widgets: this.widgets, layout: this.layout() } as R;
      case WIDGET_OPS.edit:
        if (this.holdEdits) await this.holdEdits;
        if (this.refuseEdits) throw pageError("cmux.apps.widgets.failed", "the edit was refused");
        return this.edit(params) as R;
      case WIDGET_OPS.visible: {
        const id = String(params.mount_id);
        if (!this.mounts.has(id)) throw pageError("cmux.apps.panels.not_found", "No such mount");
        this.visible.set(id, params.visible === true);
        return {} as R;
      }
      case WIDGET_OPS.meters:
        return {
          meters: [...this.mounts].map(([id, mount]) => ({
            mount_id: id,
            app: mount.app,
            instance: mount.context.instance,
            everySeconds: this.widgets.find((w) => w.app === mount.app)?.refresh?.everySeconds ?? null,
            visible: this.visible.get(id) ?? true,
            ticks: 12,
            held: 1,
            failures: 0,
          })),
        } as R;
      case "cmux.apps.panels.mount": {
        const app = String(params.app);
        if (params.surface !== "widget" || this.refused.has(app) || !this.widgets.some((w) => w.app === app))
          throw pageError("cmux.apps.panels.not_found", `No widget of ${app} shows`);
        const id = `mock-widget-${++this.nextMount}`;
        this.mounts.set(id, { app, context: params.context as Record<string, unknown> });
        return { mount_id: id } as R;
      }
      case "cmux.apps.panels.unmount":
        this.mounts.delete(String(params.mount_id));
        return {} as R;
      case "cmux.apps.panels.dispatch":
      case "cmux.apps.panels.layout":
        return {} as R;
      default:
        throw pageError("cmux.protocol.unknown_op", `unknown op ${op}`);
    }
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void, filter?: Record<string, unknown>) {
    const entry = { listener: onEvent as Listener, ...(filter && { filter }) };
    let set = this.streams.get(stream);
    if (!set) this.streams.set(stream, (set = new Set()));
    set.add(entry);
    if (stream === "cmux.apps.panels.scene" && typeof filter?.mount_id === "string") {
      const id = filter.mount_id;
      const mount = this.mounts.get(id);
      if (mount)
        queueMicrotask(() => {
          if (!set.has(entry)) return;
          const size = (mount.context.size as WidgetSize) ?? "small";
          onEvent({ mount_id: id, ops: mockWidgetScene(mount.app, size), reset: true } as E, ++this.seq);
          onEvent({ mount_id: id, status: "ready" } as E, ++this.seq);
        });
    }
    return () => {
      set.delete(entry);
    };
  }

  handle(): () => void {
    return () => undefined;
  }

  /** The daemon's `apps-widget-health` for a mount. */
  health(mountId: string, stale: boolean, reason = "render: TypeError: weather is undefined", retryMs = 4000): void {
    this.emit(WIDGET_OPS.health, {
      mount_id: mountId,
      stale,
      ...(stale && { reason, failures: 1, retry_ms: retryMs }),
    });
  }

  /** Another page (or the CLI) edited the layout: every page hears `apps-widgets-changed`. */
  changeElsewhere(tiles: WidgetTilePlacement[]): void {
    this.tiles = tiles;
    this.revision += 1;
    this.emit(WIDGET_OPS.changed, { revision: this.revision, place: "newtab" });
  }

  /** The mount id of a tile's live mount. */
  mountOf(instance: string): string | undefined {
    for (const [id, mount] of this.mounts) if (mount.context.instance === instance && !mount.context.preview) return id;
    return undefined;
  }

  private emit(stream: string, data: Record<string, unknown>): void {
    for (const { listener, filter } of this.streams.get(stream) ?? []) {
      if (filter?.mount_id && filter.mount_id !== data.mount_id) continue;
      listener(data, ++this.seq);
    }
  }

  private layout(place: WidgetPlace = "newtab") {
    return { revision: this.revision, [place]: this.tiles };
  }

  private edit(params: Record<string, unknown>) {
    const key = String(params.idempotency_key ?? "");
    if (!key) throw pageError("cmux.apps.widgets.failed", "idempotency_key is 1 to 256 bytes");
    if (this.keys.has(key)) return this.keys.get(key);
    const edit = params.edit as Record<string, unknown>;
    const tiles = [...this.tiles];
    const at = (instance: unknown) => tiles.findIndex((t) => t.instance === instance);
    switch (edit.op) {
      case "add": {
        const widget = this.widgets.find((w) => w.app === edit.app);
        if (!widget) throw pageError("cmux.apps.widgets.failed", "no such widget");
        const tile = {
          instance: `w${this.nextInstance++}`,
          app: widget.app,
          size: (edit.size as WidgetSize) ?? widget.defaultSize,
        };
        const before = edit.before ? at(edit.before) : -1;
        tiles.splice(before < 0 ? tiles.length : before, 0, tile);
        break;
      }
      case "remove":
        tiles.splice(at(edit.instance), 1);
        break;
      case "resize": {
        const index = at(edit.instance);
        tiles[index] = { ...tiles[index]!, size: edit.size as WidgetSize };
        break;
      }
      case "move": {
        const index = at(edit.instance);
        const [tile] = tiles.splice(index, 1);
        const before = edit.before ? at(edit.before) : -1;
        tiles.splice(before < 0 ? tiles.length : before, 0, tile!);
        break;
      }
    }
    this.tiles = tiles;
    this.revision += 1;
    const result = { layout: this.layout() };
    this.keys.set(key, result);
    this.emit(WIDGET_OPS.changed, { revision: this.revision, place: "newtab" });
    return result;
  }
}
