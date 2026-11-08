// A turn's tokens, read from acpmux's records (hub/turn_usage.rs, claude_stdio/prompt_cache.rs).
// Every count but `context` is the turn's model calls added up, and each call reads the whole
// context again: a turn of 58 calls whose context ended at 125K read 4.7M, nearly all of it from
// the prompt cache. So "in" is never that sum: it is the uncached input (the fresh input and the
// cache's writes, what the turn sent the model new), the cache's reads are named apart as cached,
// and `context` is what the context held after the turn's last call (Leo, 2026-11-08: "I feel like
// you're overcounting it by a bit ... you can probably say cached, uncached, perhaps, like, amount
// from context").
import type { TurnTokenSplit } from "./model";

const tokenCount = (value: unknown) => (typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : 0);
const positive = (value: unknown) =>
  typeof value === "number" && Number.isFinite(value) && value > 0 ? value : undefined;

/// What the turn sent the model new: its fresh input and the cache's writes, over all its calls.
export const uncachedTokens = (split: TurnTokenSplit) => split.input + split.cacheWrite;

/// What its calls read again from the prompt cache, added up.
export const cachedTokens = (split: TurnTokenSplit) => split.cacheRead;

/// A marked call's split (claude_stdio/prompt_cache.rs `call_usage`): its output apart from what it
/// read, the fresh input, cache reads and cache writes, and the chat's context after it
/// (`contextTokens`, a main-loop call's only). Unset for a call that names no output or no input (an
/// older acpmux).
export function callTokenSplit(update: any, output: number | undefined): TurnTokenSplit | undefined {
  if (output === undefined || typeof update?.inputTokens !== "number") return undefined;
  const context = positive(update.contextTokens);
  return {
    output,
    input: tokenCount(update.inputTokens),
    cacheRead: tokenCount(update.cachedReadTokens),
    cacheWrite: tokenCount(update.cachedWriteTokens),
    ...(context !== undefined ? { context } : {}),
  };
}

/// A `turn_result`'s tokens (acpmux hub/turn_usage.rs), when it names its output and has any (an
/// all-zero result is an empty turn, with nothing to show), with its context and model calls when
/// the daemon names them (an older one does not).
export function resultTokenSplit(msg: any): TurnTokenSplit | undefined {
  if (typeof msg?.outputTokens !== "number") return undefined;
  const context = positive(msg.contextTokens);
  const calls = positive(msg.modelCalls);
  const split: TurnTokenSplit = {
    output: tokenCount(msg.outputTokens),
    input: tokenCount(msg.inputTokens),
    cacheRead: tokenCount(msg.cacheReadTokens),
    cacheWrite: tokenCount(msg.cacheWriteTokens),
    ...(context !== undefined ? { context } : {}),
    ...(calls !== undefined ? { calls } : {}),
  };
  return split.output + split.input + split.cacheRead + split.cacheWrite > 0 ? split : undefined;
}

/// The running turn's split with one more call: the counts add up, the call is counted, and the
/// context is the newest a main-loop call named (a subagent's call names none and leaves it).
export function addSplit(sum: TurnTokenSplit, call: TurnTokenSplit): TurnTokenSplit {
  const context = call.context ?? sum.context;
  return {
    output: sum.output + call.output,
    input: sum.input + call.input,
    cacheRead: sum.cacheRead + call.cacheRead,
    cacheWrite: sum.cacheWrite + call.cacheWrite,
    ...(context !== undefined ? { context } : {}),
  };
}

export const NO_TOKENS: TurnTokenSplit = { output: 0, input: 0, cacheRead: 0, cacheWrite: 0 };
