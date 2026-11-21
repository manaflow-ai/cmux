// Extension footer controls (`cmux.composer.control/1`) in the composer's bottom bar. The daemon
// decides which there are (cmux-tui-core apps/composer.rs, `apps.composer.list` `controls`, through
// the page host's `cmux.apps.panels.composer`) and leaves out any action its app may not run; this
// file reads its answer, lists it again when the installed apps change (`cmux.apps.panels.changed`),
// and sends a click back (`cmux.apps.panels.composer.control`), which runs the action as the app.
import { useEffect, useMemo, useSyncExternalStore } from "react";
import type { PageClient } from "../../../pages/shared/pageClient";
import { appPanelsDevClient } from "../../../apps/scene/panelsClient";
import { pageHostClient } from "../pageHost";

/// A button of a footer menu, or what a footer button does: `insert` is written at the caret here;
/// `action` is run by the daemon as the control's app.
export type ExtensionControlItem = {
  id: string;
  label: string;
  description?: string;
  symbol?: string;
  action?: string;
  insert?: string;
};

export type ExtensionControl = {
  app: string;
  extension: string;
  id: string;
  kind: "button" | "menu";
  label: string;
  symbol?: string;
  tooltip?: string;
  placement: "left" | "right";
  order: number;
  action?: string;
  insert?: string;
  items: ExtensionControlItem[];
};

const EMPTY: readonly ExtensionControl[] = [];

const text = (value: unknown): string | undefined => (typeof value === "string" && value ? value : undefined);

function itemFrom(entry: unknown): ExtensionControlItem | undefined {
  if (!entry || typeof entry !== "object") return undefined;
  const raw = entry as Record<string, unknown>;
  const id = text(raw.id);
  const label = text(raw.label);
  const action = text(raw.action);
  const insert = text(raw.insert);
  if (!id || !label || (!action && !insert)) return undefined;
  return {
    id,
    label,
    ...(text(raw.description) && { description: text(raw.description)! }),
    ...(text(raw.symbol) && { symbol: text(raw.symbol)! }),
    ...(insert ? { insert } : { action: action! }),
  };
}

/// The controls in an `apps.composer.list` reply, in the daemon's order; an entry that names no
/// app, id or label, a button that does nothing and a menu with no item are dropped.
export function extensionControlsFrom(reply: unknown): ExtensionControl[] {
  const controls = (reply as { controls?: unknown } | null)?.controls;
  if (!Array.isArray(controls)) return [];
  const out: ExtensionControl[] = [];
  for (const entry of controls) {
    if (!entry || typeof entry !== "object") continue;
    const raw = entry as Record<string, unknown>;
    const app = text(raw.app);
    const id = text(raw.id);
    const label = text(raw.label);
    if (!app || !id || !label) continue;
    const kind = raw.kind === "menu" ? "menu" : "button";
    const items = kind === "menu" && Array.isArray(raw.items) ? raw.items.flatMap((i) => itemFrom(i) ?? []) : [];
    const own = kind === "button" ? itemFrom({ id, label, action: raw.action, insert: raw.insert }) : undefined;
    if (kind === "menu" ? !items.length : !own) continue;
    out.push({
      app,
      extension: text(raw.extension) ?? app,
      id,
      kind,
      label,
      ...(text(raw.symbol) && { symbol: text(raw.symbol)! }),
      ...(text(raw.tooltip) && { tooltip: text(raw.tooltip)! }),
      placement: raw.placement === "right" ? "right" : "left",
      order: typeof raw.order === "number" ? raw.order : 0,
      ...(own?.action && { action: own.action }),
      ...(own?.insert && { insert: own.insert }),
      items,
    });
  }
  return out;
}

/// A click on `control` (or its menu's `item`): the text to write at the caret, or undefined once
/// the daemon took the action. An insert never leaves the page.
export async function runExtensionControl(
  client: PageClient | null,
  control: ExtensionControl,
  item?: ExtensionControlItem,
): Promise<string | undefined> {
  const target = item ?? control;
  if (target.insert) return target.insert;
  if (!client) return undefined;
  await client.call("cmux.apps.panels.composer.control", {
    app: control.app,
    control: control.id,
    ...(item && { item: item.id }),
  });
  return undefined;
}

const sameControls = (a: readonly ExtensionControl[], b: readonly ExtensionControl[]) =>
  a.length === b.length && a.every((control, index) => JSON.stringify(control) === JSON.stringify(b[index]));

/// One page's footer controls: read on start and again on every change of the installed apps.
export class ExtensionControls {
  private snapshot: readonly ExtensionControl[] = EMPTY;
  private readonly listeners = new Set<() => void>();
  private reading = 0;
  private active = false;
  private stopWatch?: () => void;

  constructor(private readonly client: PageClient | null) {}

  getSnapshot = (): readonly ExtensionControl[] => this.snapshot;
  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  start(): void {
    if (this.active || !this.client) return;
    this.active = true;
    void this.client
      .subscribe("cmux.apps.panels.changed", () => void this.refresh())
      .then((stop) => {
        if (!this.active) stop();
        else {
          this.stopWatch = stop;
          void this.refresh();
        }
      })
      .catch(() => undefined);
    void this.refresh();
  }

  stop(): void {
    this.active = false;
    ++this.reading;
    this.stopWatch?.();
    this.stopWatch = undefined;
  }

  async refresh(): Promise<void> {
    if (!this.active || !this.client) return;
    const reading = ++this.reading;
    let next: ExtensionControl[];
    try {
      next = extensionControlsFrom(await this.client.call("cmux.apps.panels.composer", {}));
    } catch {
      // An older host serves no composer places: the footer has no extension controls.
      next = [];
    }
    if (!this.active || reading !== this.reading || sameControls(next, this.snapshot)) return;
    this.snapshot = next.length ? next : EMPTY;
    for (const listener of this.listeners) listener();
  }
}

/// The page's footer controls, kept current while the page is open, and the client a click goes to.
export function useExtensionControls(injectedClient?: PageClient | null): {
  controls: readonly ExtensionControl[];
  client: PageClient | null;
} {
  const client = injectedClient === undefined ? (pageHostClient() ?? appPanelsDevClient()) : injectedClient;
  const owner = useMemo(() => new ExtensionControls(client), [client]);
  const controls = useSyncExternalStore(owner.subscribe, owner.getSnapshot, owner.getSnapshot);
  useEffect(() => {
    owner.start();
    return () => owner.stop();
  }, [owner]);
  return { controls, client };
}
