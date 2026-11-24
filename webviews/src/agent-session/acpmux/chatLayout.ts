import { useSyncExternalStore } from "react";

/// The chat's structure a look reshapes, beyond its paint (examples/looks/README.md "Chat layout"):
/// the `agentPane.display.layout.*` rows (schemas/settings/source/agent-pane-display.json). The
/// host's `display` event carries them with the rest of the chat's look (setChatDisplay), so a
/// changed setting reshapes the open chat at once, with no reload. Each value lands on the page
/// root as a data attribute (`<html data-chat-messages="flat">`) and chatLayout.css draws it; the
/// default of each leaves no attribute, so a page with none of these set renders as before.
///
/// Every arm is height-neutral for the transcript's row model (model.ts): a message keeps its
/// padding, line height and column share, only its side, fill and outline change, so the
/// virtual list's measured heights stay right when a look switches under an open chat.
export const CHAT_LAYOUT = {
  messages: { key: "agentPane.display.layout.messages", attr: "chatMessages", arms: ["bubbles", "flat", "card"] },
  composer: { key: "agentPane.display.layout.composer", attr: "chatComposer", arms: ["rounded", "pill", "square"] },
  header: { key: "agentPane.display.layout.header", attr: "chatHeader", arms: ["full", "quiet"] },
} as const;

type Slots = typeof CHAT_LAYOUT;
export type ChatLayout = { [K in keyof Slots]: Slots[K]["arms"][number] };

export const DEFAULT_CHAT_LAYOUT: ChatLayout = {
  messages: "bubbles",
  composer: "rounded",
  header: "full",
};

/// The layout a `display` map asks for; an unknown or missing value is that slot's default.
export function resolveChatLayout(raw: unknown): ChatLayout {
  const values = (raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {}) as Record<string, unknown>;
  const out = { ...DEFAULT_CHAT_LAYOUT } as Record<string, string>;
  for (const [slot, spec] of Object.entries(CHAT_LAYOUT)) {
    const value = values[spec.key];
    if (typeof value === "string" && (spec.arms as readonly string[]).includes(value)) out[slot] = value;
  }
  return out as ChatLayout;
}

/// Writes `layout` onto `root` as data attributes; a slot at its default removes its attribute.
export function applyChatLayout(root: HTMLElement, layout: ChatLayout): void {
  for (const [slot, spec] of Object.entries(CHAT_LAYOUT) as [keyof Slots, Slots[keyof Slots]][]) {
    const value = layout[slot];
    if (value === DEFAULT_CHAT_LAYOUT[slot]) delete root.dataset[spec.attr];
    else root.dataset[spec.attr] = value;
  }
}

let current: ChatLayout = DEFAULT_CHAT_LAYOUT;
const listeners = new Set<() => void>();

/// The `display` event's map (chatDisplay.ts setChatDisplay): the page follows at once.
export function configureChatLayout(raw: unknown): void {
  const next = resolveChatLayout(raw);
  if (typeof document !== "undefined") applyChatLayout(document.documentElement, next);
  if (JSON.stringify(next) === JSON.stringify(current)) return;
  current = next;
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => current;

export const useChatLayout = (): ChatLayout => useSyncExternalStore(subscribe, snapshot, snapshot);
