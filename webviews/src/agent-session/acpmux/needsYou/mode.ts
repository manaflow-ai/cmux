// Needs you's mode, followed live (Leo 2026-10-22: "the needs you thingy doesnt even work yet ofc").
// The page starts with the host's `data-needs-you` on <html> (AgentPaneTunables documentAttributes);
// the host then pushes each change as the `needsYou` event (old host:
// `cmuxAcpmuxBridge.applyNeedsYou`), so installing the App Store item, or changing the Debug choice,
// reaches an open chat without a reload. The attribute stays the one value: a push writes it, so
// links.ts `needsYouListOff` agrees, and a reply's needs-you links (conversation/Markdown.tsx
// `NeedsYouLink`) redraw with the header. Kept apart from NeedsYou.tsx so the page host's event
// handler and a reply's Markdown do not load the list.
import { useSyncExternalStore } from "react";

/// The Debug choice `agentPane.debug.needsYou`: `pinned` (the default) draws each ask with its
/// answers; `compact` one line per ask; `off` no badge at all. The host also sends `off` while the
/// App Store's Needs You item is not installed (`agentPane.needsYou.enabled`, off by default): no
/// badge, no list, and no link opens one.
export type NeedsYouMode = "pinned" | "compact" | "off";

const listeners = new Set<() => void>();

function parse(value: unknown): NeedsYouMode {
  return value === "off" || value === "compact" ? value : "pinned";
}

/// The mode on <html> now.
export function needsYouMode(
  root: { dataset: DOMStringMap } | undefined = globalThis.document?.documentElement,
): NeedsYouMode {
  return parse(root?.dataset.needsYou);
}

/// The host's push: writes the mode on <html> and re-renders every reader. Anything but `compact`
/// or `off` is `pinned`, as the attribute reads.
export function setNeedsYouMode(value: unknown): void {
  const root = globalThis.document?.documentElement;
  if (!root) return;
  const next = parse(value);
  if (next === needsYouMode(root)) return;
  root.dataset.needsYou = next;
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

/// The mode; re-renders when the host pushes a new one.
export function useNeedsYouMode(): NeedsYouMode {
  // The server snapshot too: a reply's Markdown is also drawn to static markup.
  return useSyncExternalStore(subscribe, needsYouMode, needsYouMode);
}
