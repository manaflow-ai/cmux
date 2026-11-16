// Resume on a stopped helper, the one control every surface that draws its row or tab offers (Leo,
// 2026-11-12: "A Resume button in cmux on a stopped helper's row and tab. It starts a fresh session
// from that helper's record and original instructions, and carries on from there."): its end line in
// the transcript (SubagentDoneLine.tsx), the tray's finished lines (SubagentTray.tsx), the summary
// card's and Session Info's Subagents (summary/SubagentStatusList.tsx, summary/SubagentsTab.tsx,
// session-info/SubagentsSection.tsx; the native panel's button is session-info/native/subagents.ts),
// an open group's line (SubagentGroup.tsx `SubagentListRow`) and the helper's own pane, on its
// "Subagent of" line (SubagentGroup.tsx `SubagentOfRow`). A stopped acpmux sub-session offers it on
// the same rows, and on its card in the transcript (conversation/SubsessionCallCard.tsx), from its
// session row (resumeState.ts ``subsessionResumeRow``).
//
// The gate (resumeState.ts `canResume`), the call (`TurnActions.resumeAgent`) and what it leaves
// (``ResumeRun``: busy while acpmux has it, else a refusal's note) are the same everywhere: here.
import { useState, type ReactNode } from "react";
import { Retry } from "../conversation/icons";
import type { TurnActions } from "../conversation/turnActions";
import { useT } from "../i18n";
import type { RetryNote } from "./retryState";
import { canResume, resumeVersion, settledResume, shownResume, type ResumeRun } from "./resumeState";
import type { Subagent } from "./subagentFold";

/// What a surface needs for Resume: the chat's `resumeAgent` and the capabilities acpmux named. A
/// surface inside the transcript reads them from TurnActionsContext; one outside it takes them as
/// it takes its other actions (a prop, or the provider SubagentsTab.tsx sets).
export type ResumeActions = Pick<TurnActions, "resumeAgent" | "retryCapabilities">;

/// The Resume runs of a list's rows, by subagent id (a list draws each row with no state of its
/// own: Session Info's native rows). ``useResume`` is the one row's.
export function useResumeRuns(): {
  shown: (id: string, version: unknown) => ResumeRun | undefined;
  run: (agent: Subagent, version: unknown, resume: (agent: Subagent) => Promise<RetryNote | undefined>) => void;
} {
  const [runs, setRuns] = useState<ReadonlyMap<string, ResumeRun>>(() => new Map());
  const set = (id: string, next: ResumeRun) => setRuns((current) => new Map(current).set(id, next));
  const shown = (id: string, version: unknown) => shownResume(runs.get(id), version);
  return {
    shown,
    run: (agent, version, resume) => {
      if (shown(agent.id, version)?.busy) return;
      set(agent.id, { version, busy: true });
      void resume(agent).then(
        (key) => set(agent.id, settledResume(version, key)),
        () => set(agent.id, settledResume(version, "retry.failed")),
      );
    },
  };
}

/// One row's Resume: the button where acpmux can resume `agent`, and the note a refusal leaves.
/// `version` keys the note (a transcript row's version); unset, the agent's own (``resumeVersion``).
export function useResume(
  agent: Subagent | undefined,
  actions: ResumeActions | undefined,
  version?: unknown,
): { offered: boolean; busy: boolean; button?: ReactNode; note?: ReactNode } {
  const runs = useResumeRuns();
  const resume = actions?.resumeAgent;
  if (!agent || !resume || !canResume(agent, actions?.retryCapabilities)) {
    const note = agent && runs.shown(agent.id, version ?? resumeVersion(agent))?.key;
    return { offered: false, busy: false, ...(note && { note: <ResumeNote note={note} /> }) };
  }
  const key = version ?? resumeVersion(agent);
  const shown = runs.shown(agent.id, key);
  return {
    offered: true,
    busy: Boolean(shown?.busy),
    button: <ResumeButton busy={Boolean(shown?.busy)} onResume={() => runs.run(agent, key, resume)} />,
    ...(shown?.key && { note: <ResumeNote note={shown.key} /> }),
  };
}

function ResumeNote({ note }: { note: RetryNote }) {
  const t = useT();
  return <output className="cv-subagent-done__note cv-subagent-resume__note">{t(note)}</output>;
}

/// The button itself, as the end line drew it: the retry arrow, "Resume" and what it does.
export function ResumeButton({ busy, onResume }: { busy: boolean; onResume: () => void }) {
  const t = useT();
  const label = t("subagents.resume");
  return (
    <button
      type="button"
      className="cv-iconbtn cv-iconbtn--compact cv-subagent-restart cv-subagent-resume"
      aria-label={label}
      title={label}
      data-tooltip-detail={t("subagents.resumeDetail")}
      disabled={busy}
      onClick={onResume}
    >
      <Retry size={14} />
    </button>
  );
}

/// The note, then the button: a row's trailing Resume (the tray's, a list's, the pane's).
export function ResumeControl({ agent, actions }: { agent: Subagent; actions: ResumeActions | undefined }) {
  const { button, note } = useResume(agent, actions);
  if (!button && !note) return null;
  return (
    <span className="cv-subagent-resume-control">
      {note}
      {button}
    </span>
  );
}
