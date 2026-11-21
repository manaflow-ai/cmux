import { useEffect, useRef } from "react";
import type { FloatingState } from "./floatingState";
import type { ComposerAttachment } from "./attachments";

/// What the compact bar shows of the chat: working, waiting on the user, or quiet.
export type FloatingStatus = "streaming" | "attention" | "idle";

/// Start Agent's floating chat around its page (cx-b9qi): the App's state and the page's asks.
export interface QuickFloating {
  readonly state: FloatingState;
  readonly status: FloatingStatus;
  readonly title: string;
  /// The reply's last line, for the compact bar.
  readonly line?: string;
  setOnTop(onTop: boolean): void;
  setCollapsed(collapsed: boolean): void;
  moveToTab(): void;
  /// Include focused tab: attaches what the user is looking at in cmux to the next prompt, as a chip.
  includeContext(): void;
}

/// Include focused tab's chip from the App's `quick.context` reply (`{name, text}`), or nothing when
/// the user is looking at nothing it can include. One chip at a time: a newer one replaces it. An
/// untitled tab's chip is named `fallback`.
export function contextAttachment(value: unknown, fallback: string): ComposerAttachment | undefined {
  const raw = (value ?? {}) as { name?: unknown; text?: unknown };
  if (typeof raw.text !== "string" || !raw.text.trim()) return undefined;
  const name = typeof raw.name === "string" && raw.name.trim() ? raw.name : fallback;
  return { id: "floating-context", kind: "text", name, mimeType: "text/plain", size: raw.text.length, text: raw.text };
}

/// The chat's state for the compact bar: an ask waiting on the user comes first, then a turn running.
export function floatingStatus(waiting: boolean, running: boolean): FloatingStatus {
  if (waiting) return "attention";
  return running ? "streaming" : "idle";
}

/// The floating chat's keys while it holds a chat: ⌘J folds it to the compact bar and back, ⌘⇧I
/// includes the focused tab. They are the panel's own, like Return and Escape. ⌘⇧P is not one: it
/// is the app's command palette in every web view (Lawrence 2026-10-19), so the app takes it before
/// the page; Keep on Top is the header's pin button.
export function useFloatingKeys(floating: QuickFloating | undefined) {
  const latest = useRef(floating);
  latest.current = floating;
  const holding = floating?.state.holding === true;
  useEffect(() => {
    if (!holding) return;
    const onKey = (event: KeyboardEvent) => {
      const current = latest.current;
      if (!current || event.isComposing || !event.metaKey || event.altKey || event.ctrlKey) return;
      const key = event.key.toLowerCase();
      if (key === "j" && !event.shiftKey) current.setCollapsed(!current.state.collapsed);
      else if (key === "i" && event.shiftKey && !current.state.collapsed) current.includeContext();
      else return;
      event.preventDefault();
      event.stopPropagation();
    };
    // ui-allow: the floating panel's own window keys (⌘J, ⌘⇧I), wherever focus is in its page, like an app menu key.
    document.addEventListener("keydown", onKey, true);
    return () => document.removeEventListener("keydown", onKey, true);
  }, [holding]);
}
