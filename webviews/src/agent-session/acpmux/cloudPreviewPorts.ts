// A Cloud chat's new preview ports, kept per pane view (goal memory-per-chat, paneView.ts): in a
// shared pane document each chat has its own context, known ports and cards, so one chat's app never
// shows in another's. The null view is the page itself, which is every page today.
import { useSyncExternalStore } from "react";
import { usePaneView } from "./paneViewStore";

export type CloudPreviewPort = { port: number; process?: string };
export type CloudPreviewContext = { machineID?: string; sessionId?: string; turnId?: string; active: boolean };
type PortEvent = CloudPreviewPort & {
  machineID?: string;
  sessionId?: string;
  turnId?: string;
  state?: string;
  known?: boolean;
  snapshot?: boolean;
  replayed?: boolean;
};

const NONE: readonly CloudPreviewPort[] = [];

type ViewPorts = {
  current: readonly CloudPreviewPort[];
  knownPorts: Set<number>;
  knownByContext: Map<string, Set<number>>;
  unscopedKnown: Set<number>;
  context: CloudPreviewContext | undefined;
  pending: readonly unknown[];
};

const byView = new Map<string | null, ViewPorts>();
/// Readers a view, apart from its ports so a drop or reset keeps them listening.
const listeners = new Map<string | null, Set<() => void>>();

function portsOf(view: string | null): ViewPorts {
  let state = byView.get(view);
  if (!state) {
    state = {
      current: NONE,
      knownPorts: new Set(),
      knownByContext: new Map(),
      unscopedKnown: new Set(),
      context: undefined,
      pending: [],
    };
    byView.set(view, state);
  }
  return state;
}

function wake(view: string | null): void {
  const set = listeners.get(view);
  if (set) for (const listener of set) listener();
}

function validPort(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 1 && value <= 65535;
}

