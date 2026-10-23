// Read aloud under a message (Claude Code desktop's speaker): the system voice through the web
// view's speech synthesis, one message at a time. A second press on the message being read stops
// it; reading another stops the first.
import { useSyncExternalStore } from "react";

let speaking: string | undefined;
const listeners = new Set<() => void>();
const set = (id: string | undefined) => {
  speaking = id;
  for (const listener of listeners) listener();
};

/// Whether the page can speak: a web view without speech synthesis shows no Read aloud.
export const canReadAloud = () =>
  typeof window !== "undefined" && "speechSynthesis" in window && typeof SpeechSynthesisUtterance === "function";

/// Reads `text` (Markdown) aloud as message `id`, in `lang`; stops instead when `id` is being read.
export function readAloud(id: string, text: string, lang?: string): void {
  if (!canReadAloud()) return;
  const synth = window.speechSynthesis;
  const again = speaking === id;
  synth.cancel();
  if (again) {
    set(undefined);
    return;
  }
  const utterance = new SpeechSynthesisUtterance(spokenText(text));
  if (lang) utterance.lang = lang;
  // A cancelled utterance ends after the next one started: only its own end clears the state.
  utterance.onend = utterance.onerror = () => {
    if (speaking === id) set(undefined);
  };
  set(id);
  synth.speak(utterance);
}

/// Stops whatever message is being read: the chat moved to another session or left the page.
export function stopReadingAloud(): void {
  if (speaking === undefined) return;
  if (canReadAloud()) window.speechSynthesis.cancel();
  set(undefined);
}

/// Whether message `id` is being read now.
export function useReadingAloud(id: string): boolean {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => void listeners.delete(listener);
    },
    () => speaking === id,
    () => false,
  );
}

/// Markdown as it should be heard: link and image text without their addresses, no emphasis or
/// heading marks, code blocks left out.
export function spokenText(markdown: string): string {
  return markdown
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/`([^`]*)`/g, "$1")
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/^\s{0,3}(?:#{1,6}|>|[-*+]|\d+\.)\s+/gm, "")
    .replace(/(\*{1,3}|_{1,3}|~~)(\S(?:.*?\S)?)\1/g, "$2")
    .replace(/\s+/g, " ")
    .trim();
}
