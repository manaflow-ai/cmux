// A compaction of the chat's context, noted where it happened (acpmux `compaction`): "Compacting
// the conversation…" while it runs, then how it ended: how much context it left, or why it
// failed. One compaction is one note, however often Claude Code says it is still compacting. A compaction
// subrouter ran to move the chat to another account says so. Drawn as a tool row, like a
// background task's end (BackgroundTaskNote.tsx).
//
// A failover note says acpmux moved the chat onto its fallback harness after a usage limit, which
// is otherwise invisible: the turn just goes on, answered by another harness.
//
// A policy note says the chat's harness cannot keep its permission policy (acpmux
// `policy_unenforced`), which is otherwise invisible too: the chat still names the policy while
// its agent runs without the asks the policy would answer.
import { type StringKey, useT } from "../i18n";
import type { AcpmuxCompaction, AcpmuxFailover, AcpmuxPolicyUnenforced } from "../model";
import { ArrowRight, Lock, Spinner, SummaryToggle } from "./icons";

/// 27183 -> "27k", 2470 -> "2.5k"; under a thousand as is.
export function compactTokens(tokens: number): string {
  if (tokens < 1000) return String(tokens);
  const thousands = tokens / 1000;
  return `${thousands < 10 ? thousands.toFixed(1).replace(/\.0$/, "") : Math.round(thousands)}k`;
}

export function CompactionNote({ compaction }: { compaction: AcpmuxCompaction }) {
  const t = useT();
  const { state, reason, error, preTokens, postTokens } = compaction;
  const accountSwitch = reason === "account_switch";
  let text: string;
  if (state === "running") text = accountSwitch ? t("compaction.runningAccountSwitch") : t("compaction.running");
  else if (state === "failed") text = error ? t("compaction.failedWithError", { error }) : t("compaction.failed");
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

/// The name of each acpmux permission policy a harness can fail to keep (approve-all always holds).
const POLICY_NAMES: Record<string, StringKey> = {
  ask: "policy.ask",
  "approve-reads": "policy.approveReads",
  "approve-edits": "policy.approveEdits",
  "deny-all": "policy.denyAll",
};

export function PolicyUnenforcedNote({ note }: { note: AcpmuxPolicyUnenforced }) {
  const t = useT();
  const name = POLICY_NAMES[note.policy];
  // A policy this pane does not know yet keeps acpmux's id.
  const values = { policy: name ? t(name) : note.policy };
  return (
    <div className="cv-tools">
      <div className="cv-tool cv-policy-unenforced">
        <span className="cv-tool__icon">
          <Lock />
        </span>
        <span className="cv-tool__text cv-policy-unenforced__text">
          {note.why === "ownSettings"
            ? t("policyUnenforced.ownSettings", values)
            : t("policyUnenforced.noAskingMode", values)}
        </span>
      </div>
    </div>
  );
}
