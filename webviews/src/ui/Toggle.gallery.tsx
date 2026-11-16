// l10n-allow-file: gallery labels are fixture content, not shipped UI.
// Standalone Toggle and ToggleGroup (ui/Toggle.tsx). Light and dark are the gallery's theme axis.
// Picked as the default: `ghost`, nothing at rest and the selection fill while pressed, the fill a
// selected row and the active pill tab already use, so a pressed toggle reads like every other
// "this one is on" in the app. Shipped as opt-in looks: `outline` (a hairline at rest, for a toggle
// standing alone among text) and `segmented` (Tabs' segmented track, for two to four peer modes).
// Not picked: `accent`, the theme accent fill while pressed: the accent is kept for a surface's one
// primary action, and several pressed toggles would each shout.
import { useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { Toggle, ToggleGroup, type ToggleVariant } from "./Toggle";

type Look = ToggleVariant | "accent";
type Props = { look: Look; orientation?: "horizontal" | "vertical" };

const FORMATS = [
  { value: "bold", label: "Bold" },
  { value: "italic", label: "Italic" },
  { value: "code", label: "Code" },
];
const VIEWS = [
  { value: "split", label: "Split" },
  { value: "unified", label: "Unified" },
  { value: "files", label: "Files only" },
];

function ToggleGallery({ look, orientation = "horizontal" }: Props) {
  const variant: ToggleVariant = look === "accent" ? "ghost" : look;
  const [wrap, setWrap] = useState(true);
  const [formats, setFormats] = useState<string[]>(["bold"]);
  const [view, setView] = useState<string[]>(["split"]);
  return (
    <div className="ui-controls-stage ui-toggle-gallery" data-look={look} data-gallery-capture="">
      <div className="ui-controls-row">
        <span className="ui-controls-label">Toggle</span>
        <Toggle variant={variant === "segmented" ? "outline" : variant} pressed={wrap} onPressedChange={setWrap}>
          Wrap lines
        </Toggle>
      </div>
      <div className="ui-controls-row">
        <span className="ui-controls-label">Multiple</span>
        <ToggleGroup
          aria-label="Text format"
          variant={variant}
          multiple
          orientation={orientation}
          value={formats}
          onValueChange={setFormats}
        >
          {FORMATS.map((format) => (
            <Toggle key={format.value} value={format.value}>
              {format.label}
            </Toggle>
          ))}
        </ToggleGroup>
      </div>
      <div className="ui-controls-row">
        <span className="ui-controls-label">Single</span>
        <ToggleGroup
          aria-label="Diff view"
          variant={variant}
          orientation={orientation}
          value={view}
          // Single choice keeps one pressed: pressing the pressed one again leaves it on.
          onValueChange={(next) => next.length > 0 && setView(next)}
        >
          {VIEWS.map((option) => (
            <Toggle key={option.value} value={option.value}>
              {option.label}
            </Toggle>
          ))}
        </ToggleGroup>
      </div>
      <output className="ui-controls-receipt" data-testid="toggle-receipt">
        {[wrap ? "wrap" : "nowrap", formats.join("+") || "plain", view[0]].join(" ")}
      </output>
    </div>
  );
}

const arrows: Play = async (ctx) => {
  await ctx.focus({ role: "button", name: "Split" });
  await ctx.press("ArrowRight");
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.find({ testId: "toggle-receipt" }).textContent?.endsWith("unified"));
};

export default componentEntry<Props>({
  id: "ui.toggle",
  title: "Toggle",
  area: "UI primitives",
  height: 240,
  keywords: ["toggle group", "segmented", "pressed", "aria-pressed"],
  covers: ["ui/Toggle.tsx"],
  load: async () => ToggleGallery,
  styles: () => Promise.all([import("./ui.css"), import("./controls.gallery.css"), import("./Toggle.gallery.css")]),
  variants: {
    ghost: {
      props: { look: "ghost" },
      note: "Picked (the default): the selection fill while pressed, as a selected row.",
    },
    outline: { props: { look: "outline" }, note: "Shipped, opt-in: a hairline at rest, for a toggle among text." },
    segmented: { props: { look: "segmented" }, note: "Shipped, opt-in: Tabs' segmented track for peer modes." },
    accent: { props: { look: "accent" }, note: "Not picked: the accent is kept for the one primary action." },
    vertical: { props: { look: "ghost", orientation: "vertical" }, note: "A vertical group: Up and Down move." },
    arrows: { props: { look: "segmented" }, play: arrows, note: "Arrows rove the group; Return presses." },
  },
});
