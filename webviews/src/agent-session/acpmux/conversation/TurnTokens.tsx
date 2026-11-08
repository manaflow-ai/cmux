// A turn's tokens on its line: "↓ 12.4K out ↑ 3.9M in", output first, as Anthropic talks about a
// turn's spend (Leo, 2026-10-21: "usually anthropic talks about output instead of read tokens... its
// ok if we show both, we just ought to split it up"). "out" is only what the model generated (the
// turn's count, direct.ts `turnTokens`); "in" is the uncached input, what the turn sent the model new
// (its fresh input and the prompt cache's writes), never every call's reads added up, since each call
// reads the whole context again (tokenSplit.ts); the hover names each part. The two are never folded
// into one total. A
// turn whose calls named their output but not what they read shows "2.1M out". The line over a
// running turn (WorkingFor.tsx) and a finished turn's "Worked for" (TurnRows.tsx) draw it in the
// line's quieter tertiary text and tabular numerals (conversation.css `.cv-worked__tokens`). The
// live line at the bottom (Thinking.tsx) says the output alone as Claude Code does, "47.4K tokens",
// with this split on its hover (liveLineTokens.experiment.ts).
import type { ReactNode } from "react";
import { usePaneLanguage, useT } from "../i18n";
import type { TurnTokenSplit } from "../model";
import { uncachedTokens } from "../tokenSplit";
import { formatDuration } from "./turns";
import { compactTokens, workingTokens, hasTokens, tokenDetail } from "./turnTokensModel";
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
          {t("turn.tokens.in", { tokens: compactTokens(language, uncachedTokens(split)) })}
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
