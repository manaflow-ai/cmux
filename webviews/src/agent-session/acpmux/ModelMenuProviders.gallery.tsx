// l10n-allow-file: gallery fixtures (sample models), not shipped UI.
// An OpenCode chat's model menu, as Lawrence's screenshot showed it (2026-10-22: "spacing + needs
// search", "we should just have a standard model picker"): one model offered by several providers,
// each once its own row. Three versions of one row per model; `row` ships.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { ModelPickerProps } from "./modelPickerLayout";
import type { QuickProviderLook } from "./QuickModelMenu";

const catalog: ModelPickerProps["catalog"] = [
  {
    id: "opencode",
    name: "OpenCode",
    models: [
      { id: "opencode/deepseek-v4-pro", name: "DeepSeek V4 Pro [New]" },
      { id: "opencode/deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash" },
      { id: "openrouter/deepseek/deepseek-v4-pro", name: "OpenRouter/DeepSeek V4 Pro" },
      { id: "openrouter/deepseek/deepseek-v4.1-flash", name: "OpenRouter/DeepSeek V4.1 Flash" },
      { id: "openrouter/deepseek/deepseek-chat", name: "OpenRouter/DeepSeek Chat" },
      { id: "deepseek/deepseek-v4-pro", name: "DeepSeek/DeepSeek V4 Pro" },
      { id: "deepseek/deepseek-chat", name: "DeepSeek/DeepSeek Chat" },
      { id: "deepseek/deepseek-reasoner", name: "DeepSeek/DeepSeek Reasoner" },
      { id: "groq/deepseek-r2-distill", name: "Groq/DeepSeek R2 Distill" },
      { id: "zai/glm-5.3", name: "Z.ai/GLM 5.3" },
    ],
  },
];

const chat = (providers: QuickProviderLook): ModelPickerProps => ({
  catalog,
  harness: "opencode",
  model: "opencode/deepseek-v4-pro",
  label: "DeepSeek V4 Pro",
  efforts: [],
  recents: [],
  harnessFixed: true,
  quick: {
    providers,
    effort: {
      levels: [
        { id: "low", name: "Low" },
        { id: "medium", name: "Medium" },
        { id: "high", name: "High" },
      ],
      current: "medium",
      onPick: () => undefined,
    },
  },
  onLand: () => undefined,
  onEffort: () => undefined,
});

const open: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-model .acpmux-picker-button" });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-quick-menu [role="menuitemradio"]') !== null);
};

/// Opens the menu, then the submenu row whose name starts with `name`.
const openSub =
  (name: string): Play =>
  async (ctx) => {
    await open(ctx);
    await ctx.click({ role: "menuitem", name: new RegExp(`^${name}`) });
    await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-quick-menu").length > 1);
  };

export default componentEntry<ModelPickerProps>({
  id: "agent-pane.model-menu-providers",
  title: "Model menu: one row per model",
  area: "Agent pane",
  pane: true,
  height: 420,
  widths: { narrow: 240, normal: 420, wide: 760 },
  anchors: [{ selector: ".acpmux-model" }],
  covers: ["agent-session/acpmux/modelVariants.ts#groupVariants"],
  styles: () => Promise.all([import("./styles.css"), import("./modelPicker.css")]),
  load: () => import("./ModelPicker").then(({ ModelPicker }) => ModelPicker),
  variants: {
    "provider-row": {
      note: "Version A (ships): each model once, the provider it lands at the row's end; a Provider row switches the running model's.",
      props: chat("row"),
      play: open,
    },
    "provider-row-open": {
      note: "Version A: the Provider row's submenu, the running provider checked.",
      props: chat("row"),
      play: openSub("Provider"),
    },
    "provider-submenu": {
      note: "Version B: a model several providers serve is a submenu of them; a pick takes a hover more.",
      props: chat("submenu"),
      play: open,
    },
    "provider-submenu-open": {
      note: "Version B: the DeepSeek V4 Pro row's providers.",
      props: chat("submenu"),
      play: openSub("DeepSeek V4 Pro"),
    },
    "provider-expanded": {
      note: "Version C: the model's name heads its providers, indented under it; every provider shows, at a row each.",
      props: chat("expanded"),
      play: open,
    },
  },
});
