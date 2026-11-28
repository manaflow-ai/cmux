import { useEffect, useRef, useState, type ReactNode } from "react";
import { untilNotBusy, type RetryNote } from "./retryState";
import { canResume, resumeVersion, settledResume, shownResume, type ResumeRun } from "./resumeState";
import type { Subagent } from "./subagentFold";
import { ResumeButton, ResumeNote, type ResumeActions } from "./ResumeControl";

/// The Resume runs of a list's rows, by subagent id (a list draws each row with no state of its
/// own: Session Info's native rows). ``useResume`` is the one row's.
export function useResumeRuns(): {
  shown: (id: string, version: unknown) => ResumeRun | undefined;
  run: (agent: Subagent, version: unknown, resume: (agent: Subagent) => Promise<RetryNote | undefined>) => void;
} {
  const [runs, setRuns] = useState<ReadonlyMap<string, ResumeRun>>(() => new Map());
  const set = (id: string, next: ResumeRun) => setRuns((current) => new Map(current).set(id, next));
  // A Resume acpmux refuses `retry.busy` (one is already out, or a turn runs) stays busy and is asked
  // again on its own (retryState.ts ``untilNotBusy``), never a "try again shortly" to click; the
  // list going away stops every wait.
  const asking = useRef(new Map<string, () => void>());
  useEffect(
    () => () => {
      for (const stop of asking.current.values()) stop();
      asking.current.clear();
    },
    [],
  );
  const shown = (id: string, version: unknown) => shownResume(runs.get(id), version);
  return {
    shown,
    run: (agent, version, resume) => {
      if (shown(agent.id, version)?.busy) return;
      set(agent.id, { version, busy: true });
      asking.current.get(agent.id)?.();
      const asked = untilNotBusy(() => resume(agent));
      asking.current.set(agent.id, asked.stop);
      void asked.answer
        .finally(() => {
          if (asking.current.get(agent.id) === asked.stop) asking.current.delete(agent.id);
        })
        .then(
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
