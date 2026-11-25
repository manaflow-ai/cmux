import { useSyncExternalStore } from "react";

/// Session Info's Remote Control switch, as the App pushes it (`remoteControl`,
/// AgentPaneRemoteControl.swift): the iPhone host's own switch (`mobile.allowIPhoneConnections`),
/// so cmux on the person's iPhone can open this Mac's chats. Null while this Mac cannot serve
/// phones (no account signed in, no iPhone host in the build): then the row is not drawn.
export type RemoteControl = { on: boolean };

let current: RemoteControl | null = null;
/// The App's last pushed value, and the newest click: a refused write puts back the App's value
/// only while no later click or push replaced it.
let confirmed: RemoteControl | null = null;
let clicks = 0;
const listeners = new Set<() => void>();

function publish(next: RemoteControl | null): void {
  if (next?.on === current?.on && (next === null) === (current === null)) return;
  current = next;
  for (const listener of listeners) listener();
}

export function setRemoteControl(value: unknown): void {
  confirmed = readRemoteControl(value);
  publish(confirmed);
}

export function readRemoteControl(value: unknown): RemoteControl | null {
  if (!value || typeof value !== "object") return null;
  const on = (value as Record<string, unknown>).on;
  return typeof on === "boolean" ? { on } : null;
}

export function remoteControl(): RemoteControl | null {
  return current;
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

export function useRemoteControl(): RemoteControl | null {
  return useSyncExternalStore(subscribe, remoteControl, remoteControl);
}

/// The person's click on the switch: shows the new value at once and writes it through the App
/// (`pane.setRemoteControl {on}`, a person-only call). A refused or failed write puts the switch
/// back; the App's push after a write that worked says the same value again.
export async function toggleRemoteControl(
  on: boolean,
  call: (method: string, params: Record<string, unknown>) => Promise<unknown>,
): Promise<void> {
  if (!current) return;
  const click = ++clicks;
  publish({ on });
  try {
    await call("pane.setRemoteControl", { on });
  } catch {
    // Only the newest click undoes, and to the App's last pushed value, never another click's.
    if (click === clicks) publish(confirmed);
  }
}
