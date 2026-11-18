// l10n-allow-file: gallery fixture (sample workflow, phase and agent names), not shipped UI.
// A Claude workflow's card in the transcript (Labs `workflowLabs`, WorkflowCard.tsx), drawn from a
// workflow's events fed through the real subagent fold (workflowFixture.ts): its name, "Workflow ·
// N agents · time" and a dot per agent, live while it runs. A click opens Session Info's
// Background tasks (session-info/WorkflowTasks.tsx), whose gallery is agent-pane.chat-inspector.
import { componentEntry } from "../../../gallery/format";
import { GALLERY_NOW } from "../../../gallery/clock";
import { realWorkflowFixture } from "../realWorkflowFixture";
import { WorkflowCard, type WorkflowCardPresentation } from "./WorkflowCard";
import {
  configureUsageLimitHold,
  configureWorkflowCardOpen,
  configureWorkflowCardSideTab,
  type UsageLimitHold,
} from "./workflowCardModel";
import { workflowFixture, type WorkflowFixtureStage } from "./workflowFixture";

type Props = {
  stage: WorkflowFixtureStage;
  presentation: WorkflowCardPresentation;
  replay?: ReturnType<typeof realWorkflowFixture>;
  /// The chat waits at an account usage limit (workflowCardModel `usageLimitHold`).
  hold?: UsageLimitHold;
};

/// The reset the held variants continue after: 2h05m past the gallery's clock.
const RESET = GALLERY_NOW + 125 * 60_000;

/// The gallery's cards open nothing, but draw as the chat's do: a button.
configureWorkflowCardOpen(() => undefined);
configureWorkflowCardSideTab(() => undefined);

function GalleryWorkflowCard({ stage, presentation, replay, hold }: Props) {
  configureUsageLimitHold(hold);
  const nodes = (replay ?? workflowFixture(stage)).filter((node) => node.kind === "workflow");
  return (
    <div className="acpmux-shell" style={{ padding: "16px 20px" }}>
      {nodes.map((node) => (
        <WorkflowCard key={node.id} node={node} presentation={presentation} />
      ))}
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.workflow-card",
  title: "Workflow card",
  area: "Agent pane",
  pane: true,
  height: 180,
  widths: { narrow: 420, normal: 760 },
  covers: [
    "agent-session/acpmux/summary/WorkflowCard.tsx",
    "agent-session/acpmux/summary/workflowDots.css",
    "agent-session/acpmux/subagents/runningTray.ts",
  ],
  load: async () => GalleryWorkflowCard,
  variants: {
    "selected-running": {
      note: "Selected treatment: title and state, N/M progress, current phase with model and elapsed time, latest agent line, and known tokens. Before: dots only. After: the card explains what the workflow is doing without opening Session Info.",
      props: { stage: "running", presentation: "selected" },
    },
    "compact-running": {
      note: "Gallery alternative A: a single metadata line with a thin N/M progress bar. It keeps the card shortest while the selected treatment remains the shipped design.",
      props: { stage: "running", presentation: "compact" },
    },
    "phases-running": {
      note: "Gallery alternative B: the current phase remains in metadata and each phase gets a status strip. It makes the workflow topology visible at a glance; the selected treatment remains the shipped design.",
      props: { stage: "running", presentation: "phases" },
    },
    "selected-parallel": {
      note: "Two phases at once, 25 minutes in (Leo's 2026-11-05 screenshot): the card names both running phases, counts 2 done · 5 running rather than a 2/7 that reads as the total while Latency plan and Swarm synthesis have not spawned, shows one clock, says what the most recently active agent does in words (named, so five running agents never read as one) rather than its shell command, and names both running phases and the workflow's model on its last row.",
      props: { stage: "parallel", presentation: "selected" },
    },
    "selected-finished": {
      note: "Selected treatment after completion: 7/7, completed state, final elapsed time and total tokens remain visible; the progress bar is full and no done line repeats the card.",
      props: { stage: "finished", presentation: "selected" },
    },
    "held-at-limit": {
      note: "Labs: the chat's account hit its usage limit mid-run. The state reads 'Paused at usage limit, continues after' the reset time acpmux's retry waits for, the clock stops, and the bar and running phase lose their accent. It goes on by itself at that time (auto retry).",
      props: { stage: "parallel", presentation: "selected", hold: { nextAt: RESET } },
    },
    "held-no-time": {
      note: "Labs: held at a usage limit with no reset time known: 'Paused at usage limit'.",
      props: { stage: "running", presentation: "selected", hold: {} },
    },
    "held-compact": {
      note: "Gallery alternative A while held: the compact card's one line gives the pause first; the phase names give way.",
      props: { stage: "running", presentation: "compact", hold: { nextAt: RESET } },
    },
    "held-phases": {
      note: "Gallery alternative B while held: the phase strip keeps its done segments, the running one goes muted.",
      props: { stage: "running", presentation: "phases", hold: { nextAt: RESET } },
    },
    "held-finished": {
      note: "A workflow that already finished is never called paused, even while the chat waits at a limit.",
      props: { stage: "finished", presentation: "selected", hold: { nextAt: RESET } },
    },
    "real-run": {
      note: "Labs: a scrubbed card replayed from a real Claude Workflow stream. Completed, Report, 3/3 and 10s, with the recorded tokens and model.",
      props: { stage: "finished", presentation: "selected", replay: realWorkflowFixture(GALLERY_NOW) },
    },
    "real-running": {
      note: "Labs: the real Claude Workflow replay while it runs. Report is running at 8s with 2/3 agents complete.",
      props: { stage: "running", presentation: "selected", replay: realWorkflowFixture(GALLERY_NOW, 8_760) },
    },
  },
});
