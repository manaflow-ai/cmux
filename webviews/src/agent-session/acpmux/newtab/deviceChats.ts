// The device chats the host pushes (`deviceChats`, CmuxNextAgentPane AgentPaneDeviceChat): the
// acpmux chat index's newest chats, the same source as the sidebar's All chats. A module store,
// so a push that arrives before the New Tab screen mounts is kept; the screen reads it with
// `useDeviceChats` (no effect).
import { useSyncExternalStore } from "react";

export type DeviceChat = { key: string; harness: string; title?: string; updatedAt: number };

let chats: DeviceChat[] = [];
const listeners = new Set<() => void>();

/// Replaces the list from a host push; anything malformed is dropped.
export function setDeviceChats(value: unknown): void {
  const next = Array.isArray(value)
    ? value.flatMap((item): DeviceChat[] => {
        const chat = item as Partial<DeviceChat> | null;
        if (!chat || typeof chat.key !== "string" || typeof chat.harness !== "string") return [];
        const updatedAt = typeof chat.updatedAt === "number" ? chat.updatedAt : 0;
        return [{ key: chat.key, harness: chat.harness, updatedAt, ...(typeof chat.title === "string" && chat.title ? { title: chat.title } : {}) }];
      })
    : [];
  chats = next;
  for (const listener of listeners) listener();
}

export function deviceChats(): DeviceChat[] {
  return chats;
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useDeviceChats(): DeviceChat[] {
  return useSyncExternalStore(subscribe, deviceChats, deviceChats);
}
