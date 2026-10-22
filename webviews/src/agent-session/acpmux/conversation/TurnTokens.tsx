// A turn's tokens on its line: "↓ 12.4K out ↑ 3.9M in", output first, as Anthropic talks about a
// turn's spend (Leo, 2026-10-21: "usually anthropic talks about output instead of read tokens... its
// ok if we show both, we just ought to split it up"). "in" is all the model read: the fresh input,
// the prompt cache's reads and its writes; the hover names each. A harness that reports only a
// total (an older acpmux, a call without acpmux's split) shows "2.1M tokens". The running line
// (Thinking.tsx, WorkingFor.tsx) and a finished turn's "Worked for" (TurnRows.tsx) draw it in the
// line's quieter tertiary text and tabular numerals (conversation.css `.cv-worked__tokens`).
import type { ReactNode } from "react";
import { type PaneLanguage, type Translate, usePaneLanguage, useT } from "../i18n";
import type { TurnTokenSplit } from "../model";
import { formatDuration } from "./turns";

/// A token count, compact in the pane's language: 2.1M, 840K, 12.4K.
export const compactTokens = (language: PaneLanguage, tokens: number) =>
  new Intl.NumberFormat(language, { notation: "compact", maximumFractionDigits: 1 }).format(tokens);

/// "2.1M tokens": a turn's tokens as one count, compact in the pane's language.
export const workingTokens = (t: Translate, language: PaneLanguage, tokens: number) =>
  t("turn.working.tokens", { n: tokens, tokens: compactTokens(language, tokens) });

/// All the model read: its fresh input, the prompt cache's reads and its writes.
export const readTokens = (split: TurnTokenSplit) => split.input + split.cacheRead + split.cacheWrite;

/// The hover: "Output 12.4K · fresh input 1.2K · cache reads 3.8M · cache writes 40K".
export const tokenDetail = (t: Translate, language: PaneLanguage, split: TurnTokenSplit) =>
  t("turn.tokens.detail", {
    output: compactTokens(language, split.output),
    input: compactTokens(language, split.input),
    cacheRead: compactTokens(language, split.cacheRead),
    cacheWrite: compactTokens(language, split.cacheWrite),
  });

/// The tokens' span (no separator before it). `split` wins over `total` when both are known.
export function TurnTokens({ total, split }: { total?: number; split?: TurnTokenSplit }) {
  const t = useT();
  const language = usePaneLanguage();
  if (split && split.output + readTokens(split) > 0)
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
