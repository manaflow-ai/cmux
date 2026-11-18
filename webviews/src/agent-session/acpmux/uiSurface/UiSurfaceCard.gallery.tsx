// l10n-allow-file: gallery fixtures (sample agent surfaces), not shipped UI.
// Agent UI surfaces (`cmux.ui-surface/1`, Labs `labs.agentUiSurfaces`): what an agent's A2UI view or
// MCP App draws as in the chat. Approval in three looks (compact row, full card with facts,
// high-risk destructive), review in three (radio list, chip grid, ranked list with details), the
// travel quickstart's two fallback-heavy samples, and the states: streaming, pending confirm,
// confirmed, error, table, chart, progress. `beside-permission` puts a tool permission ask over an
// approval card, to check they read as one family. The gallery's client answers each action with a
// host-like Pending after a short wait, so a press shows the confirm strip as acpmux would.
// Golden surfaces from cmux-tui/crates/cmux-ui-surfaces/tests/golden/*.json show as `golden-*`
// variants once Rust writes them and they are listed in GOLDEN below.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { PermissionPanel } from "../permissions/Panel";
import type { PermissionClientState } from "../permissions/protocol";
import type { UiSurfaceClient } from "./actions";
import {
  approvalCompact,
  approvalDanger,
  approvalFull,
  chartSurface,
  errorSurface,
  kitchenSink,
  pendingFor,
  progressSurface,
  refineSearch,
  reviewChips,
  reviewList,
  reviewRanked,
  streamingSurface,
  tableSurface,
  travelerForm,
} from "./fixtures";
import { readUiSurface, type UiSurface } from "./model";
import { UiSurfaceCard } from "./UiSurfaceCard";

const galleryClient: UiSurfaceClient = {
  uiSurfaceAction: ({ actionId, values }) =>
    new Promise((resolve) => setTimeout(() => resolve(pendingFor(actionId, values)), 120)),
  uiSurfaceConfirm: () => new Promise((resolve) => setTimeout(() => resolve({ sent: "agent" }), 120)),
  uiSurfaceCancel: async () => ({ ok: true }),
  uiSurfaceBridge: async () => ({}),
  openLink: () => undefined,
  draft: () => undefined,
};

const permissionState: PermissionClientState = {
  supported: true,
  ready: true,
  chatAllowance: false,
  loading: false,
  busy: false,
  groups: [
    {
      groupId: "group-gallery-ui",
      sessionId: "session-gallery",
      turnId: "turn-gallery-1",
      revision: 1,
      state: "pending",
      decisions: ["allow_once", "allow_chat", "deny"],
      decision: null,
      items: [
        {
          permissionId: "permission-gallery-ui",
          state: "pending",
          request: {
            toolCall: {
              title: "Run the deploy",
              kind: "execute",
              rawInput: { command: "bun run deploy --env staging", cwd: "/Users/you/src/app" },
            },
          },
        },
      ],
    },
  ],
};

type Props = { surfaces: UiSurface[]; permission?: boolean };

function Stage({ surfaces, permission }: Props) {
  return (
    <div
      className="acpmux-shell"
      data-ui-surface-fixture
      style={{ padding: 16, display: "grid", gap: 12, alignContent: "start" }}
    >
      {permission && (
        <PermissionPanel
          state={permissionState}
          working
          onRespond={() => {}}
          onRetry={() => {}}
          onRevoke={() => {}}
          onRefresh={() => {}}
        />
      )}
      {surfaces.map((surface) => (
        <UiSurfaceCard key={surface.surfaceId} surface={surface} client={galleryClient} />
      ))}
    </div>
  );
}

/// Presses `name` on the first card, then waits for the confirm strip.
const pressThenStrip =
  (name: string): Play =>
  async (ctx) => {
    await ctx.click({ role: "button", name });
    await ctx.waitFor(() => ctx.document.querySelector(".uis-confirm"));
  };

const confirmed =
  (name: string): Play =>
  async (ctx) => {
    await pressThenStrip(name)(ctx);
    await ctx.click({ selector: "[data-uis-confirm]" });
    await ctx.waitFor(() => ctx.document.querySelector(".uis-answer"));
  };

const pickThenSubmit =
  (labels: string[], confirm: boolean): Play =>
  async (ctx) => {
    for (const label of labels) await ctx.click({ role: "radio", name: label });
    await pressThenStrip("Submit")(ctx);
    if (!confirm) return;
    await ctx.click({ selector: "[data-uis-confirm]" });
    await ctx.waitFor(() => ctx.document.querySelector(".uis-answer"));
  };

const typeTraveler: Play = async (ctx) => {
  await ctx.type("Ada Lovelace", { selector: "input[type='text']" });
  await ctx.click({ role: "radio", name: "Window" });
  await pressThenStrip("Save traveller")(ctx);
};

// Golden surfaces Rust writes (see the header): each listed module's default export, read as a
// surface. Empty until that lane lands; `scripts/gallery/entries.ts` loads entries without Vite, so
// this is a static list, not an import.meta.glob.
const GOLDEN: Record<string, unknown> = {};
const golden = Object.fromEntries(
  Object.entries(GOLDEN).flatMap(([name, value]) => {
    const surface = readUiSurface(value);
    return surface ? [[`golden-${name}`, { note: `Rust golden ${name}.json`, props: { surfaces: [surface] } }]] : [];
  }),
);

