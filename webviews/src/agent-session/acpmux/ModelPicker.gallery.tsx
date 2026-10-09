// l10n-allow-file: gallery fixtures (sample models), not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { ModelPickerProps } from "./modelPickerLayout";

const catalog: ModelPickerProps["catalog"] = [
  {
    id: "claude",
    name: "Claude Code",
    models: [
      { id: "claude-opus-5-5", name: "Opus 5.5" },
      { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
      { id: "claude-haiku-4-5", name: "Haiku 4.5" },
      { id: "claude-opus-4-1", name: "Opus 4.1" },
      { id: "claude-opus-4", name: "Opus 4" },
      { id: "claude-sonnet-4", name: "Sonnet 4" },
      { id: "claude-sonnet-3-7", name: "Sonnet 3.7" },
      { id: "claude-haiku-3-5", name: "Haiku 3.5" },
    ],
  },
  {
    id: "codex",
    name: "Codex",
    models: [
      { id: "gpt-6.1-sol", name: "GPT-6.1-Sol" },
      { id: "gpt-6-astra", name: "GPT-6-Astra" },
      { id: "gpt-6-luna", name: "GPT-6-Luna" },
      { id: "daybreak-blue", name: "Daybreak Blue" },
    ],
  },
  { id: "terminal", name: "Terminal", pickable: false, models: [{ id: "shell", name: "Shell" }] },
];

// Each variant starts with nothing starred; the picker reads stars once, when it mounts.
try {
  globalThis.localStorage?.removeItem("cmux.model-picker.favorites");
} catch {}

const openPicker = async (ctx: Parameters<NonNullable<Play>>[0]) => {
  await ctx.click({ role: "button", name: "Model" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-mp-models"));
};

const refresh = (
  status: "idle" | "fetching" | "updated" | "error",
  date?: string,
): ModelPickerProps["catalogRefresh"] => ({
  status,
  date,
  refresh: () => undefined,
});

const base: ModelPickerProps = {
  catalog,
  harness: "claude",
  model: "claude-opus-5-5",
  label: "Opus 5.5",
  efforts: [],
  recents: [],
  onLand: () => undefined,
  onEffort: () => undefined,
};

export default componentEntry<ModelPickerProps>({
  id: "agent-pane.model-picker",
  title: "Model picker",
  area: "Agent pane",
  height: 390,
  anchors: [{ selector: ".acpmux-model" }],
  covers: ["agent-session/acpmux/ModelPicker.tsx#ModelPicker"],
  styles: () => Promise.all([import("./styles.css"), import("./modelPicker.css")]),
  load: () => import("./ModelPicker").then((module) => module.ModelPicker),
  variants: {
    idle: {
      props: { ...base, catalogRefresh: refresh("idle", "2026-10-07T10:00:00Z") },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Model" });
        await ctx.click({ role: "button", name: "Refresh models" });
      },
    },
    // Picker v2: a short list per harness under "More models", the running harness at the bottom.
    open: { props: base, play: openPicker },
    "more-models": {
      props: base,
      play: async (ctx) => {
        await openPicker(ctx);
        await ctx.click({ selector: ".acpmux-mp-more" });
      },
    },
    // Starring a model from More sinks it to the bottom with a filled star.
    starred: {
      props: base,
      play: async (ctx) => {
        await openPicker(ctx);
        await ctx.click({ selector: ".acpmux-mp-more" });
        await ctx.click({ role: "button", name: "Model: Haiku 4.5" });
      },
    },
    "hover-harness": {
      props: base,
      play: async (ctx) => {
        await openPicker(ctx);
        await ctx.hover({ selector: ".acpmux-mp-harness:first-child" });
      },
    },
    "search-all": {
      props: base,
      play: async (ctx) => {
        await openPicker(ctx);
        await ctx.type("6");
      },
    },
    fetching: { props: { ...base, catalogRefresh: refresh("fetching", "2026-10-07T10:00:00Z") } },
    updated: { props: { ...base, catalogRefresh: refresh("updated", "2026-10-07T12:30:00Z") } },
    error: { props: { ...base, catalogRefresh: refresh("error", "2026-10-07T10:00:00Z") } },
  },
});