function field(item: Record<string, unknown>, ...names: string[]): string | undefined {
  for (const name of names) {
    const value = item[name];
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return undefined;
}

function parseEvent(value: unknown): PortEvent | undefined {
  if (!value || typeof value !== "object") return undefined;
  const item = value as Record<string, unknown>;
  const data = item.data && typeof item.data === "object" ? (item.data as Record<string, unknown>) : item;
  if (!validPort(data.port)) return undefined;
  const process = typeof data.process === "string" ? data.process.trim() : "";
  const known =
    item.known === true ||
    item.snapshot === true ||
    item.replayed === true ||
    data.known === true ||
    data.snapshot === true ||
    data.replayed === true;
  const machineID = field(data, "machineID", "machineId", "machine");
  const sessionId = field(data, "sessionId", "sessionID", "session");
  const turnId = field(data, "turnId", "turnID", "turn");
  return {
    port: data.port,
    ...(process ? { process } : {}),
    ...(machineID ? { machineID } : {}),
    ...(sessionId ? { sessionId } : {}),
    ...(turnId ? { turnId } : {}),
    ...(typeof data.state === "string" ? { state: data.state } : {}),
    ...(known ? { known: true } : {}),
  };
}

export function readCloudPreviewPort(value: unknown): CloudPreviewPort | undefined {
  const event = parseEvent(value);
  return event ? { port: event.port, ...(event.process ? { process: event.process } : {}) } : undefined;
}

function contextKey(value: CloudPreviewContext | undefined): string {
  if (!value) return "";
  return [value.machineID ?? "", value.sessionId ?? "", value.turnId ?? ""].join("\u0000");
}

function machineSessionKey(value: CloudPreviewContext | undefined): string {
  if (!value) return "";
  return [value.machineID ?? "", value.sessionId ?? ""].join("\u0000");
}

function matches(event: PortEvent, target: CloudPreviewContext): boolean {
  if (event.machineID && event.machineID !== target.machineID) return false;
  if (event.sessionId && event.sessionId !== target.sessionId) return false;
  if (event.turnId && event.turnId !== target.turnId) return false;
  return true;
}

function apply(state: ViewPorts, event: PortEvent, target: CloudPreviewContext): boolean {
  if (!matches(event, target)) return false;
  const remember = () => {
    state.knownByContext.set(contextKey(target), state.knownPorts);
    state.knownByContext.set(machineSessionKey(target), state.knownPorts);
  };
  if (event.state === "down" || event.state === "closed") {
    state.knownPorts.delete(event.port);
    state.unscopedKnown.delete(event.port);
    // A new turn copies the session baseline, so a close must also leave the session's set, or
    // the next turn restores the closed port as known and a reopen shows no card.
    remember();
    state.current = state.current.filter((item) => item.port !== event.port);
    return false;
  }
  if (event.known === true || !target.active || state.knownPorts.has(event.port)) {
    state.knownPorts.add(event.port);
    remember();
    return false;
  }
  state.knownPorts.add(event.port);
  remember();
  state.current = [...state.current, { port: event.port, ...(event.process ? { process: event.process } : {}) }];
  return true;
}

/// Sets `view`'s chat context (its machine, session, turn and whether it is working).
export function setCloudPreviewContext(next: CloudPreviewContext, view: string | null = null): void {
  const state = portsOf(view);
  const key = contextKey(next);
  const changed = contextKey(state.context) !== key;
  state.context = next;
  if (changed) {
    state.current = NONE;
    state.knownPorts = new Set<number>([
      ...(state.knownByContext.get(key) ?? []),
      ...(state.knownByContext.get(machineSessionKey(next)) ?? []),
      ...state.unscopedKnown,
    ]);
    state.knownByContext.set(key, state.knownPorts);
  }
  const queued = state.pending;
  state.pending = [];
  const before = state.current;
  for (const value of queued) {
    const event = parseEvent(value);
    if (event) apply(state, event, next);
  }
  if (changed || before !== state.current) wake(view);
}

/// A port the host saw open for `view`'s chat; true when it is a new card.
export function addCloudPreviewPort(value: unknown, view: string | null = null): boolean {
  const event = parseEvent(value);
  if (!event) return false;
  const state = portsOf(view);
  if (!state.context) {
    state.pending = [...state.pending, value];
    return false;
  }
  const before = state.current;
  const added = apply(state, event, state.context);
  if (before !== state.current) wake(view);
  return added;
}

/// Ports `view`'s chat already had open: known, so none becomes a card.
export function seedCloudPreviewPorts(values: readonly unknown[], view: string | null = null): void {
  const state = portsOf(view);
  for (const value of values) {
    const event = parseEvent(value);
    if (event) {
      state.knownPorts.add(event.port);
      if (!state.context) state.unscopedKnown.add(event.port);
    }
  }
  if (state.context) {
    state.knownByContext.set(contextKey(state.context), state.knownPorts);
    state.knownByContext.set(machineSessionKey(state.context), state.knownPorts);
  }
}

export function cloudPreviewPorts(view: string | null = null): readonly CloudPreviewPort[] {
  return byView.get(view)?.current ?? NONE;
}

/// Forgets a view that closed, waking its readers with no cards.
export function dropCloudPreviewPorts(view: string): void {
  if (byView.delete(view)) wake(view);
}

/// Tests: forgets every view's ports.
export function resetCloudPreviewPorts(): void {
  const views = [...byView.keys()];
  byView.clear();
  for (const view of views) wake(view);
}

export function subscribeCloudPreviewPorts(listener: () => void, view: string | null = null): () => void {
  let set = listeners.get(view);
  if (!set) {
    set = new Set();
    listeners.set(view, set);
  }
  set.add(listener);
  return () => {
    const current = listeners.get(view);
    if (!current) return;
    current.delete(listener);
    if (current.size === 0) listeners.delete(view);
  };
}

/// React: the calling component's view's new ports.
export function useCloudPreviewPorts(): readonly CloudPreviewPort[] {
  const view = usePaneView();
  return useSyncExternalStore(
    (listener) => subscribeCloudPreviewPorts(listener, view),
    () => cloudPreviewPorts(view),
    () => cloudPreviewPorts(view),
  );
}

declare global {
  interface Window {
    /// The old host's script for the `cloudPreviewPort` event (CmuxNextAgentPane AgentPaneView).
    cmuxAcpmuxCloudPreviewPort?: (value: unknown) => void;
  }
}
export function installCloudPreviewPortHook(target: Window): void {
  target.cmuxAcpmuxCloudPreviewPort = (value) => void addCloudPreviewPort(value);
}
if (typeof window !== "undefined") installCloudPreviewPortHook(window);
