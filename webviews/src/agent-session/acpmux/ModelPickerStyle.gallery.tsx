// l10n-allow-file: gallery fixtures (sample models), not shipped UI.
// Settings > Agent Chat > Model Picker Style (`agentPane.display.modelPickerStyle`, chatDisplay.ts):
// what a click on the model chip of a New Tab or a chat that can switch harness opens. `list`, the
// default, is the harness rail and its model columns; `menu`, a look's pick after the Claude Code
// app's model menu, is the compact menu a started chat already opens (QuickModelMenu.tsx): the
// harness's numbered models, an Effort submenu, Fast mode where the harness has one, and More models
// for the full picker.
import { useLayoutEffect } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { MODEL_PICKER_STYLE_KEY, type ModelPickerStyle, setChatDisplay } from "./chatDisplay";
import type { ModelPickerProps } from "./modelPickerLayout";
import { MODEL_PICKER } from "./composerSelectors";

type Props = ModelPickerProps & { pickerStyle: ModelPickerStyle };

const models = (names: string[]) => names.map((name) => ({ id: name.toLowerCase().replace(/ /g, "-"), name }));

const levels = ["Low", "Medium", "High", "Extra High", "Max"].map((name) => ({
  id: name.toLowerCase().replace(/ /g, ""),
  name,
}));

const claude: ModelPickerProps = {
  catalog: [
    { id: "claude", name: "Claude Code", models: models(["Opus 5.5", "Sonnet 5.5", "Haiku 5.5", "Fable 5.1"]) },
    { id: "codex", name: "Codex", models: models(["GPT-6.1 Sol", "GPT-6 Astra", "GPT-6 Luna"]) },
    { id: "gemini", name: "Gemini CLI", models: models(["Gemini 3 Pro"]) },
  ],
  harness: "claude",
  model: "opus-5.5",
  label: "Opus 5.5",
  efforts: [],
  recents: [],
  onLand: () => undefined,
  onEffort: () => undefined,
  onHarness: () => undefined,
  quick: {
    effort: { levels, current: "high", onPick: () => undefined },
    fast: { checked: false, onChange: () => undefined },
  },
};

// A harness with no Fast mode: the menu draws no Fast mode row.
const codex: ModelPickerProps = {
  ...claude,
  harness: "codex",
  model: "gpt-6.1-sol",
  label: "GPT-6.1 Sol",
  quick: { effort: { levels, current: "medium", onPick: () => undefined } },
};

const openPicker: Play = async (ctx) => {
  await ctx.click({ selector: MODEL_PICKER });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-quick-menu, .acpmux-cols") !== null);
};
const openEffort: Play = async (ctx) => {
  await openPicker(ctx);
  await ctx.hover({ role: "menuitem", name: /^Effort/ });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-quick-submenu") !== null);
};

export default componentEntry<Props>({
  id: "agent-pane.model-picker-style",
  title: "Model picker style",
  area: "Agent pane",
  pane: true,
  height: 520,
  widths: { normal: 560, wide: 760 },
  anchors: [{ selector: ".acpmux-model" }],
  covers: ["agent-session/acpmux/ModelPicker.tsx#ModelPicker"],
  styles: () => Promise.all([import("./styles.css"), import("./modelPicker.css"), import("./composerControls.css")]),
  load: () =>
    import("./ModelPicker").then(({ ModelPicker }) => {
      function ModelPickerStyleDemo({ pickerStyle, ...rest }: Props) {
        useLayoutEffect(() => {
          setChatDisplay(pickerStyle === "menu" ? { [MODEL_PICKER_STYLE_KEY]: "menu" } : {});
          return () => setChatDisplay({});
        }, [pickerStyle]);
        return (
          <div style={{ display: "flex", flexDirection: "column", justifyContent: "flex-end", height: "100%" }}>
            <ModelPicker {...rest} />
          </div>
        );
      }
      return ModelPickerStyleDemo;
    }),
  variants: {
    list: {
      note: "List (the default): the harness rail and its model columns, as today.",
      props: { ...claude, pickerStyle: "list" },
      play: openPicker,
    },
    menu: {
      note: "Menu: the compact menu, the harness's models numbered, Effort, Fast mode and More models.",
      props: { ...claude, pickerStyle: "menu" },
      play: openPicker,
    },
    "menu-effort": {
      note: "Menu with its Effort submenu open.",
      props: { ...claude, pickerStyle: "menu" },
      play: openEffort,
    },
    "menu-no-fast": {
      note: "Menu on a harness with no Fast mode: no Fast mode row.",
      props: { ...codex, pickerStyle: "menu" },
      play: openPicker,
    },
  },
});
