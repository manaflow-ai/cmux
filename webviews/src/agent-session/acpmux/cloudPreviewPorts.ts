import { useSyncExternalStore } from "react";

export type CloudPreviewPort = { port: number; process?: string };
export type CloudPreviewContext = { machineID?: string; sessionId?: string; turnId?: string; active: boolean };
type PortEvent = CloudPreviewPort & {
  machineID?: string;
  sessionId?: string;
  turnId?: string;
  state?: string;
  known?: boolean;
};

const NONE: readonly CloudPreviewPort[] = [];
let current: readonly CloudPreviewPort[] = NONE;
let knownPorts = new Set<number>();
const knownByContext = new Map<string, Set<number>>();
const unscopedKnown = new Set<number>();
const listeners = new Set<() => void>();
let context: CloudPreviewContext | undefined;
let pending: readonly unknown[] = [];

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
    ...(data.known === true ? { known: true } : {}),
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

function matches(event: PortEvent, target: CloudPreviewContext): boolean {
  if (event.machineID && event.machineID !== target.machineID) return false;
  if (event.sessionId && event.sessionId !== target.sessionId) return false;
  if (event.turnId && event.turnId !== target.turnId) return false;
  return true;
}

function apply(event: PortEvent, target: CloudPreviewContext): boolean {
  if (!matches(event, target)) return false;
  if (event.state === "down" || event.state === "closed") {
    knownPorts.delete(event.port);
    current = current.filter((item) => item.port !== event.port);
    return false;
  }
  if (event.known === true || !target.active || knownPorts.has(event.port)) {
    knownPorts.add(event.port);
    knownByContext.set(contextKey(target), knownPorts);
    return false;
  }
  knownPorts.add(event.port);
  knownByContext.set(contextKey(target), knownPorts);
  current = [...current, { port: event.port, ...(event.process ? { process: event.process } : {}) }];
  return true;
}

export function setCloudPreviewContext(next: CloudPreviewContext): void {
  const key = contextKey(next);
  const changed = contextKey(context) !== key;
  context = next;
  if (changed) {
    current = NONE;
    knownPorts = new Set<number>([...(knownByContext.get(key) ?? []), ...unscopedKnown]);
    knownByContext.set(key, knownPorts);
  }
  if (pending.length === 0) return;
  const queued = pending;
  pending = [];
  let changedCards = changed;
  for (const value of queued) {
    const event = parseEvent(value);
    if (event && apply(event, next)) changedCards = true;
  }
  if (changedCards) for (const listener of listeners) listener();
}

export function addCloudPreviewPort(value: unknown): boolean {
  const event = parseEvent(value);
  if (!event) return false;
  if (!context) {
    pending = [...pending, value];
    return false;
  }
  const added = apply(event, context);
  if (added) for (const listener of listeners) listener();
  return added;
}

export function seedCloudPreviewPorts(values: readonly unknown[]): void {
  for (const value of values) {
    const event = parseEvent(value);
    if (event) {
      knownPorts.add(event.port);
      if (!context) unscopedKnown.add(event.port);
    }
  }
  if (context) knownByContext.set(contextKey(context), knownPorts);
}

export function cloudPreviewPorts(): readonly CloudPreviewPort[] {
  return current;
}

export function resetCloudPreviewPorts(): void {
  current = NONE;
  knownPorts = new Set<number>();
  knownByContext.clear();
  unscopedKnown.clear();
  context = undefined;
  pending = [];
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

export function useCloudPreviewPorts(): readonly CloudPreviewPort[] {
  return useSyncExternalStore(subscribe, cloudPreviewPorts, cloudPreviewPorts);
}
