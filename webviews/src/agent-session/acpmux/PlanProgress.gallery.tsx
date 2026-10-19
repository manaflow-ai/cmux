// l10n-allow-file: gallery fixtures, not shipped UI.
import { useLayoutEffect } from "react";
import { componentEntry } from "../../gallery/format";
import type { AcpmuxRow } from "./model";

type Props = { enabled: boolean; working: boolean; rows: AcpmuxRow[] };
const rows: AcpmuxRow[] = [
  {
    id: "plan",
    kind: "plan",
    version: 1,
    at: 1,
    plan: [
      { content: "Read the uploader", status: "completed" },
      { content: "Add retry", status: "completed" },
      { content: "Cover timeouts", status: "completed" },
      {
        content: "Check retries against a slow connection and keep the existing upload behavior",
        status: "in_progress",
      },
      { content: "Update docs", status: "pending" },
      { content: "Run checks", status: "pending" },
      { content: "Review the diff", status: "pending" },
    ],
  },
];

export default componentEntry<Props>({
  id: "agent-pane.plan-progress",
  title: "Pinned plan progress",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 140,
  widths: { narrow: 320, normal: 560, wide: 860 },
  covers: ["agent-session/acpmux/PlanProgress.tsx#PlanProgress"],
  load: async () => {
    const { PlanProgress } = await import("./PlanProgress");
    const { configureLabs } = await import("./labs");
    return function PlanProgressGallery(props: Props) {
      useLayoutEffect(() => {
        configureLabs({ labs: { planProgress: props.enabled } });
        return () => configureLabs(undefined);
      }, [props.enabled]);
      return <PlanProgress {...props} onReveal={() => undefined} />;
    };
  },
  variants: {
    running: { props: { enabled: true, working: true, rows } },
    ended: { props: { enabled: true, working: false, rows } },
    "no-plan": { props: { enabled: true, working: true, rows: [] } },
    "lab-off": { props: { enabled: false, working: true, rows } },
  },
});
