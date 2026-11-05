// l10n-allow-file: the verbs are English wordplay with no translation; other languages keep "Thinking".
// The live line's word before a turn's first step: a playful verb per turn, as the Claude Code CLI's
// spinner says "Pondering…" or "Noodling…", instead of "Thinking" every time (Leo, 2026-11-04: "instead
// of just always saying thinking all the time. I feel like it's got a little spunk, a little personality
// to it"). The agent pane provides the list (`ThinkingVerbsContext`); with none (the guest page, Chief
// web, galleries and replays, until they opt in) the line reads "Thinking".
import { createContext } from "react";
import { DEFAULT_STATUS_VERBS } from "../statusVerbs";

export const THINKING_VERBS = DEFAULT_STATUS_VERBS;

/// The verbs the live line picks from, or none for the plain translated "Thinking".
export const ThinkingVerbsContext = createContext<readonly string[] | undefined>(undefined);

/// The pane's verbs in `language`: the list in English, none in a language the wordplay doesn't reach.
export function thinkingVerbsFor(language: string): readonly string[] | undefined {
  return language === "en" || language.startsWith("en-") ? THINKING_VERBS : undefined;
}

/// The turn's verb, from its prompt's row id (`key`, the live row's `verbKey`): one verb for the
/// whole turn, since the id outlives the prompt's echo, clock offsets and retries that move its time,
/// and a new one for the next turn.
export function thinkingVerb(verbs: readonly string[] | undefined, key: string | undefined): string | undefined {
  if (!verbs?.length || !key) return undefined;
  // FNV-1a over the id, so ids that differ by one character still land far apart in the list.
  let hash = 2166136261;
  for (let index = 0; index < key.length; index += 1) {
    hash ^= key.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return verbs[(hash >>> 0) % verbs.length];
}
