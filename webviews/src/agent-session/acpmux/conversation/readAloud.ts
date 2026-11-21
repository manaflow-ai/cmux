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
export function readAloud(id: string, text: string, paneLanguage?: string): void {
  if (!canReadAloud()) return;
  const again = speaking === id;
  // The voice follows the message's script when it is not the pane's (a Japanese reply under an
  // English pane would go to an English voice).
  const lang = again ? paneLanguage : spokenLanguage(spokenText(text), paneLanguage);
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

// Scripts that name their language well enough to pick a voice, tested on letters only (digits and
// punctuation of a script's block, such as Arabic-Indic digits, say nothing about the language). Latin
// text cannot tell English from Spanish by its letters, so it keeps the pane's language.
const SCRIPTS = [
  { id: "kana", pattern: /^[\p{scx=Hiragana}\p{scx=Katakana}]$/u, language: "ja", family: ["ja"] },
  { id: "hangul", pattern: /^\p{scx=Hangul}$/u, language: "ko", family: ["ko"] },
  // Han alone is ambiguous between Japanese and Chinese: a pane in either keeps its own voice.
  { id: "han", pattern: /^\p{scx=Han}$/u, language: "zh-CN", family: ["zh", "yue", "ja"] },
  {
    id: "cyrillic",
    pattern: /^\p{scx=Cyrillic}$/u,
    language: "ru",
    family: ["ru", "uk", "bg", "sr", "be", "mk", "kk"],
  },
  { id: "arabic", pattern: /^\p{scx=Arabic}$/u, language: "ar", family: ["ar", "fa", "ur"] },
  { id: "hebrew", pattern: /^\p{scx=Hebrew}$/u, language: "he", family: ["he"] },
  { id: "thai", pattern: /^\p{scx=Thai}$/u, language: "th", family: ["th"] },
  { id: "greek", pattern: /^\p{scx=Greek}$/u, language: "el", family: ["el"] },
  { id: "devanagari", pattern: /^\p{scx=Devanagari}$/u, language: "hi", family: ["hi", "mr", "ne"] },
] as const;

/// The language to speak `text` in: the pane's `fallback` unless the text's letters are mostly another
/// script (a Japanese reply read by an English voice is noise). Kana marks Japanese even among Han
/// characters; a fallback in the same script's family (zh-Hant for Han text) is kept.
export function spokenLanguage(text: string, fallback?: string): string | undefined {
  let letters = 0;
  const counts = new Map<string, number>();
  for (const [letter] of text.matchAll(/\p{L}/gu)) {
    letters++;
    const script = SCRIPTS.find((candidate) => candidate.pattern.test(letter));
    if (script) counts.set(script.id, (counts.get(script.id) ?? 0) + 1);
  }
  if (!letters) return fallback;
  // Japanese mixes Han with kana, which Chinese has none of, so with enough kana among the CJK letters
  // the Han are Japanese too. A stray quoted kana word in a Chinese sentence is too few to turn it.
  const kana = counts.get("kana") ?? 0;
  const han = counts.get("han") ?? 0;
  const japanese = kana > 0 && kana * 5 >= kana + han;
  if (japanese) counts.set("kana", kana + han);
  let best: (typeof SCRIPTS)[number] | undefined;
  let bestCount = 0;
  for (const script of SCRIPTS) {
    if (script.id === "han" && japanese) continue;
    const count = counts.get(script.id) ?? 0;
    if (count > bestCount) [best, bestCount] = [script, count];
  }
  // Under a third of the letters is a quoted word or name, not the message's language.
  if (!best || bestCount * 3 < letters) return fallback;
  const base = fallback?.split("-")[0]?.toLowerCase();
  return base && (best.family as readonly string[]).includes(base) ? fallback : best.language;
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
