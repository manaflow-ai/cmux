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

/// The chat a `turn_result` is from, as acpmux's session summary names it: its harness and family,
/// and `backgroundsWork`, which acpmux sets for a chat running Claude Code over its stream
/// (claude-stdio), whatever its profile is named (hub/processes.rs `backgrounds_work`).
export type ResultHarness = { harness?: string; family?: string; backgroundsWork?: boolean };

/// Whether a `turn_result`'s `inputTokens` is its fresh input alone. acpmux marks every record it
/// writes so (`inputExcludesCache`, hub/turn_usage.rs). An older acpmux wrote no mark: its Claude
/// records were fresh-only too (Claude names its input, cache reads and cache writes apart), but its
/// ACP records (Codex's, Gemini's) counted the cache in the input, so a Codex turn of 314.9K fresh
/// and 3M cached read "3.3M uncached". A Claude chat is told by how it runs where acpmux says
/// (`backgroundsWork`: Claude Code over its stream), else by its names: a harness that is a Claude
/// (`claude`, `claude-acp`), a Claude leaf family (`claude-sr2`), or the `cmux` model router's
/// profile (harness `cmux`, family `claude`: Claude Code too). Plain family `claude` alone is not
/// one, as opencode on a Claude model is filed under it with its own usage. With no chat named, the
/// record's model names a Claude. A record that says none of it is read as counting its cache, the
/// reading that can never count a token twice: at worst it shows a Claude turn's uncached input
/// low, never a Codex turn's cached reads again as uncached.
function inputIsFresh(msg: any, chat: ResultHarness | undefined): boolean {
  if (msg?.inputExcludesCache === true) return true;
  if (chat?.backgroundsWork === true) return true;
  const harness = chat?.harness?.trim().toLowerCase();
  const family = chat?.family?.trim().toLowerCase();
  if (harness || family)
    return (
      !!harness?.startsWith("claude") || !!family?.startsWith("claude-") || (harness === "cmux" && family === "claude")
    );
  return typeof msg?.model === "string" && /claude|opus|sonnet|haiku/i.test(msg.model);
}

/// A `turn_result`'s tokens (acpmux hub/turn_usage.rs), when it names its output and has any (an
/// all-zero result is an empty turn, with nothing to show), with its context and model calls when
/// the daemon names them (an older one does not). Its input is the fresh part alone: an older
/// acpmux's unmarked record of a harness that counted its cache in it has the cache taken out
/// (`inputIsFresh`), at no less than none.
export function resultTokenSplit(msg: any, chat?: ResultHarness): TurnTokenSplit | undefined {
  if (typeof msg?.outputTokens !== "number") return undefined;
  const context = positive(msg.contextTokens);
  const calls = positive(msg.modelCalls);
  const cacheRead = tokenCount(msg.cacheReadTokens);
  const cacheWrite = tokenCount(msg.cacheWriteTokens);
  const input = tokenCount(msg.inputTokens);
  const split: TurnTokenSplit = {
    output: tokenCount(msg.outputTokens),
    input: inputIsFresh(msg, chat) ? input : Math.max(0, input - cacheRead - cacheWrite),
    cacheRead,
    cacheWrite,
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
