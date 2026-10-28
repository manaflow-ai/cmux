// The tabs an agent marked as needing the person (tab-attention-v1, `cmux attention request`), as
// the host pushes them for every agent page (`attentionTabs`, CmuxNextAgentPane
// AgentPaneAttentionTabs): what to do there and the workspace and tab by their titles, never an
// id. Needs you lists each as a `tab` item (model.ts); its Go to asks the host to show the tab
// (`chat.attention.open`). A module store like newtab/nowPlaying.ts, so a push that arrives before
// the header mounts is kept. Leo, 2026-10-22: "idk where things are man i dont see anything other
// than the current workspace".
import { useSyncExternalStore } from "react";

export type AttentionTab = {
  /// The host's key for the tab (its machine and tab id); the page only echoes it back to Go to.
  tabId: string;
  /// The agent's one line: what the person must do in the tab.
  reason: string;
  workspaceTitle: string;
  tabTitle: string;
  /// When the agent marked it (epoch ms).
  atMs: number;
};

/// The host op a tab item's Go to calls (`cmux.agent.chat.attention.open {tabId}`).
export const ATTENTION_OPEN_OP = "chat.attention.open";

/// Longest text a pushed field keeps (the daemon caps a reason at 200 bytes).
const MAX_TEXT = 512;
const MAX_TAB_ID_BYTES = 256;

const EMPTY: readonly AttentionTab[] = [];
let tabs: readonly AttentionTab[] = EMPTY;
const listeners = new Set<() => void>();

const text = (value: unknown) => (typeof value === "string" ? value.slice(0, MAX_TEXT) : "");

/// The pushed list's well-formed entries, newest mark first: a `tab` entry with a tab id and a reason.
export function parseAttentionTabs(value: unknown): AttentionTab[] {
  if (!Array.isArray(value)) return [];
  const parsed: AttentionTab[] = [];
  for (const raw of value as unknown[]) {
    if (!raw || typeof raw !== "object") continue;
    const entry = raw as Record<string, unknown>;
    const tabId = text(entry.tabId);
    const reason = text(entry.reason).trim();
    // `atMs` is the daemon's whole, nonnegative epoch ms: anything else is no mark, as on the host.
    const atMs = entry.atMs;
    if (entry.kind !== "tab" || !tabId || new TextEncoder().encode(tabId).length > MAX_TAB_ID_BYTES || !reason) continue;
    if (typeof atMs !== "number" || !Number.isSafeInteger(atMs) || atMs < 0) continue;
    parsed.push({
      tabId,
      reason,
      workspaceTitle: text(entry.workspaceTitle),
      tabTitle: text(entry.tabTitle),
      atMs,
    });
  }
  return parsed.sort((a, b) => b.atMs - a.atMs);
}

/// Replaces the list from a host push; anything malformed is dropped.
export function setAttentionTabs(value: unknown): void {
  const next = parseAttentionTabs(value);
  tabs = next.length === 0 ? EMPTY : next;
  for (const listener of listeners) listener();
}

export function attentionTabs(): readonly AttentionTab[] {
  return tabs;
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useAttentionTabs(): readonly AttentionTab[] {
  return useSyncExternalStore(subscribe, attentionTabs, attentionTabs);
}
