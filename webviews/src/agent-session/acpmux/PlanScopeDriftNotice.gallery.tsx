// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import { PlanScopeDriftCard } from "./PlanScopeDriftNotice";

export default componentEntry<{ path: string }>({
  id: "agent-pane.plan-scope-drift-notice",
  title: "Plan scope drift notice",
  area: "Agent pane",
  pane: true,
  height: 120,
  widths: { narrow: 360, normal: 560, wide: 760 },
  covers: ["agent-session/acpmux/PlanScopeDriftNotice.tsx#PlanScopeDriftNotice"],
  load: async () =>
    function GalleryPlanScopeDrift(props: { path: string }) {
      return (
        <PlanScopeDriftCard
          drift={{
            sessionId: "gallery",
            path: props.path,
            area: props.path.split("/")[0] ?? props.path,
          }}
          onStop={() => undefined}
        />
      );
    },
  styles: () => import("../../ui/notice.css"),
  variants: {
    "short-path": {
      note: "The first drift is a compact file path with all three calm actions.",
      props: { path: "auth/session.rs" },
    },
    "nested-path": {
      note: "A nested source path wraps naturally without changing the notice's state.",
      props: { path: "Packages/macOS/CmuxNext/Sources/Agent/SessionScope.swift" },
    },
    "generated-path": {
      note: "Generated files use the same warning and action treatment.",
      props: { path: "webviews/src/agent-session/acpmux/generated/plan.ts" },
    },
  },
});
