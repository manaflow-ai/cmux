// The line over a running turn's work: "Working for 42s", ticking each second from the prompt,
// or held at `durationMs` while text streams. While a call runs (`row.doing`, turns.ts) it names
// that call beside the time instead, as Claude desktop's line does. No mark blinks before it; the
// ticking time says the turn is alive. After that it counts the work still going in the background, as Claude's
// phone app does ("Working… · 5 running tasks"): "· 2 agents · 1 command", only subagents still
// running and background shells that have not ended. Each count opens what it counts. The counts
// follow on the same fixed-height line, so one that comes or goes moves neither the label nor the
// rows below. Before them, as Claude desktop's line does, it says the turn's tokens so far
// ("5m 54s · 2.1M tokens") when the harness reports them (direct.ts `turnTokens`). When the turn
// ends, the "Worked for" disclosure takes its place.
import { createContext, useContext, useEffect, useState } from "react";
import { type PaneLanguage, type Translate, usePaneLanguage, useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { formatDuration } from "./turns";

export const workingLabel = (t: Translate, at: number, now: number) =>
  t("turn.working", { time: formatDuration(Math.max(0, now - at)) });

/// What the running turn's line counts (App.tsx): the subagents and background shells still
/// running, and what opens each.
export type WorkingCounts = {
  agents: number;
  commands: number;
  openAgents: () => void;
  openCommands: () => void;
  /// The turn's tokens so far (snapshot `turnTokens`), when the harness reports them.
  tokens?: number;
};

/// "2.1M tokens": the running turn's tokens, compact in the pane's language.
export const workingTokens = (t: Translate, language: PaneLanguage, tokens: number) =>
  t("turn.working.tokens", {
    n: tokens,
    tokens: new Intl.NumberFormat(language, { notation: "compact", maximumFractionDigits: 1 }).format(tokens),
  });

export const WorkingCountsContext = createContext<WorkingCounts | undefined>(undefined);

export function WorkingFor({ row, now = Date.now }: { row: AcpmuxRow; now?: () => number }) {
  const t = useT();
  const language = usePaneLanguage();
  const counts = useContext(WorkingCountsContext);
  const [time, setTime] = useState(now);
  const held = row.durationMs !== undefined;
  useEffect(() => {
    if (held) return;
    setTime(now());
    const timer = setInterval(() => setTime(now()), 1000);
    return () => clearInterval(timer);
  }, [now, held]);
  const until = held ? row.at + row.durationMs! : time;
  const parts = counts
    ? [
        counts.agents > 0 && {
          key: "agents",
          label: t("turn.working.agents", { n: counts.agents }),
          open: counts.openAgents,
        },
        counts.commands > 0 && {
          key: "commands",
          label: t("turn.working.commands", { n: counts.commands }),
          open: counts.openCommands,
        },
      ].filter((part) => part !== false)
    : [];
  // Find counts and visits transcript rows only (chatFind.ts findMatches skips this row), so the
  // line is not painted either: the call it names is matched on its own tool row.
  return (
    <div className="cv-worked has-divider" data-find-skip>
      {row.doing ? (
        <>
          <span className="cv-worked__label cv-worked__doing">{row.doing}</span>
          <span className="cv-worked__time">{formatDuration(Math.max(0, until - row.at))}</span>
        </>
      ) : (
        <span className="cv-worked__label">{workingLabel(t, row.at, until)}</span>
      )}
      {counts?.tokens ? (
        <span className="cv-worked__count">
          <span className="cv-worked__sep" aria-hidden="true">
            ·
          </span>
          <span className="cv-worked__tokens">{workingTokens(t, language, counts.tokens)}</span>
        </span>
      ) : null}
      {parts.map((part) => (
        <span key={part.key} className="cv-worked__count">
          <span className="cv-worked__sep" aria-hidden="true">
            ·
          </span>
          <button type="button" className="cv-worked__open" onClick={part.open}>
            {part.label}
          </button>
        </span>
      ))}
    </div>
  );
}
