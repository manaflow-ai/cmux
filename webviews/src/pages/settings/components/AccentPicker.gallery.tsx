// l10n-allow-file: gallery fixture (sample accent choices), not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { AccentPicker, type AccentChoice } from "./AccentPicker";

const choices: AccentChoice[] = Array.from({ length: 20 }, (_, index) => ({
  value: `accent-${index}`,
  label: `Accent ${index + 1}`,
  swatch: "var(--agent-accent)",
  art: false,
}));

function AccentFixture() {
  const [value, setValue] = useState(choices[0]!.value);
  return (
    <section className="settings-page" style={{ padding: 16 }}>
      <span id="accent-fixture-label">Accent color</span>
      <AccentPicker
        value={value}
        choices={choices}
        labelId="accent-fixture-label"
        label="Accent color"
        disabled={false}
        onPick={setValue}
      />
    </section>
  );
}

export default componentEntry({
  id: "settings.accent-picker",
  title: "Accent picker scroll edges",
  area: "Settings",
  height: 430,
  widths: { narrow: 360, normal: 600 },
  covers: ["pages/settings/components/AccentPicker.tsx#AccentPicker", "ui/Listbox.tsx#Listbox"],
  load: async () => AccentFixture,
  styles: () => import("../page.css"),
  variants: {
    overflowing: {
      note: "Rich accent rows scroll inside the theme-style listbox.",
      props: {},
      play: async (ctx) => {
        await ctx.click({ selector: "[data-accent-picker]" });
        await ctx.waitFor(() => ctx.document.querySelectorAll("[data-accent-option]").length === choices.length);
      },
    },
  },
});
