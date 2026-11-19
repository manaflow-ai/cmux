// l10n-allow-file: gallery states, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { buildPickerCatalog, BUNDLED_MODEL_CATALOG } from "./modelCatalogData";
import type { ModelPickerProps } from "./modelPickerLayout";

const ids = ["gemini-4-carbon", "gemini-4-hydrogen"];
const catalog = buildPickerCatalog({
  catalog: BUNDLED_MODEL_CATALOG,
  acpmux: [
    {
      id: "gemini",
      name: "Gemini CLI",
      family: "gemini",
      topModels: ids,
      models: ids.map((id) => ({ id, curated: true })),
    },
  ],
})
  .harnesses.filter((harness) => harness.id === "gemini")
  .map((harness) => ({ ...harness, top: harness.topModels }));

const base: ModelPickerProps = {
  catalog,
  harness: "gemini",
  model: ids[0],
  label: "4 Carbon",
  efforts: [],
  recents: [],
  quick: {},
  onLand: () => undefined,
  onEffort: () => undefined,
  onHarness: () => undefined,
  onCombo: () => undefined,
};

const open: Play = async (ctx) => {
  await ctx.click({ selector: '[data-menu="Model"]' });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-cols [role="listbox"]'));
};

export default componentEntry<ModelPickerProps>({
  id: "agent-pane.model-picker-day-one",
  title: "Model menu: new releases",
  area: "Agent pane",
  pane: true,
  height: 460,
  widths: { narrow: 320, normal: 520, wide: 760 },
  anchors: [{ selector: ".acpmux-model" }],
  covers: ["agent-session/acpmux/QuickModelColumns.tsx#QuickModelColumns"],
  styles: () => Promise.all([import("./styles.css"), import("./modelPicker.css")]),
  load: () => import("./ModelPicker").then(({ ModelPicker }) => ModelPicker),
  variants: {
    carbon: { note: "New releases retain catalog order with Carbon selected.", props: base, play: open },
    hydrogen: {
      note: "Hydrogen is selected in the same compact menu.",
      props: { ...base, model: ids[1], label: "4 Hydrogen" },
      play: open,
    },
    retired: {
      note: "A chat on a refused legacy model can choose either current release.",
      props: {
        ...base,
        model: "gemini-4-argon",
        label: "4 Argon",
        catalog: catalog.map((harness) => ({
          ...harness,
          models: [
            ...harness.models,
            { id: "gemini-4-argon", name: "4 Argon", unavailable: "This model is no longer available" },
          ],
        })),
      },
      play: open,
    },
  },
});