export default componentEntry<Props>({
  id: "agent-pane.ui-surface",
  title: "Agent UI surface cards",
  area: "Agent pane",
  experimental: true,
  pane: true,
  covers: [
    "agent-session/acpmux/uiSurface/UiSurfaceCard.tsx#UiSurfaceCard",
    "agent-session/acpmux/uiSurface/nodes.tsx",
    // The tool row draws the same card per surface, behind Labs (agentUiSurfaces.ts).
    "agent-session/acpmux/uiSurface/ToolUiSurfaces.tsx#ToolUiSurfaces",
  ],
  load: async () => Stage,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../composerStates.css"),
      import("../composerLocation.css"),
      import("../conversation/conversation.css"),
    ]),
  widths: { narrow: 380, normal: 560, wide: 760 },
  height: 560,
  anchors: [{ selector: "[data-ui-surface-fixture]" }],
  checks: {
    layoutShiftMax: {
      value: 0.05,
      reason: "A press adds the confirm strip under the card; the card above it does not move.",
    },
  },
  variants: {
    "approval-compact": {
      note: "Approval, compact: one row like a permission ask, Deny and Approve at its end (no facts, low risk).",
      props: { surfaces: [approvalCompact] },
    },
    "approval-full": {
      note: "Approval, full: title, detail, a facts table, the answers at the foot.",
      props: { surfaces: [approvalFull] },
    },
    "approval-danger": {
      note: "Approval, high risk: warning mark, High risk tag, a red Approve; the server is not one the person connected (claimed).",
      props: { surfaces: [approvalDanger] },
    },
    "beside-permission": {
      note: "A tool permission ask (permissions/Panel.tsx) over the compact and full approval cards: one family.",
      props: { surfaces: [approvalCompact, approvalFull], permission: true },
    },
    "review-list": {
      note: "Review, radio list: one pick, each option's detail under its label.",
      props: { surfaces: [reviewList] },
    },
    "review-chips": {
      note: "Review, chip grid: short labels, several picks.",
      props: { surfaces: [reviewChips] },
    },
    "review-ranked": {
      note: "Review, ranked: five or more options with details, numbered in the agent's order, several picks.",
      props: { surfaces: [reviewRanked] },
    },
    streaming: {
      note: "Streaming: Drawing… in the head, controls locked until the surface is ready; the card's height only grows.",
      props: { surfaces: [streamingSurface] },
    },
    "pending-confirm": {
      note: "Approve pressed: the host's summary of what Confirm sends, Cancel ⎋ and Confirm ↩.",
      props: { surfaces: [approvalFull] },
      play: pressThenStrip("Approve"),
    },
    "pending-danger": {
      note: "High-risk Approve pressed: the strip is the only way the action goes.",
      props: { surfaces: [approvalDanger] },
      play: pressThenStrip("Approve"),
    },
    "pending-form": {
      note: "The traveller form filled and Save pressed: the summary lists every value sent.",
      props: { surfaces: [travelerForm] },
      play: typeTraveler,
    },
    "review-pending": {
      note: "A review pick sent for confirmation.",
      props: { surfaces: [reviewList] },
      play: pickThenSubmit(["Queue and retry with backoff"], false),
    },
    confirmed: {
      note: "Approval confirmed: the answers give way to Approved.",
      props: { surfaces: [approvalFull] },
      play: confirmed("Approve"),
    },
    "review-answered": {
      note: "Review confirmed: options locked, Sent at the foot.",
      props: { surfaces: [reviewChips] },
      play: async (ctx) => {
        await ctx.click({ role: "checkbox", name: "Tokyo" });
        await ctx.click({ role: "checkbox", name: "Kyoto" });
        await pressThenStrip("Submit")(ctx);
        await ctx.click({ selector: "[data-uis-confirm]" });
        await ctx.waitFor(() => ctx.document.querySelector(".uis-answer"));
      },
    },
    error: {
      note: "Error: what fit, then acpmux's reason.",
      props: { surfaces: [errorSurface] },
    },
    "travel-traveler-form": {
      note: "The travel quickstart's 70-traveler-form: basic fields, choice chips, Save.",
      props: { surfaces: [travelerForm] },
    },
    "travel-refine-search": {
      note: "The travel quickstart's 30-refine-search: its DateRangePicker and TravelerCounter draw as fallbacks.",
      props: { surfaces: [refineSearch] },
    },
    table: {
      note: "A table node (the reply's table block); the HTML in the caption reads as text.",
      props: { surfaces: [tableSurface] },
    },
    chart: {
      note: "A chart node, drawn by the chat's chart fence path and palette.",
      props: { surfaces: [chartSurface] },
    },
    progress: { note: "Progress: done, determinate, indeterminate, failed.", props: { surfaces: [progressSurface] } },
    "every-node": { note: "Every remaining node type in one card.", props: { surfaces: [kitchenSink] } },
    ...golden,
  },
});
