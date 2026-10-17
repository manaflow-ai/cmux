// acpmux operations the pane uses only when acpmux says it serves them. Names follow the
// operation catalog (cmux-next-spec spec/acp-ui.md, family `acp.*`, owner acpmux).

/// Fork a session through one of its turns: `{ sessionId, throughSeq }` → `{ sessionId }` of
/// the new session, holding the source's events up to and including `throughSeq`.
export const FORK_OP = "acp.session.fork";

/// One finalized recording becomes an agent prompt. The adapter owns the audio
/// encoding; the pane only asks for this operation when the daemon advertises it.
export const PROMPT_AUDIO_OP = "acp.prompt.audio";

/// Thread-scoped realtime voice operations. These are separate from dictation:
/// realtime keeps the microphone and speaker session open across turns.
export const REALTIME_VOICE_OPS = {
  start: "acp.realtime.start",
  appendAudio: "acp.realtime.appendAudio",
  stop: "acp.realtime.stop",
} as const;

export type PromptCapabilities = {
  image?: boolean;
  audioInput?: boolean;
  dictation?: boolean;
  realtimeVoice?: boolean;
  audioOutput?: boolean;
};

/// Whether acpmux's `initialize` result lists `op` among the operations it serves
/// (`_meta.acpmux.operations`). An acpmux that does not list it does not get asked.
export function servesOperation(initialize: unknown, op: string): boolean {
  const operations = (initialize as { _meta?: { acpmux?: { operations?: unknown } } } | undefined)?._meta?.acpmux
    ?.operations;
  return Array.isArray(operations) && operations.includes(op);
}

/// Realtime voice requires every operation in the set. A daemon that only
/// supports one-shot audio must leave the live voice UI hidden.
export function servesRealtimeVoice(initialize: unknown): boolean {
  return Object.values(REALTIME_VOICE_OPS).every((operation) => servesOperation(initialize, operation));
}
