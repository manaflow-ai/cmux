import { createContext, type ReactNode } from "react";
import type { AcpmuxRow } from "../model";

/// Rows mounted at first, and how many more each scroll to the top adds.
export const WINDOW = 60;
/// The rows mounted at first, bounded at both ends: `end` undefined follows the newest row (the
/// newest window, which grows as rows arrive); a window around an anchor row ends WINDOW rows on, so
/// opening a task early in a long transcript mounts no more than one window either way.
export type Range = { start: number; end?: number };

/// The most rows mounted at once while the reader pages up or down: one window gained, one kept.
export const MOUNTED = 2 * WINDOW;

export function windowRange(rows: readonly AcpmuxRow[], anchor?: string): Range {
  const newest = Math.max(0, rows.length - WINDOW);
  const at = anchor === undefined ? -1 : rows.findIndex((row) => row.id === anchor);
  if (at < 0) return { start: newest };
  const start = Math.min(newest, Math.max(0, at - Math.floor(WINDOW / 4)));
  const end = start + WINDOW;
  return end >= rows.length ? { start } : { start, end };
}

/// What a nested agent's line in a transcript does (BackgroundTasksPanel.tsx provides it): it opens
/// that agent's own transcript, and while it runs it carries the agent's stop button, so an agent at
/// any depth opens and stops from the panel.
export const NestedAgents = createContext<{
  open?(agentId: string): void;
  stop?(agentId: string, name: string): ReactNode;
}>({});
