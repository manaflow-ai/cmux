// The device chats the host pushes (`deviceChats`, CmuxNextAgentPane AgentPaneDeviceChat): the
// acpmux chat index's newest chats, the same source as the sidebar's All chats. A module store,
// so a push that arrives before the New Tab screen mounts is kept; the screen reads it with
// `useDeviceChats` (no effect).
import { useSyncExternalStore } from "react";

/// `parent`: the chat whose agent started this one; such a chat folds under it, never on its own.
export type DeviceChat = { key: string; harness: string; title?: string; updatedAt: number; parent?: string };

let chats: DeviceChat[] = [];
let pushes = 0;
const listeners = new Set<() => void>();

/// Replaces the list from a host push; anything malformed is dropped.
export function setDeviceChats(value: unknown): void {
  const next = Array.isArray(value)
    ? value.flatMap((item): DeviceChat[] => {
        const chat = item as Partial<DeviceChat> | null;
        if (!chat || typeof chat.key !== "string" || typeof chat.harness !== "string") return [];
        const updatedAt = typeof chat.updatedAt === "number" ? chat.updatedAt : 0;
        return [
          {
            key: chat.key,
            harness: chat.harness,
            updatedAt,
            ...(typeof chat.title === "string" && chat.title ? { title: chat.title } : {}),
            ...(typeof chat.parent === "string" && chat.parent ? { parent: chat.parent } : {}),
          },
        ];
      })
    : [];
  chats = next;
  pushes += 1;
  for (const listener of listeners) listener();
}

/// How many pushes this page received: a list compares it with the one its rows answer
/// (settledCache.ts) to tell a change it has not read from a mount.
export function devicePushCount(): number {
  return pushes;
}

export function deviceChats(): DeviceChat[] {
  return chats;
}

/// Runs `listener` after every host push (the All chats list reloads its first page when the index
/// arrives after it mounted, cx-ztlw).
export function subscribeDeviceChats(listener: () => void): () => void {
  return subscribe(listener);
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useDeviceChats(): DeviceChat[] {
  return useSyncExternalStore(subscribe, deviceChats, deviceChats);
}
