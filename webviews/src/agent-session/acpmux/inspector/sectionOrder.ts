import { useSyncExternalStore } from "react";

export const DEFAULT_INSPECTOR_ORDER = [
  "environment",
  "context",
  "connectors",
  "changes",
  "sources",
  "outputs",
  "subagents",
  "tasks",
] as const;
export type InspectorOrderId = (typeof DEFAULT_INSPECTOR_ORDER)[number];
export type InspectorOrder = readonly InspectorOrderId[];
export const INSPECTOR_ORDER_KEY = "cmux.agentPane.inspector.order";
export const INSPECTOR_ORDER_SETTING_KEY = "agentPane.display.inspector.order";

// Keep the native string-list schema: the first member carries a Lamport timestamp and writer
// identity. Older unversioned arrays remain readable; unknown section IDs never reach the UI.
const VERSION = "@cmux-order/v1/";
type Revision = { time: number; writer: string; order: InspectorOrder };
type Host = (value: readonly string[]) => Promise<unknown>;
type OrderStorage = Pick<Storage, "getItem" | "setItem" | "removeItem">;
const newer = (a: Revision, b: Revision) => a.time > b.time || (a.time === b.time && a.writer > b.writer);
const same = (a: Revision, b: Revision) => a.time === b.time && a.writer === b.writer;
function normalize(value: readonly unknown[]): InspectorOrder {
  const known = (id: unknown): id is InspectorOrderId => DEFAULT_INSPECTOR_ORDER.includes(id as InspectorOrderId);
  return Object.freeze([...new Set([...value.filter(known), ...DEFAULT_INSPECTOR_ORDER])]);
}
function decode(value: unknown): Revision | undefined {
  if (!Array.isArray(value)) return;
  const match = typeof value[0] === "string" ? /^@cmux-order\/v1\/(\d+)\/([\w-]+)$/.exec(value[0]) : null;
  const time = match ? Number(match[1]) : 0;
  if (!Number.isSafeInteger(time)) return;
  return { time, writer: match?.[2] ?? "", order: normalize(value) };
}
const encode = (value: Revision) => [`${VERSION}${value.time}/${value.writer}`, ...value.order];

export function moveSection(order: InspectorOrder, id: InspectorOrderId, targetId: InspectorOrderId, after = false) {
  if (id === targetId || !order.includes(id) || !order.includes(targetId)) return order;
  const next = order.filter((item) => item !== id);
  next.splice(next.indexOf(targetId) + Number(after), 0, id);
  return next;
}

// Each pane owns one replica. Local intent, native pushes, storage events and resets all merge
// through the same newest-version rule. An RPC acknowledgement never applies an order payload.
export function createInspectorOrderStore(storage: () => OrderStorage = () => localStorage) {
  const writer = crypto.randomUUID();
  let held: Revision = { time: -1, writer: "", order: DEFAULT_INSPECTOR_ORDER };
  let host: Host | undefined;
  const listeners = new Set<() => void>();
  const read = () => {
    try {
      return decode(JSON.parse(storage().getItem(INSPECTOR_ORDER_KEY) ?? "null"));
    } catch {
      return undefined;
    }
  };
  const merge = (value: Revision | undefined) => {
    if (!value || !newer(value, held)) return;
    const changed = !held.order.every((id, index) => value.order[index] === id);
    held = { ...value, order: changed ? value.order : held.order };
    if (changed) listeners.forEach((notify) => notify());
  };
  const current = () => {
    merge(read());
    return held.order;
  };
  const changed = (event: StorageEvent) => {
    if (event.key === INSPECTOR_ORDER_KEY || event.key === null) merge(read());
  };
  const set = async (order: InspectorOrder) => {
    merge(read());
    const next: Revision = { time: Math.max(Date.now(), held.time + 1), writer, order: normalize(order) };
    const wire = encode(next);
    merge(next);
    try {
      storage().setItem(INSPECTOR_ORDER_KEY, JSON.stringify(wire));
    } catch {
      /* An unavailable browser store still keeps the in-memory replica. */
    }
    if (!host) return;
    try {
      await host(wire);
      // Another pane may have written since this request started. Confirm only our own stamp;
      // never replace held, even when the native display push has not reached this pane yet.
      const saved = read();
      if (saved && same(saved, next)) storage().removeItem(INSPECTOR_ORDER_KEY);
    } catch {
      /* Unsupported/managed settings retain the stamped local fallback for reload. */
    }
  };
  return {
    current,
    set,
    reset: () => set(DEFAULT_INSPECTOR_ORDER),
    registerHost(write: Host | undefined) {
      host = write;
    },
    applyNative(value: unknown) {
      // Supported hosts send Reset as a stamped default. A missing key on an older host
      // conveys no revision and must not overwrite a rejected local write.
      const incoming = decode(value);
      if (!incoming) return;
      merge(read());
      merge(incoming);
    },
    subscribe(notify: () => void) {
      if (!listeners.size) {
        globalThis.addEventListener?.("storage", changed);
        merge(read());
      }
      listeners.add(notify);
      return () => {
        listeners.delete(notify);
        if (!listeners.size) globalThis.removeEventListener?.("storage", changed);
      };
    },
  };
}

const order = createInspectorOrderStore();
export const applyInspectorOrder = order.applyNative;
export const registerInspectorOrderHost = order.registerHost;
export const setInspectorOrder = order.set;
export const useInspectorOrder = () => useSyncExternalStore(order.subscribe, order.current, order.current);
