// The recently closed tabs, screens and workspaces the host pushes (`recentlyClosed`,
// CmuxNextAgentPane AgentPaneClosedItem; cx-d0d.60): History's closed entries, newest first. A
// module store like deviceChats.ts, so a push that arrives before the New Tab screen mounts is
// kept; the screen reads it with `useRecentlyClosed`.
import { useSyncExternalStore } from "react";

export type ClosedItem = {
  id: string;
  kind: "terminal" | "browser" | "screen" | "workspace";
  title: string;
  detail?: string;
  closedAt: number;
  icon?: string;
  /// False while its machine is not connected: drawn dimmed, not clickable.
  available: boolean;
};

const KINDS: readonly ClosedItem["kind"][] = ["terminal", "browser", "screen", "workspace"];
let items: ClosedItem[] = [];
const listeners = new Set<() => void>();

/// Replaces the list from a host push; anything malformed is dropped.
export function setRecentlyClosed(value: unknown): void {
  items = Array.isArray(value)
    ? value.flatMap((entry): ClosedItem[] => {
        const item = entry as Partial<ClosedItem> | null;
        if (!item || typeof item.id !== "string" || typeof item.title !== "string") return [];
        if (!KINDS.includes(item.kind as ClosedItem["kind"])) return [];
        return [
          {
            id: item.id,
            kind: item.kind as ClosedItem["kind"],
            title: item.title,
            closedAt: typeof item.closedAt === "number" ? item.closedAt : 0,
            available: item.available !== false,
            ...(typeof item.detail === "string" && item.detail ? { detail: item.detail } : {}),
            ...(typeof item.icon === "string" && item.icon ? { icon: item.icon } : {}),
          },
        ];
      })
    : [];
  for (const listener of listeners) listener();
}

export function recentlyClosed(): ClosedItem[] {
  return items;
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useRecentlyClosed(): ClosedItem[] {
  return useSyncExternalStore(subscribe, recentlyClosed, recentlyClosed);
}
