// l10n-allow-file: gallery fixtures (sample models), not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { BaseUiModelPickerProps, SpikeHarness } from "./BaseUiModelPicker";

const claude: SpikeHarness = {
  id: "claude",
  name: "Claude Code",
  models: [
    { value: "claude-opus-5-5", label: "Opus 5.5", group: "Latest" },
    { value: "claude-sonnet-5-5", label: "Sonnet 5.5", group: "Latest" },
    { value: "claude-haiku-5-5", label: "Haiku 5.5", group: "Latest" },
    { value: "claude-opus-4-1", label: "Opus 4.1", group: "Older" },
    { value: "claude-sonnet-4-5", label: "Sonnet 4.5", group: "Older" },
    { value: "claude-haiku-4-5", label: "Haiku 4.5", group: "Older" },
  ],
};
const codexNames = [
  "GPT-6.1-Sol",
  "GPT-6-Astra",
  "GPT-6.1-Luna",
  "GPT-6.1-Terra",
  "GPT-6-Sol",
  "GPT-6-Luna",
  "GPT-6-Terra",
  "GPT-5.5",
  "GPT-5.5 Mini",
  "GPT-5.4",
  "GPT-5.4 Mini",
  "GPT-5.3",
  "GPT-5.2",
  "GPT-5.1",
  "GPT-5",
  "Daybreak Blue",
  "Daybreak Green",
];
const codex: SpikeHarness = {
  id: "codex",
  name: "Codex",
  models: codexNames.map((label, index) => ({
    value: label.toLowerCase().replaceAll(" ", "-"),
    label,
    group: index < 4 ? "Latest" : index < 15 ? "Older" : "Preview",
  })),
};
const opencode: SpikeHarness = {
  id: "opencode",
  name: "OpenCode",
  models: [
    { value: "kimi-k3", label: "Kimi K3" },
    { value: "qwen-4-coder", label: "Qwen 4 Coder" },
  ],
};

const base: BaseUiModelPickerProps = {
  harnesses: [claude, codex, opencode],
  harness: "claude",
  model: "claude-opus-5-5",
  effort: "high",
  fast: true,
};

const open: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Model" });
  await ctx.waitFor(() => ctx.document.querySelector(".spike-mp") !== null);
};

export default componentEntry<BaseUiModelPickerProps>({
  id: "ui.spike-base-ui-model-picker",
  title: "Model picker (Base UI spike)",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 560,
  covers: ["ui/spike/BaseUiModelPicker.tsx#BaseUiModelPicker"],
  styles: () =>
    Promise.all([import("./BaseUiModelPicker.css"), import("../../agent-session/acpmux/conversation/spinner.css")]),
  load: () => import("./BaseUiModelPicker").then(({ BaseUiModelPicker }) => BaseUiModelPicker),
  variants: {
    // No play: the bench (bench/model-picker-open.bench.ts) opens it itself.
    closed: { props: base },
    open: { props: base, play: open },
    "long-list": { props: { ...base, harness: "codex", model: "gpt-6.1-sol" }, play: open },
    loading: {
      note: "The harness is still reporting its models: the shared spinner.",
      props: { ...base, harness: "opencode", harnesses: [claude, codex, { ...opencode, loading: true }] },
      play: open,
    },
    empty: {
      note: "No models and no query: No models yet. Refresh…",
      props: {
        ...base,
        harness: "opencode",
        model: undefined,
        harnesses: [claude, codex, { ...opencode, models: [] }],
      },
      play: open,
    },
    "no-match": {
      note: "A typed query with no match: No matching models.",
      props: base,
      play: async (ctx) => {
        await open(ctx);
        await ctx.type("zzz", { role: "combobox", name: "Search models" });
      },
    },
  },
});
