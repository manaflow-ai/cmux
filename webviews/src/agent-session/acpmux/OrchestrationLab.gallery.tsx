// l10n-allow-file: gallery fixture labels are a read-only visual work surface.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";

const selectHugeBlue: Play = async (ctx) => {
  await ctx.click({
    role: "button",
    name: /Verify Linux cleanup/,
  });
  await ctx.waitFor(() => ctx.find({ role: "heading", name: "Verify Linux cleanup" }));
};

const selectDecision: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /Run gallery checks/ });
  await ctx.waitFor(() => ctx.find({ role: "heading", name: "Move gallery checks to the cloud worker?" }));
};

const jumpToDecision: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Review decision (1)" });
  await ctx.waitFor(() => ctx.find({ role: "heading", name: "Run gallery checks" }));
};

const openInspector: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Inspect technical receipt" });
  await ctx.waitFor(() => ctx.find({ role: "dialog", name: /technical receipt/ }));
};

export default componentEntry<{
  initialStrategy?: string;
  initialInspectorOpen?: boolean;
}>({
  id: "agent-pane.orchestration-lab",
  title: "Orchestration lab",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 780,
  widths: { narrow: 520, normal: 860, wide: 1160 },
  anchors: [{ selector: ".orchestration-gallery-header" }, { selector: ".orchestration-work-list" }],
  covers: ["agent-session/acpmux/OrchestrationLab.tsx#OrchestrationLab"],
  styles: () => import("./OrchestrationLab.gallery.css"),
  load: async () => {
    const { OrchestrationLab } = await import("./OrchestrationLab");
    return OrchestrationLab;
  },
  variants: {
    "local-queue": {
      note: "Sample work view with running, blocked, and decision-needed sessions.",
      props: { initialStrategy: "local-queue" },
    },
    "huge-blue": {
      note: "Blocked work keeps the evidence gap and no-action explanation visible.",
      props: { initialStrategy: "huge-blue" },
      play: selectHugeBlue,
    },
    "cloud-fair-share": {
      note: "Decision-needed work exposes preview-only Use cloud and Keep local choices.",
      props: { initialStrategy: "cloud-fair-share" },
      play: selectDecision,
    },
    "jump-to-decision": {
      note: "The summary action selects the first pending decision without exposing receipt details.",
      props: { initialStrategy: "local-queue" },
      checks: {
        layoutShiftMax: {
          value: 0.05,
          reason:
            "Selecting work inserts its in-flow decision panel; the overview and work list remain anchored while the detail reflows.",
        },
      },
      play: jumpToDecision,
    },
    inspector: {
      note: "Technical receipt is behind the per-work inspector and closed by default on the main view.",
      props: { initialStrategy: "local-queue" },
      play: openInspector,
    },
  },
});
