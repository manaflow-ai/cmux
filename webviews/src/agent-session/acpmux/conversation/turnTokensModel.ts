import { type PaneLanguage, type Translate } from "../i18n";
import type { TurnTokenSplit } from "../model";
import { cachedTokens, uncachedTokens } from "../tokenSplit";

/// A token count, compact in the pane's language: 2.1M, 840K, 12.4K.
export const compactTokens = (language: PaneLanguage, tokens: number) =>
  new Intl.NumberFormat(language, { notation: "compact", maximumFractionDigits: 1 }).format(tokens);

/// "2.1M out": the turn's generated output, compact in the pane's language. Prompt and cache tokens
/// belong to the context card and the split's "in", and are never folded into this count.
export const workingTokens = (t: Translate, language: PaneLanguage, tokens: number) =>
  t("turn.working.outputTokens", { n: tokens, tokens: compactTokens(language, tokens) });

/// All the model read over the turn's calls: its fresh input, the prompt cache's reads and its
/// writes. Each call reads the whole context again, so this is what was billed, not what any call held.
export const readTokens = (split: TurnTokenSplit) => split.input + split.cacheRead + split.cacheWrite;

/// Whether a split has any tokens to show: an all-zero one (an empty turn_result) draws nothing,
/// and so takes no separator either.
export const hasTokens = (split: TurnTokenSplit | undefined): split is TurnTokenSplit =>
  split !== undefined && split.output + readTokens(split) > 0;

/// The hover: "Output 12.4K · fresh input 1.2K · cache reads 3.8M · cache writes 40K".
export const tokenDetail = (t: Translate, language: PaneLanguage, split: TurnTokenSplit) =>
  t("turn.tokens.detail", {
    output: compactTokens(language, split.output),
    input: compactTokens(language, split.input),
    cacheRead: compactTokens(language, split.cacheRead),
    cacheWrite: compactTokens(language, split.cacheWrite),
  });

const UNCACHED = "\ue000";
const CACHED = "\ue001";
const NBSP = "\u00a0";

/// A row's translated text with each count in its place and held to the words after it, up to the
/// row's next " · " ("14.2K uncached", "14,2 k hors cache"): the reply time's tooltip is plain text
/// (a `title`, ui/titleTooltips.ts), so no span can keep them together, and a narrow pane wraps
/// between parts, never between a count and its word. Every locale puts the count before its words.
function countsWithTheirWords(row: string, counts: ReadonlyMap<string, string>): string {
  const held = row.replace(
    /([\ue000\ue001])([^·]*)/g,
    (_, marker: string, words: string) => marker + words.replace(/\s+(?=\S)/g, NBSP),
  );
  return held.replace(/[\ue000\ue001]/g, (marker) => counts.get(marker) ?? "");
}

/// The reply time's token rows (TurnRows.tsx TurnFooter), one count per row: "Output 5.1K", "Input
/// 14.2K uncached · 930.9K cached", "Context at end 139.9K", "Model calls 7". The input row's two
/// counts are its calls' added up (Leo, 2026-11-09: "we can prob just have the last line be Input");
/// the context is what the chat held after the last call, so it is never that sum. A turn an older acpmux recorded has no context and
/// no call count, and draws neither row (gallery `agent-pane.reply-time-tokens`).
export const tokenRows = (t: Translate, language: PaneLanguage, split: TurnTokenSplit): string[] => [
  t("turn.tokens.outputRow", { tokens: compactTokens(language, split.output) }),
  countsWithTheirWords(
    t("turn.tokens.inputRow", { uncached: UNCACHED, cached: CACHED }),
    new Map([
      [UNCACHED, compactTokens(language, uncachedTokens(split))],
      [CACHED, compactTokens(language, cachedTokens(split))],
    ]),
  ),
  ...(split.context ? [t("turn.tokens.contextRow", { tokens: compactTokens(language, split.context) })] : []),
  ...(split.calls ? [t("turn.tokens.callsRow", { n: new Intl.NumberFormat(language).format(split.calls) })] : []),
];

/// A reply time's tooltip: its words on the first line ("Worked for 13s", "Stopped by cmux"), then
/// the turn's token rows (`tokenRows`), or unset when it has neither. The title tooltip keeps the
/// line breaks (desktop.css `.ui-title-tooltip`).
export function replyTimeDetail(
  t: Translate,
  language: PaneLanguage,
  words: readonly (string | undefined)[],
  split: TurnTokenSplit | undefined,
): string | undefined {
  const head = words.filter(Boolean).join(" · ");
  const lines = [...(head ? [head] : []), ...(hasTokens(split) ? tokenRows(t, language, split) : [])];
  return lines.length ? lines.join("\n") : undefined;
}
