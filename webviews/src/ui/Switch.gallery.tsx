// l10n-allow-file: gallery labels are fixture content, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { Switch, type SwitchSize } from "./Switch";

type Props = { size?: SwitchSize; checked?: boolean };

function SwitchGallery({ size = "md", checked = false }: Props) {
  const [on, setOn] = useState(checked);
  return (
    <div className="ui-controls-stage">
      <div className="ui-controls-setting">
        <span>Fast mode</span>
        <Switch size={size} checked={on} onCheckedChange={setOn} aria-label="Fast mode" />
      </div>
      <div className="ui-controls-setting">
        <span>Always on</span>
        <Switch size={size} defaultChecked aria-label="Always on" />
      </div>
      <div className="ui-controls-setting">
        <span>Unavailable</span>
        <Switch size={size} disabled aria-label="Unavailable" />
      </div>
      <output className="ui-controls-receipt" data-testid="switch-receipt">
        {on ? "on" : "off"}
      </output>
    </div>
  );
}

const space: Play = async (ctx) => {
  await ctx.focus({ role: "switch", name: "Fast mode" });
  await ctx.press("Space");
  await ctx.waitFor(() => ctx.find({ testId: "switch-receipt" }).textContent === "on");
};

export default componentEntry<Props>({
  id: "ui.switch",
  title: "Switch",
  area: "UI primitives",
  height: 220,
  covers: ["ui/Switch.tsx#Switch"],
  load: async () => SwitchGallery,
  styles: () => Promise.all([import("./ui.css"), import("./controls.gallery.css")]),
  variants: {
    md: { props: { size: "md" }, note: "The default: 32 x 20, the size settings rows use." },
    sm: { props: { size: "sm" }, note: "Inside a menu row or a popover (Claude's fast-mode switch)." },
    lg: { props: { size: "lg" } },
    "md-on": { props: { size: "md", checked: true } },
    space: { props: {}, play: space },
  },
});
