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
import { Retry } from "../conversation/icons";
import type { TurnActions } from "../conversation/turnActions";
import { useT } from "../i18n";
import type { RetryNote } from "./retryState";
import type { Subagent } from "./subagentFold";
import { Described } from "../chips/FactsHoverCard";
import { useResume } from "./useResume";

/// What a surface needs for Resume: the chat's `resumeAgent` and the capabilities acpmux named. A
/// surface inside the transcript reads them from TurnActionsContext; one outside it takes them as
/// it takes its other actions (a prop, or the provider SubagentsTab.tsx sets).
export type ResumeActions = Pick<TurnActions, "resumeAgent" | "retryCapabilities">;

export function ResumeNote({ note }: { note: RetryNote }) {
  const t = useT();
  return <output className="cv-subagent-done__note cv-subagent-resume__note">{t(note)}</output>;
}

/// The button itself, as the end line drew it: the retry arrow, "Resume" and what it does.
export function ResumeButton({ busy, onResume }: { busy: boolean; onResume: () => void }) {
  const t = useT();
  const label = t("subagents.resume");
  return (
    <Described text={t("subagents.resumeDetail")}>
      {(described) => (
        <button
          {...described}
          type="button"
          className="cv-iconbtn cv-iconbtn--compact cv-subagent-restart cv-subagent-resume"
          aria-label={label}
          title={label}
          disabled={busy}
          onClick={onResume}
        >
          <Retry size={14} />
        </button>
      )}
    </Described>
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
