// l10n-allow-file: gallery fixtures (sample models), not shipped UI.
// The full model picker's harness rail at three densities (Leo 2026-10-20: "you're giving way too
// much space to the model things, the harnesses on the left there ... the padding itself, and then
// even the buttons, like the buttons can, I assume, be kind of like rounded squared off-ish").
// `condensed` ships (modelPicker.css's rail tokens: a 36px rail of 28px rounded-square tabs, 4px
// ends, 2px gaps). `dense` is a step tighter (32px rail, 24px tabs, the small radius). `before` is
// the rail as it was: 44px wide, 6px ends, 4px gaps, 32px round tabs.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { ModelPickerProps } from "./modelPickerLayout";
import { MODEL_PICKER } from "./composerSelectors";

type RailDensity = "condensed" | "dense" | "before";
type Props = ModelPickerProps & { rail: RailDensity };

const RAIL_CSS: Record<RailDensity, string> = {
  condensed: "",
  dense: `
.acpmux-mp {
  --acpmux-mp-rail-width: 32px;
  --acpmux-mp-rail-tab: 24px;
  --acpmux-mp-rail-pad: 4px;
  --acpmux-mp-rail-gap: 2px;
  --acpmux-mp-rail-radius: var(--ds-radius-sm, 4px);
}
`,
  before: `
.acpmux-mp {
  --acpmux-mp-rail-width: 44px;
  --acpmux-mp-rail-tab: 32px;
  --acpmux-mp-rail-pad: 6px;
  --acpmux-mp-rail-gap: 4px;
  --acpmux-mp-rail-radius: 9999px;
}
`,
};

const models = (names: string[]) => names.map((name) => ({ id: name.toLowerCase().replace(/ /g, "-"), name }));

const props: ModelPickerProps = {
  catalog: [
    { id: "claude", name: "Claude Code", models: models(["Opus 5.5", "Sonnet 5.5", "Haiku 5.5", "Fable 5.1"]) },
    { id: "codex", name: "Codex", models: models(["GPT-6.1 Sol", "GPT-6 Astra", "GPT-6 Luna"]) },
    { id: "opencode", name: "OpenCode", models: models(["Big Pickle"]) },
    { id: "pi", name: "Pi", models: models(["GPT-6.1 Sol"]) },
    { id: "gemini", name: "Gemini CLI", models: models(["Gemini 3 Pro"]) },
  ],
  harness: "claude",
  model: "opus-5.5",
  label: "Opus 5.5",
  efforts: [],
  recents: [],
  onLand: () => undefined,
  onEffort: () => undefined,
};

const openPicker: Play = async (ctx) => {
  await ctx.click({ selector: MODEL_PICKER });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-mp-rail-tab") !== null);
};

export default componentEntry<Props>({
  id: "agent-pane.model-picker-rail",
  title: "Model picker harness rail",
  area: "Agent pane",
  pane: true,
  height: 520,
  widths: { normal: 560 },
  anchors: [{ selector: ".acpmux-model" }],
  covers: ["agent-session/acpmux/ModelPicker.tsx#ModelPicker"],
  styles: () => Promise.all([import("./styles.css"), import("./modelPicker.css"), import("./composerControls.css")]),
  load: () =>
    import("./ModelPicker").then(({ ModelPicker }) => ({ rail, ...rest }: Props) => (
      <>
        <style>{RAIL_CSS[rail]}</style>
        <ModelPicker {...rest} />
      </>
    )),
  variants: {
    condensed: { props: { ...props, rail: "condensed" }, play: openPicker },
    dense: { props: { ...props, rail: "dense" }, play: openPicker },
    before: { props: { ...props, rail: "before" }, play: openPicker },
  },
});
