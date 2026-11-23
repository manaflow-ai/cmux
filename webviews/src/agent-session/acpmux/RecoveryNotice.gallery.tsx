// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { RecoveryStatus } from "./recoveryStatus";

type Props = { state: RecoveryStatus | undefined; armable?: boolean };

const RESET = Date.UTC(2026, 10, 22, 15, 30);

export default componentEntry<Props>({
  id: "agent-pane.recovery",
  title: "Turn recovery: resume at reset, restart outcome",
  area: "Agent pane",
  pane: true,
  height: 120,
  widths: { narrow: 320, normal: 720, wide: 900 },
  covers: ["agent-session/acpmux/RecoveryNotice.tsx"],
  load: async () => {
    const { RecoveryNotice } = await import("./RecoveryNotice");
    return function GalleryRecovery({ state, armable = true }: Props) {
      return (
        <div className="acpmux-shell">
          <RecoveryNotice state={state} onResumeAtReset={armable ? async () => {} : undefined} />
        </div>
      );
    };
  },
  styles: () => import("./styles.css"),
  variants: {
    offered: { props: { state: { resumeAtReset: { state: "offered", turnId: "t", resetsAt: RESET } } } },
    armed: { props: { state: { resumeAtReset: { state: "armed", turnId: "t", resetsAt: RESET } } } },
    "unknown-reset": { props: { state: { resumeAtReset: { state: "unknown_reset", turnId: "t" } } } },
    "restart-queued": {
      props: {
        state: {
          restartOutcome: { state: "resumed", nextAction: "none", continuationPromptId: "p", delivery: "queued" },
        },
      },
    },
    "restart-review": {
      props: {
        state: {
          restartOutcome: {
            state: "waiting_for_user",
            nextAction: "review_then_send",
            why: "trigger",
            unfinishedTools: ["Bash", "Edit"],
          },
        },
      },
    },
    "restart-unable": {
      props: {
        state: { restartOutcome: { state: "unable_to_resume", nextAction: "retry", why: "attempts_exhausted" } },
      },
    },
  },
});
