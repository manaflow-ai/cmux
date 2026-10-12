// l10n-allow-file: gallery fixtures (sample models), not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { ModelPickerProps } from "./modelPickerLayout";
import type { Play } from "../../gallery/play";

const catalog: ModelPickerProps["catalog"] = [
  {
    id: "claude",
    name: "Claude Code",
    models: [
      { id: "claude-opus-5-5", name: "Opus 5.5" },
      { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
      { id: "claude-opus-4-1", name: "Opus 4.1" },
      { id: "claude-haiku-4-5", name: "Haiku 4.5" },
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

const numericSearch: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Model" });
  const search = { selector: '.acpmux-mp input[role="combobox"]' };
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-mp input[role="combobox"]') !== null);
  await ctx.type("gpt", search);
  await ctx.press("1");
  // With a query active, a digit is search input rather than a row shortcut. The menu remains
  // mounted after the key, whereas the old shortcut path selected the first cross-harness match
  // and closed the picker.
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-mp input[role="combobox"]') !== null);
};

export default componentEntry<ModelPickerProps>({
  id: "agent-pane.model-picker",
  title: "Model picker",
  area: "Agent pane",
  height: 390,
  widths: { narrow: 200, normal: 420, wide: 760 },
  anchors: [{ selector: ".acpmux-model" }],
  covers: ["agent-session/acpmux/ModelPicker.tsx#ModelPicker", "ui/ScrollArea.tsx#ScrollArea"],
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
    fetching: { props: { ...base, catalogRefresh: refresh("fetching", "2026-10-07T10:00:00Z") } },
    updated: { props: { ...base, catalogRefresh: refresh("updated", "2026-10-07T12:30:00Z") } },
    error: { props: { ...base, catalogRefresh: refresh("error", "2026-10-07T10:00:00Z") } },
    "numeric-search": {
      props: { ...base },
      play: numericSearch,
    },
    // A folder profile whose icon names no brand: the chip draws no mark (never a placeholder
    // square), and its rail tab its initial.
    "profile-without-mark": {
      props: {
        ...base,
        catalog: [
          {
            id: "vercel-ai-gateway",
            name: "Vercel AI Gateway",
            icon: "/icons/vercel-ai-gateway.svg",
            folder: { folder: "/Users/me/app", state: "enabled" },
            models: [{ id: "apex", name: "Apex" }],
          },
          ...catalog,
        ],
        harness: "vercel-ai-gateway",
        model: "apex",
        label: "Apex",
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Model" });
      },
    },
  },
});
