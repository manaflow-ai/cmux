// l10n-allow-file: synthetic Chief work fixtures, not shipped copy.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { ChiefWorkPanel, type ChiefWorkPanelProps } from "./ChiefWorkPanel";
import type { HomeChiefWork } from "./chiefWorkTypes";

type Props = Pick<ChiefWorkPanelProps, "snapshot" | "loading" | "stillTrying">;
function WorkGallery(props: Props) {
  const [strings] = useState(() => createStrings(table));
  return (
    <div style={{ container: "lg-page / inline-size", height: "100%", width: "100%" }}>
      <div className="lg-main" style={{ height: "100%" }}>
        <div className="lg-stage">
          <ChiefWorkPanel {...props} strings={strings} onRefresh={() => undefined} onClose={() => undefined} />
        </div>
      </div>
    </div>
  );
}
const active: HomeChiefWork = {
  agents: [
    {
      id: "agent-design",
      name: "Design the hello page",
      state: "working",
      task: "Building a friendly landing page with a shareable preview.",
      startedAt: 1,
    },
    {
      id: "agent-verify",
      name: "Check the preview",
      state: "waiting",
      task: "Waiting for the preview to become available.",
      startedAt: 2,
    },
    { id: "agent-research", name: "Find the right template", state: "idle", startedAt: 0 },
  ],
  tasks: [
    {
      id: "build",
      sessionId: "agent-design",
      title: "Build the hello page",
      status: "running",
      command: "bun run build",
      startedAt: 1,
    },
    {
      id: "preview",
      sessionId: "agent-design",
      title: "Start the preview",
      status: "running",
      command: "bun run dev --host 0.0.0.0",
      startedAt: 2,
    },
    {
      id: "lint",
      sessionId: "agent-design",
      title: "Check the page",
      status: "done",
      command: "bun run check",
      endedAt: 3,
    },
  ],
  taskSources: ["harness"],
  truncated: false,
};
// The plans arms (chiefPlans.experiment.ts): the Chief's own plan and each subagent's.
const planned: HomeChiefWork = {
  ...active,
  plans: [
    {
      id: "chief-turn",
      name: "Ship the hello page",
      state: "working",
      plan: { source: "chief", done: 2, total: 5, current: "Check the preview on a phone", next: "Share the link" },
    },
  ],
  agents: [
    {
      ...active.agents[0]!,
      plan: { source: "harness", done: 3, total: 7, current: "Write the hero section", next: "Add the share preview" },
    },
    {
      ...active.agents[1]!,
      plan: { source: "agent", done: 1, total: 3, current: "Wait for the preview URL", next: "Open it on a phone" },
    },
    { ...active.agents[2]!, plan: { source: "harness", done: 4, total: 4 } },
  ],
};
export default componentEntry<Props>({
  id: "pages.home-chief-work",
  title: "Chief background work",
  area: "Home and Chief",
  height: 844,
  widths: { narrow: 390, normal: 768, wide: 1280 },
  covers: ["pages/home-channels/ChiefWorkPanel.tsx"],
  load: async () => WorkGallery,
  styles: () => Promise.all([import("./styles.css"), import("./ledger.css")]),
  variants: {
    active: {
      note: "Selected: quiet grouped rows, actual states, one manual refresh.",
      props: { snapshot: active, loading: false },
    },
    phone: {
      note: "Full-width sheet on a 390px phone.",
      props: { snapshot: active, loading: false },
    },
    "plans-inline": {
      note: "Plans, inline arm: count and the step in progress under each subagent.",
      props: { snapshot: planned, loading: false },
      experiments: { "chief-plans": "inline" },
    },
    "plans-steps": {
      note: "Plans, steps arm: a progress bar, the step in progress and the next one.",
      props: { snapshot: planned, loading: false },
      experiments: { "chief-plans": "steps" },
    },
    "plans-section": {
      note: "Plans, plans-first arm: the Chief's plan and each subagent's in one section on top.",
      props: { snapshot: planned, loading: false },
      experiments: { "chief-plans": "section" },
    },
    "plans-off": {
      note: "Plans off (the default): the same snapshot as before plans.",
      props: { snapshot: planned, loading: false },
      experiments: { "chief-plans": "off" },
    },
    empty: { props: { snapshot: { agents: [], tasks: [], truncated: false }, loading: false } },
    loading: { props: { loading: true } },
    // A read that kept failing past the deadline: one quiet line, no button (it is asked again on its own).
    "still-loading": { props: { loading: false, stillTrying: true } },
    refreshing: { props: { snapshot: active, loading: true } },
    partial: { props: { snapshot: { ...active, truncated: true }, loading: false } },
    failed: {
      props: {
        snapshot: {
          agents: [
            {
              id: "a",
              name: "Check the hello page",
              state: "failed",
              task: "The preview could not be reached.",
            },
          ],
          tasks: [
            {
              id: "b",
              sessionId: "a",
              title: "Verify the preview",
              status: "failed",
              detail: "Connection refused. The preview server may have stopped.",
            },
            { id: "c", sessionId: "a", title: "Preview process", status: "unknown" },
          ],
          truncated: false,
        },
        loading: false,
      },
    },
  },
});
