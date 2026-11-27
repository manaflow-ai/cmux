// Prompt coach (acpmux `coach_offer` and `coach` records; Leo, 2026-11-08: "go think of things/look
// at things, esp valuable things that people would think \"wow this is awesome\""). After a chat in
// which the person corrected the agent three or more times before moving on, acpmux logs a
// `coach_offer` at the end of a turn. The page then asks it once (`_acpmux/prompt_coach`, direct.ts)
// to rewrite the chat's first prompt with the context the person added later; it logs a `coach`
// record with the rewrite, and that record draws the card under the turn it lands in
// (PromptCoachCard.tsx). A `coach_offer` alone draws nothing: the card appears once, whole.

/// The row kind that draws a prompt coach card (rows/registry.tsx).
export const PROMPT_COACH = "promptCoach";

/// A row's id for a rewrite: one row per coach id.
export const coachRowId = (coachId: string) => `coach-${coachId}`;

export type PromptCoach = {
  coachId: string;
  /// The chat it coaches: what the card's × remembers (promptCoachDismissed.ts).
  sessionId: string;
  /// The chat's first prompt, as the person sent it.
  firstPrompt: string;
  /// That prompt rewritten with what the person said later, ready to copy.
  rewrite: string;
  /// How many times the person corrected the agent before moving on (three or more).
  corrections: number;
};

const count = (value: unknown) =>
  typeof value === "number" && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;

/// A `coach_offer` record's data: the coach id to ask for, or undefined for one without an id.
export function coachOfferFromRecord(data: unknown): { coachId: string; corrections: number } | undefined {
  if (!data || typeof data !== "object") return undefined;
  const record = data as Record<string, unknown>;
  const coachId = typeof record.coachId === "string" ? record.coachId : "";
  return coachId ? { coachId, corrections: count(record.corrections) } : undefined;
}

/// The coach id a `coach` record names, made or not drawable, so the page never asks for it again.
export const coachIdOf = (data: unknown): string =>
  data && typeof data === "object" && typeof (data as Record<string, unknown>).coachId === "string"
    ? ((data as Record<string, unknown>).coachId as string)
    : "";

/// A `coach` record's data as the card draws it, or undefined for one it cannot draw (no id, no
/// rewrite). The rewrite keeps its line breaks; only its outer blank lines go.
export function promptCoachFromRecord(data: unknown, sessionId: string): PromptCoach | undefined {
  if (!data || typeof data !== "object") return undefined;
  const record = data as Record<string, unknown>;
  const coachId = coachIdOf(record);
  const rewrite = typeof record.rewrite === "string" ? record.rewrite.replace(/^\s*\n|\s+$/g, "") : "";
  if (!coachId || !rewrite.trim()) return undefined;
  return {
    coachId,
    sessionId,
    firstPrompt: typeof record.firstPrompt === "string" ? record.firstPrompt : "",
    rewrite,
    corrections: count(record.corrections),
  };
}

/// The rewrite block's most lines before it scrolls (PromptCoachCard.css `--cv-coach-lines`).
export const COACH_MAX_LINES = 8;
/// One line of the rewrite block, in px (PromptCoachCard.css `--cv-coach-line`).
export const COACH_LINE_PX = 20;

/// How many lines the rewrite block draws at `width` (the row's), capped at COACH_MAX_LINES: each
/// paragraph wraps at about 7px a character inside the card's padding. The row estimate (model.ts)
/// uses it, so the card lands at its own height.
export function coachLines(rewrite: string, width: number): number {
  const perLine = Math.max(24, Math.floor((width - 56) / 7));
  let lines = 0;
  for (const paragraph of rewrite.split("\n")) {
    lines += Math.max(1, Math.ceil(paragraph.length / perLine));
    if (lines >= COACH_MAX_LINES) return COACH_MAX_LINES;
  }
  return Math.max(1, lines);
}
