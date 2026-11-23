// l10n-allow-file: gallery descriptions and sample daemon snapshots.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { EarnedAccessPreview } from "./EarnedAccessPreview";
import { earnedAccessPreview } from "./earnedAccess.experiment";
import type { Enforcement } from "../handoff/protocol";
import "./sessionInfo.css";

const expand: Play = async (ctx) => {
  await ctx.click({ selector: "[data-earned-access-preview] button" });
  await ctx.waitFor(() => ctx.document.querySelector('[aria-expanded="true"]'));
};
const noPreview: Play = async (ctx) => {
  if (ctx.document.querySelector("[data-earned-access-preview]")) throw new Error("Preview must be hidden");
};
function Preview({ enforcement }: { enforcement?: Enforcement }) {
  return (
    <ul className="acpmux-session-info-list">
      <EarnedAccessPreview enforcement={enforcement} />
    </ul>
  );
}
const report = (policy: string, current: string): Enforcement => ({
  policy,
  label: "native_policy",
  isolation: "unverified",
  detail: null,
  accessPreview: { current, eligibility: "unavailable" },
});

export default componentEntry({
  id: "sidebar.earned-access",
  title: "Earned access preview",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/session-info/EarnedAccessPreview.tsx#EarnedAccessPreview"],
  load: async () => Preview,
  experiment: {
    definition: earnedAccessPreview,
    script: [
      {
        name: "Open access details",
        run: async (ctx) => {
          if (ctx.document.querySelector("[data-earned-access-preview]")) await expand(ctx);
        },
      },
    ],
  },
  variants: {
    full: {
      note: "Full is current, never earned",
      props: { enforcement: report("approve-all", "full") },
    },
    reads: { note: "Reads", props: { enforcement: report("approve-reads", "reads") } },
    review: { note: "Read-only", props: { enforcement: report("review", "readOnly") } },
    ask: { note: "Ask is not a rung", props: { enforcement: report("ask", "ask") } },
    legacy: { note: "Old daemon", props: {}, play: noPreview },
  },
});
