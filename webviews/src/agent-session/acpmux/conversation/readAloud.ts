// Read aloud under a message (Claude Code desktop's speaker), one message at a time. A second press
// on the message being read stops it, reading another stops the first, and Escape stops it.
//
// In the cmux app the app speaks (CmuxNextAgentPane AgentPaneReadAloud): one system voice for every
// chat, so Stop Reading Aloud in the palette, the CLI and MCP reach it, and closing the chat stops
// it. The page's own speech synthesis could not be stopped once its WebKit view closed or
// hibernated mid-message (user, 2026-10-29). The app announces itself with a `readAloud` event
// (pageHost.ts) and pushes every change; a page without that host keeps the web view's voice.
import { useSyncExternalStore } from "react";
import { postNative } from "../native";

let speaking: string | undefined;
/// Whether the app speaks for this page: set by its first `readAloud` event.
let hosted = false;
const listeners = new Set<() => void>();
const set = (id: string | undefined) => {
  if (speaking === id) return;
  speaking = id;
  followEscape(id !== undefined);
  for (const listener of listeners) listener();
};

/// The app's request, through the page's direct actions when it has them (as App's callNative).
const callApp = (method: string, params: Record<string, unknown>) => {
  const direct = window.cmuxAcpmuxActions?.[method];
  return direct ? direct(params) : postNative(method, params);
};

/// Whether the page can speak: the app, or a web view with speech synthesis.
export const canReadAloud = () =>
  hosted ||
  (typeof window !== "undefined" && "speechSynthesis" in window && typeof SpeechSynthesisUtterance === "function");

/// The app's read-aloud state (`readAloud` host event, `{id}`): the message it reads, null for none.
export function setReadAloudState(value: unknown): void {
  hosted = true;
  const id = value && typeof value === "object" ? (value as { id?: unknown }).id : undefined;
  set(typeof id === "string" && id ? id : undefined);
}

/// Reads `text` (Markdown) aloud as message `id`, in `lang`; stops instead when `id` is being read.
export function readAloud(id: string, text: string, lang?: string): void {
  if (!canReadAloud()) return;
  const again = speaking === id;
  if (hosted) {
    // Drawn at once; the app's next `readAloud` event is the truth (a refusal clears it).
    set(again ? undefined : id);
    const request = again
      ? callApp("readAloud.stop", {})
      : callApp("readAloud.speak", { id, text: spokenText(text), ...(lang && { lang }) });
    void Promise.resolve(request).catch(() => {
      if (!again && speaking === id) set(undefined);
    });
    return;
  }
  const synth = window.speechSynthesis;
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

/// Stops whatever message is being read: Escape, the chat moved to another session or left the page.
export function stopReadingAloud(): void {
  if (speaking === undefined) return;
  set(undefined);
  if (hosted) void Promise.resolve(callApp("readAloud.stop", {})).catch(() => undefined);
  else if ("speechSynthesis" in window) window.speechSynthesis.cancel();
}

/// Whether message `id` is being read now.
export function useReadingAloud(id: string): boolean {
  return useSyncExternalStore(
    subscribe,
    () => speaking === id,
    () => false,
  );
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

/// Escape stops the reading: listened to only while something reads, first in the capture phase, so
/// the composer's Escape (stop the turn) waits for the next press.
let escapeOn = false;
function onEscape(event: KeyboardEvent) {
  if (event.key !== "Escape" || event.isComposing || speaking === undefined) return;
  event.preventDefault();
  event.stopImmediatePropagation();
  stopReadingAloud();
}
function followEscape(on: boolean) {
  if (on === escapeOn || typeof window === "undefined") return;
  escapeOn = on;
  if (on) window.addEventListener("keydown", onEscape, true);
  else window.removeEventListener("keydown", onEscape, true);
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
