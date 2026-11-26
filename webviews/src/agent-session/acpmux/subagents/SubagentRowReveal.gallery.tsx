// l10n-allow-file: gallery fixtures (subagent names and tasks), not shipped UI.
// A stopped or failed subagent's line with controls that show only under the pointer (Retry, Resume,
// ⋯), for Leo's row (2026-11-24, on "Agent terminated early due to an API e... ⟲ Retry 47m 39s >":
// "this is the same kind of problem. you're early ellipsis-ing because of a button that doesnt even
// always show"). The pick: the words run to the time at rest, and on hover the controls come in over
// their end as the words fade out under them, one motion (ui/motion/motion.css `.ui-reveal-text`).
// Compared with the line as it was (a column kept for the hidden Retry), a hard cut on a plate, and
// the controls over the time. Synthetic data.
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import type { Play } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";
import type { TurnActions } from "../conversation/turnActions";
import type { Subagent } from "./subagentFold";

type Design = "pick" | "before" | "hard-cut" | "over-time";
type Props = { lines: Subagent[]; design?: Design };

const API_ERROR = "Agent terminated early due to an API error. The request timed out after 600s.";
const agent = (name: string, task: string, fields: Partial<Subagent> = {}): Subagent => ({
  id: `agent-${name.toLowerCase().replaceAll(" ", "-")}`,
  parent: null,
  name,
  task,
  kind: "general-purpose",
  state: "failed",
  startedAt: minutesAgo(60),
  endedAt: minutesAgo(60 - 47.65),
  prompt: task,
  ...fields,
});

/// Leo's row: a failed run acpmux can retry, its reason long enough to reach the time.
const LEO = agent("Auth daemon", "Laptop daemon auth handoff", { retryable: true, error: API_ERROR });
const LINES = [
  LEO,
  agent("Folder sync", "Speed up Cloud folder sync", { retryable: true, error: "503: no accounts available" }),
  agent(
    "Reviewer",
    "Review the hover row sweep across every surface the transcript draws, the sidebar, Session Info and Settings included",
    {
      state: "cancelled",
      resumable: true,
    },
  ),
];

const hoverFirst: Play = async (ctx) => {
  await ctx.hover({ selector: ".cv-subagent-done-row" });
};

export default componentEntry<Props>({
  id: "agent-pane.subagent-row-reveal",
  title: "Subagent line: hover controls over the words",
  area: "Agent pane",
  pane: true,
  height: 180,
  widths: { narrow: 360, normal: 560, wide: 760 },
  covers: [
    "agent-session/acpmux/subagents/SubagentDoneLine.tsx",
    "agent-session/acpmux/subagents/subagents.css",
    "ui/revealCover.ts",
    "ui/motion/motion.css",
  ],
  load: async () => {
    const { SubagentDoneLine } = await import("./SubagentDoneLine");
    const { TurnActionsContext } = await import("../conversation/turnActions");
    const { SUBAGENT_DONE } = await import("./subagentRows");
    // No capabilities named: Resume is offered wherever the row allows it (resumeState.ts `canResume`).
    const actions: TurnActions = { retryAgent: async () => undefined, resumeAgent: async () => undefined };
    return function GallerySubagentRowReveal({ lines, design = "pick" }: Props) {
      const rows: AcpmuxRow[] = lines.map((line, index) => ({
        id: `done-${index}`,
        version: 1,
        kind: SUBAGENT_DONE,
        at: line.endedAt ?? Date.now(),
        subagents: [line],
      }));
      return (
        <div
          className="acpmux-shell"
          data-reveal-design={design}
          style={{ padding: "16px", flexDirection: "column", gap: "4px" }}
        >
          <TurnActionsContext.Provider value={actions}>
            {rows.map((row) => (
              <div key={row.id}>
                <SubagentDoneLine row={row} />
              </div>
            ))}
          </TurnActionsContext.Provider>
        </div>
      );
    };
  },
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("../conversation/TranscriptActivityRow.css"),
      import("./subagents.css"),
      import("../../../ui/motion/motion.css"),
      import("./SubagentRowReveal.gallery.css"),
    ]),
  variants: {
    pick: {
      note: 'The pick, at rest: the words run to the time; no room is kept for Retry, Resume or ⋯, which show only under the pointer (Leo, 2026-11-24: "you\'re early ellipsis-ing because of a button that doesnt even always show").',
      props: { lines: LINES },
    },
    "pick-hover": {
      note: "The pick under the pointer: Retry comes in over the words' end as they fade out under it, on the hover-reveal tokens, one motion; the time and chevron stay.",
      props: { lines: LINES },
      play: hoverFirst,
    },
    before: {
      note: 'Before: a column kept at rest for the hidden Retry, so Leo\'s line cut at "API e..." next to empty space.',
      props: { lines: LINES, design: "before" },
    },
    "before-hover": {
      note: "Before, under the pointer: Retry fills the kept column.",
      props: { lines: LINES, design: "before" },
      play: hoverFirst,
    },
    "hard-cut": {
      note: "Version B: the controls lie over the words on a plate, the words ending in an ellipsis at rest and cut hard on hover. Full width at rest, but the cut jumps instead of fading.",
      props: { lines: LINES, design: "hard-cut" },
      play: hoverFirst,
    },
    "over-time": {
      note: "Version C: the controls take the time's place on hover. The words never move, but the time disappears exactly when the person points at the row.",
      props: { lines: LINES, design: "over-time" },
      play: hoverFirst,
    },
  },
});
