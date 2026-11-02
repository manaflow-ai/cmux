// A turn's tokens on its line: "↓ 12.4K out ↑ 3.9M in", output first, as Anthropic talks about a
// turn's spend (Leo, 2026-10-21: "usually anthropic talks about output instead of read tokens... its
// ok if we show both, we just ought to split it up"). "out" is only what the model generated (the
// turn's count, direct.ts `turnTokens`); "in" is all the model read: the fresh input, the prompt
// cache's reads and its writes; the hover names each. The two are never folded into one total. A
// turn whose calls named their output but not what they read shows "2.1M out". The running line
// (Thinking.tsx, WorkingFor.tsx) and a finished turn's "Worked for" (TurnRows.tsx) draw it in the
// line's quieter tertiary text and tabular numerals (conversation.css `.cv-worked__tokens`).
import type { ReactNode } from "react";
import { type PaneLanguage, type Translate, usePaneLanguage, useT } from "../i18n";
import type { TurnTokenSplit } from "../model";
import { formatDuration } from "./turns";

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

/// The tokens' span (no separator before it). `split` wins over `total` when both are known.
export function TurnTokens({ total, split }: { total?: number; split?: TurnTokenSplit }) {
  const t = useT();
  const language = usePaneLanguage();
  if (hasTokens(split))
    return (
      <span className="cv-worked__tokens is-split" title={tokenDetail(t, language, split)}>
        <span className="cv-worked__tokens-part">
          {t("turn.tokens.out", { tokens: compactTokens(language, split.output) })}
        </span>
        <span className="cv-worked__tokens-part">
          {t("turn.tokens.in", { tokens: compactTokens(language, readTokens(split)) })}
        </span>
      </span>
    );
  if (!total) return null;
  return <span className="cv-worked__tokens">{workingTokens(t, language, total)}</span>;
}

/// "Worked for 1m 16s" with its time in the line's quieter color: the translated label split around
/// its time, so the words keep their place in every language.
export function TimedLabel({ text, time }: { text: (time: string) => string; time: number }): ReactNode {
  const shown = formatDuration(time);
  const marker = "\u0000";
  const [before, after] = text(marker).split(marker);
  if (after === undefined) return text(shown);
  return (
    <>
      {before}
      <span className="cv-worked__label-time">{shown}</span>
      {after}
    </>
  );
}
