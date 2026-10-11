// l10n-allow-file: gallery fixtures exercise picker states and labels, not shipped copy.
import { useMemo, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { AcpmuxSnapshot } from "./model";
import { ComposerPickers } from "./ComposerPickers";

type Props = Record<string, never>;

const initialSnapshot: AcpmuxSnapshot = {
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions: [],
  connection: "gallery",
  isWorking: false,
  queue: [],
  canLoadOlder: false,
  catalog: [
    {
      id: "codex",
      name: "Codex",
      models: [
        {
          id: "gpt-6.1-sol",
          name: "GPT-6.1 Sol",
          efforts: ["low", "medium", "high"],
          defaultEffort: "medium",
          fast: true,
          contextWindow: 200_000,
        },
        { id: "gpt-6-astra", name: "GPT-6 Astra", efforts: ["low", "high"] },
      ],
    },
    {
      id: "claude",
      name: "Claude Code",
      models: [{ id: "claude-sonnet-5-5", name: "Sonnet 5.5", efforts: ["medium", "high"] }],
    },
  ],
  summary: {
    sessionId: "gallery-composer",
    harness: "codex",
    model: "gpt-6.1-sol",
    turnCount: 1,
    usage: { used: 48_000, size: 200_000 },
    modes: {
      availableModes: [
        { id: "default", name: "Default", description: "Ask before sensitive actions." },
        { id: "full-access", name: "Full access", description: "Run actions without asking." },
        { id: "plan", name: "Plan", description: "Read and propose without editing." },
      ],
      currentModeId: "default",
    },
    configOptions: [
      {
        id: "effort",
        name: "Effort",
        category: "thought_level",
        currentValue: "medium",
        options: [
          { value: "low", name: "Low" },
          { value: "medium", name: "Medium" },
          { value: "high", name: "High" },
        ],
      },
      {
        id: "fast-mode",
        name: "Fast mode",
        currentValue: "off",
        options: [
          { value: "off", name: "Off" },
          { value: "on", name: "On" },
        ],
      },
    ],
  },
};

function GalleryComposerPickers() {
  const [model, setModel] = useState(initialSnapshot.summary!.model!);
  const [mode, setMode] = useState(initialSnapshot.summary!.modes!.currentModeId!);
  const [effort, setEffort] = useState("medium");
  const [fast, setFast] = useState("off");
  const snapshot = useMemo<AcpmuxSnapshot>(
    () => ({
      ...initialSnapshot,
      summary: {
        ...initialSnapshot.summary!,
        model,
        modes: { ...initialSnapshot.summary!.modes!, currentModeId: mode },
        configOptions: initialSnapshot.summary!.configOptions!.map((option) => ({
          ...option,
          currentValue: option.id === "effort" ? effort : option.id === "fast-mode" ? fast : option.currentValue,
        })),
      },
    }),
    [effort, fast, mode, model],
  );
  return (
    <div className="acpmux-composer-gallery-shell">
      <div className="acpmux-composer-gallery-copy">
        <strong>Composer controls</strong>
        <span>Model, context, effort, permission, and Plan controls share one quiet footer rail.</span>
      </div>
      <ComposerPickers
        snapshot={snapshot}
        onModel={setModel}
        onMode={setMode}
        onEffort={(id, value) => (id === "fast-mode" ? setFast(value) : setEffort(value))}
        onShowContextUsage={() => undefined}
        showPlan
      />
    </div>
  );
}

const openModel: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Model" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="dialog"] [type="search"]') !== null);
};

const openEffort: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Effort" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menuitemradio"][aria-checked="true"]') !== null);
};

const openMode: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Mode" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menuitemradio"][aria-checked="true"]') !== null);
};

const openContext: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-context-ring" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-context-pop") !== null);
};

const planToggle: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Build" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Plan" }).getAttribute("aria-pressed") === "true");
};

export default componentEntry<Props>({
  id: "agent-pane.composer-pickers",
  title: "Composer picker rail",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 420, normal: 640, wide: 860 },
  anchors: [{ selector: ".acpmux-chips" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Opening a picker must leave the composer rail in place." },
    layoutShiftMax: { value: 0, reason: "Picker surfaces are portaled and must not add flow to the composer." },
    longFrameFailMs: { value: 33, reason: "Composer picker actions should remain responsive on the gallery host." },
    settleMaxMs: { value: 250, reason: "Local picker opens and toggles should settle within a quarter second." },
  },
  covers: ["agent-session/acpmux/ComposerPickers.tsx#ComposerPickers"],
  load: async () => GalleryComposerPickers,
  styles: () =>
    Promise.all([
      import("./styles.css"),
      import("./composerControls.css"),
      import("./modelPicker.css"),
      import("./ComposerPickers.gallery.css"),
    ]),
  variants: {
    closed: { props: {} },
    "model-menu": { props: {}, play: openModel },
    "effort-menu": { props: {}, play: openEffort },
    "permission-menu": { props: {}, play: openMode },
    "context-details": { props: {}, play: openContext },
    plan: { props: {}, play: planToggle },
  },
});
