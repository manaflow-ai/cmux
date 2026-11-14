// l10n-allow-file: gallery fixtures (sample models and installer output), not shipped UI.
// Lawrence 2026-11-07: "we should make it possible to search for any model in cmux model picker and
// it needs to 'just work' aka download the relevant harness". A New Tab's model menu on a Mac with
// Claude Code alone: the search finds Gemini CLI's and OpenCode's models too, and a pick installs
// the harness with its progress in the menu (harnessSetup.ts).
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { ModelPickerProps } from "./modelPickerLayout";

const model = (id: string, name: string) => ({ id, name, efforts: ["low", "medium", "high"] });

const catalog: ModelPickerProps["catalog"] = [
  {
    id: "claude",
    name: "Claude Code",
    pickable: true,
    models: [model("claude-opus-5-5", "Opus 5.5"), model("claude-sonnet-5-5", "Sonnet 5.5")],
  },
  {
    id: "gemini",
    name: "Gemini CLI",
    pickable: true,
    notInstalled: true,
    models: [
      model("gemini-3.8-flash", "Gemini 3.8 Flash"),
      model("gemini-3.1-pro-preview", "Gemini 3.1 Pro Preview"),
      model("gemini-3.5-flash-lite", "Gemini 3.5 Flash Lite"),
    ],
  },
  {
    id: "opencode",
    name: "OpenCode",
    pickable: true,
    notInstalled: true,
    models: [
      { id: "opencode/gemini-3.8-flash", name: "Gemini 3.8 Flash" },
      { id: "opencode/deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash" },
      { id: "opencode-go/kimi-k3", name: "Kimi K3" },
    ],
  },
];

const base: ModelPickerProps = {
  catalog,
  harness: "claude",
  model: "claude-opus-5-5",
  label: "Opus 5.5",
  efforts: [],
  recents: [],
  quick: {},
  onLand: () => undefined,
  onEffort: () => undefined,
  onHarness: () => undefined,
  onCombo: () => undefined,
  onSetUpPick: () => undefined,
};

const open: Play = async (ctx) => {
  await ctx.click({ selector: '[data-menu="Model"]' });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-cols input[type=search]"));
};

const search =
  (text: string): Play =>
  async (ctx) => {
    await open(ctx);
    await ctx.type(text, { selector: ".acpmux-cols input[type=search]" });
    await ctx.waitFor(() => ctx.document.querySelector('.acpmux-cols [role="listbox"]'));
  };

export default componentEntry<ModelPickerProps>({
  id: "agent-pane.model-picker-any-model",
  title: "Model menu: search any model",
  area: "Agent pane",
  pane: true,
  height: 460,
  widths: { narrow: 320, normal: 520, wide: 760 },
  anchors: [{ selector: ".acpmux-model" }],
  covers: ["agent-session/acpmux/QuickModelColumns.tsx#QuickModelColumns"],
  styles: () => Promise.all([import("./styles.css"), import("./modelPicker.css")]),
  load: () => import("./ModelPicker").then(({ ModelPicker }) => ModelPicker),
  variants: {
    search: {
      note: "Typed “gemini 3.8 flash”: Gemini CLI and OpenCode are not installed; their models list after the ready ones.",
      props: base,
      play: search("gemini 3.8 flash"),
    },
    installing: {
      note: "A pick of Gemini 3.8 Flash: the CLI installs in place, its last output line under the step.",
      props: {
        ...base,
        switching: { harness: "gemini", name: "Installing Gemini CLI…" },
        setup: {
          text: "Installing Gemini CLI…",
          detail: "added 412 packages in 9s",
          busy: true,
          actions: [{ label: "Cancel", run: () => undefined }],
        },
      },
      play: open,
    },
  },
});
