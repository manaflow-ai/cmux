// A compaction of the chat's context, noted where it happened (acpmux `compaction`): "Compacting
// the conversation…" while it runs, then how it ended and how much context it left. A compaction
// subrouter ran to move the chat to another account says so. Drawn as a tool row, like a
// background task's end (BackgroundTaskNote.tsx).
//
// A failover note says acpmux moved the chat onto its fallback harness after a usage limit, which
// is otherwise invisible: the turn just goes on, answered by another harness.
import { useT } from "../i18n";
import type { AcpmuxCompaction, AcpmuxFailover } from "../model";
import { ArrowRight, Spinner, SummaryToggle } from "./icons";

/// 27183 -> "27k", 2470 -> "2.5k"; under a thousand as is.
export function compactTokens(tokens: number): string {
  if (tokens < 1000) return String(tokens);
  const thousands = tokens / 1000;
  return `${thousands < 10 ? thousands.toFixed(1).replace(/\.0$/, "") : Math.round(thousands)}k`;
}

export function CompactionNote({ compaction }: { compaction: AcpmuxCompaction }) {
  const t = useT();
  const { state, reason, preTokens, postTokens } = compaction;
  const accountSwitch = reason === "account_switch";
  let text: string;
  if (state === "running") text = accountSwitch ? t("compaction.runningAccountSwitch") : t("compaction.running");
  else if (state === "failed") text = t("compaction.failed");
  else {
    text = accountSwitch ? t("compaction.completedAccountSwitch") : t("compaction.completed");
    if (preTokens !== undefined && postTokens !== undefined)
      text = t("compaction.withSizes", { text, before: compactTokens(preTokens), after: compactTokens(postTokens) });
  }
  return (
    <div className="cv-tools">
      <div className="cv-tool cv-compaction" data-state={state}>
        <span className="cv-tool__icon">{state === "running" ? <Spinner /> : <SummaryToggle />}</span>
        <span className="cv-tool__text">{text}</span>
      </div>
    </div>
  );
}

export function FailoverNote({ failover }: { failover: AcpmuxFailover }) {
  const t = useT();
  return (
    <div className="cv-tools">
      <div className="cv-tool cv-failover">
        <span className="cv-tool__icon">
          <ArrowRight />
        </span>
        <span className="cv-tool__text">{t("failover.continued", { from: failover.from, to: failover.to })}</span>
      </div>
    </div>
  );
}
