import { type PaneLanguage, type Translate } from "../i18n";
import type { TurnTokenSplit } from "../model";

/// A token count, compact in the pane's language: 2.1M, 840K, 12.4K.
export const compactTokens = (language: PaneLanguage, tokens: number) =>
  new Intl.NumberFormat(language, { notation: "compact", maximumFractionDigits: 1 }).format(tokens);

/// "2.1M out": the turn's generated output, compact in the pane's language. Prompt and cache tokens
/// belong to the context card and the split's "in", and are never folded into this count.
export const workingTokens = (t: Translate, language: PaneLanguage, tokens: number) =>
  t("turn.working.outputTokens", { n: tokens, tokens: compactTokens(language, tokens) });

/// All the model read: its fresh input, the prompt cache's reads and its writes.
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

/// The split as plain words, "↓ 12.4K out ↑ 3.9M in", for a tooltip (TurnRows.tsx TurnFooter).
export const tokensText = (t: Translate, language: PaneLanguage, split: TurnTokenSplit) =>
  `${t("turn.tokens.out", { tokens: compactTokens(language, split.output) })} ${t("turn.tokens.in", {
    tokens: compactTokens(language, readTokens(split)),
  })}`;
