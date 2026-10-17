// l10n-allow-file: orchestration fixture labels are a read-only gallery surface.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { OrchestrationLab } from "./OrchestrationLab";

const selectHugeBlue: Play = async (ctx) => {
  await ctx.click({ role: "radio", name: /Huge Blue lease/ });
  await ctx.waitFor(() => ctx.find({ role: "heading", name: "Huge Blue lease" }));
};

export default componentEntry<{ initialStrategy?: string }>({
  id: "agent-pane.orchestration-lab",
  title: "Orchestration lab",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 780,
  widths: { narrow: 520, normal: 860, wide: 1160 },
  anchors: [{ selector: "[data-orchestration-lab]" }],
  covers: ["agent-session/acpmux/OrchestrationLab.tsx#OrchestrationLab"],
  styles: () => import("./OrchestrationLab.gallery.css"),
  load: async () => OrchestrationLab,
  variants: {
    "local-queue": {
      note: "Fixture-only local route with an explicit trust boundary.",
      props: { initialStrategy: "local-queue" },
    },
    "huge-blue": {
      note: "Held route with cleanup evidence as the blocker.",
      props: { initialStrategy: "huge-blue" },
      play: selectHugeBlue,
    },
    "cloud-fair-share": {
      note: "Queued route with capacity unavailable.",
      props: { initialStrategy: "cloud-fair-share" },
    },
  },
});
