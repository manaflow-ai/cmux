// l10n-allow-file: gallery fixtures (sample models), not shipped UI.
// The compact model menu's density versions (Leo 2026-10-28: "AND I THINK IT'S ALL SO STUPIDLY
// SPACED AND STYLED IT'S FUCKING TONKA TOYS"), each open on its list and on its Effort submenu.
// `native` ships; `before` is the menu as it was.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { DENSITY_CSS, MENU_DENSITIES, type MenuDensity } from "../../gallery/fixtures/modelMenuDensity";
import type { ModelPickerProps } from "./modelPickerLayout";

type Props = ModelPickerProps & { density: MenuDensity };

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
  quick: {
    effort: {
      levels: ["Low", "Medium", "High", "Extra High", "Max", "Ultracode"].map((name) => ({
        id: name.toLowerCase().replace(/ /g, ""),
        name,
      })),
      current: "high",
      onPick: () => undefined,
    },
    fast: { checked: true, onChange: () => undefined },
  },
};

const openMenu: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-model .acpmux-picker-button" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-quick-menu") !== null);
};
const openEffort: Play = async (ctx) => {
  await openMenu(ctx);
  await ctx.hover({ role: "menuitem", name: /^Effort/ });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-quick-submenu") !== null);
};

export default componentEntry<Props>({
  id: "agent-pane.model-menu-density",
  title: "Model menu density",
  area: "Agent pane",
  pane: true,
  height: 520,
  widths: { normal: 560 },
  anchors: [{ selector: ".acpmux-model" }],
  covers: ["agent-session/acpmux/QuickModelMenu.tsx#QuickModelMenu"],
  styles: () => Promise.all([import("./styles.css"), import("./modelPicker.css"), import("./composerControls.css")]),
  load: () =>
    import("./ModelPicker").then(({ ModelPicker }) => ({ density, ...rest }: Props) => (
      <>
        <style>{DENSITY_CSS[density]}</style>
        <div style={{ paddingTop: 440 }}>
          <ModelPicker {...rest} />
        </div>
      </>
    )),
  variants: Object.fromEntries(
    MENU_DENSITIES.flatMap((density) => [
      [density, { props: { ...props, density }, play: openMenu }],
      [`${density}-effort`, { props: { ...props, density }, play: openEffort }],
    ]),
  ),
});
