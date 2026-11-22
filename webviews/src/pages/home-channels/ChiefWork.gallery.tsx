// l10n-allow-file: synthetic Chief work fixtures, not shipped copy.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { ChiefWorkPanel, type ChiefWorkPanelProps } from "./ChiefWorkPanel";
import type { HomeChiefWork } from "./chiefWorkTypes";

type Props = Pick<ChiefWorkPanelProps, "snapshot" | "loading" | "error">;
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
    empty: { props: { snapshot: { agents: [], tasks: [], truncated: false }, loading: false } },
    loading: { props: { loading: true } },
    error: { props: { loading: false, error: "chief.work_unavailable" } },
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
