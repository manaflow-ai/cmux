// l10n-allow-file: the verbs are English wordplay with no translation; other languages keep "Thinking".
// The live line's word before a turn's first step: a playful verb per turn, as the Claude Code CLI's
// spinner says "Pondering…" or "Noodling…", instead of "Thinking" every time (Leo, 2026-11-04: "instead
// of just always saying thinking all the time. I feel like it's got a little spunk, a little personality
// to it"). The pane provides the list (`ThinkingVerbsContext`); with none, the line reads "Thinking".
import { createContext } from "react";

export const THINKING_VERBS: readonly string[] = [
  "Baking",
  "Brainstorming",
  "Brewing",
  "Calculating",
  "Caramelizing",
  "Channeling",
  "Churning",
  "Cmuxing",
  "Cogitating",
  "Composing",
  "Concocting",
  "Conjuring",
  "Considering",
  "Contemplating",
  "Cooking",
  "Crafting",
  "Crunching",
  "Daydreaming",
  "Deliberating",
  "Distilling",
  "Doodling",
  "Fermenting",
  "Fiddling",
  "Finagling",
  "Forging",
  "Gallivanting",
  "Grooving",
  "Hatching",
  "Ideating",
  "Imagining",
  "Improvising",
  "Incubating",
  "Kneading",
  "Marinating",
  "Meandering",
  "Mulling",
  "Musing",
  "Mustering",
  "Noodling",
  "Orbiting",
  "Percolating",
  "Philosophizing",
  "Pondering",
  "Puttering",
  "Puzzling",
  "Reckoning",
  "Ruminating",
  "Scheming",
  "Simmering",
  "Sketching",
  "Spelunking",
  "Steeping",
  "Stewing",
  "Synthesizing",
  "Tinkering",
  "Untangling",
  "Vibing",
  "Whirring",
  "Whisking",
  "Wondering",
  "Wrangling",
];

/// The verbs the live line picks from, or none for the plain translated "Thinking".
export const ThinkingVerbsContext = createContext<readonly string[] | undefined>(undefined);

/// The pane's verbs in `language`: the list in English, none in a language the wordplay doesn't reach.
export function thinkingVerbsFor(language: string): readonly string[] | undefined {
  return language === "en" || language.startsWith("en-") ? THINKING_VERBS : undefined;
}

/// The turn's verb, from when its prompt was sent (`since`): one verb for the whole turn, so the
/// line never changes its word while it runs, and a new one for the next turn.
export function thinkingVerb(verbs: readonly string[] | undefined, since: number | undefined): string | undefined {
  if (!verbs?.length || since === undefined) return undefined;
  // A small integer hash (FNV-style) of the time, so turns a second apart don't walk the list in order.
  let hash = 2166136261;
  for (let value = Math.floor(since); value > 0; value = Math.floor(value / 256)) {
    hash ^= value % 256;
    hash = Math.imul(hash, 16777619);
  }
  return verbs[(hash >>> 0) % verbs.length];
}
