// l10n-allow-file: synthetic input regression fixture, not shipped copy.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { Picker } from "./ComposerPickers";
import { useMenuPressGuard } from "./menuPressGuard";

function PickerPointerGallery() {
  const [picked, setPicked] = useState<string[]>([]);
  useMenuPressGuard();
  return (
    <div className="acpmux-composer-gallery-shell acpmux-composer">
      <div className="acpmux-composer-gallery-copy">
        <strong>Composer action picker</strong>
        <output data-testid="picker-receipt">{picked.length ? `Selected: ${picked.join(", ")}` : "No action selected"}</output>
      </div>
      <Picker label="Actions" className="acpmux-composer-plus" button="Actions" align="start"
        sections={[{ choices: [{ id: "attach", name: "Attach file" }, { id: "mention", name: "Mention file" }],
          onPick: (id) => setPicked((values) => [...values, id]) }]} />
    </div>
  );
}

export default componentEntry({
  id: "agent-pane.picker-pointer",
  title: "Composer picker pointer buttons",
  area: "Agent pane",
  pane: true,
  height: 360,
  widths: { narrow: 300, normal: 520, wide: 760 },
  covers: ["agent-session/acpmux/ComposerPickers.tsx#Picker"],
  styles: () => Promise.all([import("./styles.css"), import("./ComposerPickers.gallery.css")]),
  load: async () => PickerPointerGallery,
  variants: {
    closed: { props: {} },
    open: {
      props: {},
      play: async (ctx) => {
        await ctx.click({ role: "combobox", name: "Actions" });
        await ctx.waitFor(() => ctx.document.querySelector('[role="listbox"]'));
      },
    },
  },
});
