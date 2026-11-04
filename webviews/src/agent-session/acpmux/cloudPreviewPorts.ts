import { useSyncExternalStore } from "react";

export type CloudPreviewPort = { port: number; process?: string };

const NONE: readonly CloudPreviewPort[] = [];
let current: readonly CloudPreviewPort[] = NONE;
const listeners = new Set<() => void>();

function validPort(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 1 && value <= 65535;
}

export function readCloudPreviewPort(value: unknown): CloudPreviewPort | undefined {
  if (!value || typeof value !== "object") return undefined;
  const item = value as Record<string, unknown>;
  if (!validPort(item.port) || item.known === true) return undefined;
  const process = typeof item.process === "string" ? item.process.trim() : "";
  return { port: item.port, ...(process ? { process } : {}) };
}

export function addCloudPreviewPort(value: unknown): boolean {
  const port = readCloudPreviewPort(value);
  if (!port || current.some((item) => item.port === port.port)) return false;
  current = [...current, port];
  for (const listener of listeners) listener();
  return true;
}

export function seedCloudPreviewPorts(values: readonly unknown[]): void {
  const next: CloudPreviewPort[] = [];
  for (const value of values) {
    const port = readCloudPreviewPort(value);
    if (port && !next.some((item) => item.port === port.port)) next.push(port);
  }
  current = next.length ? next : NONE;
  for (const listener of listeners) listener();
}

export function cloudPreviewPorts(): readonly CloudPreviewPort[] {
  return current;
}

export function resetCloudPreviewPorts(): void {
  current = NONE;
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

export function useCloudPreviewPorts(): readonly CloudPreviewPort[] {
  return useSyncExternalStore(subscribe, cloudPreviewPorts, cloudPreviewPorts);
}
