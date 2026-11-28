// l10n-allow-file: gallery fixtures, not shipped UI.
// The contrast edge of floating glass (glass.css "THE CONTRAST EDGE"; the readback on cmux#59205:
// in the light theme over a light photo the hover card was white glass over white with no visible
// edge). A hover card, a menu and a tooltip on their real classes over a few rows of text, on the
// frame's theme and background, so the light, dark and busy photos of the background axis show each
// candidate: none (before), ring, lift, floor and ring-lift (what ships).
import { componentEntry } from "../../gallery/format";
import { KeyHint } from "../KeyHint";

type Edge = "none" | "ring" | "lift" | "floor" | "ring-lift";
type Props = { edge: Edge };

const ROWS = [
  "Moved the scroll anchor to the row under the pointer, so a new row above it no longer shifts the list.",
  "Ran the sidebar suite on the fleet: 214 passed, 0 failed, in 41 s.",
];
const MENU_ROWS = ["Open in New Tab", "Fork Conversation", "Copy Link", "Archive"];

function GlassContrastEdgeGallery({ edge }: Props) {
  return (
    <div className="glass-contrast-gallery" data-edge={edge === "ring-lift" ? undefined : edge}>
      <div className="glass-contrast-gallery-rows">
        {ROWS.map((row) => (
          <p key={row}>{row}</p>
        ))}
      </div>
      <div className="glass-contrast-gallery-stage">
        <div className="ui-tooltip ui-card ui-glass glass-contrast-gallery-card" role="tooltip">
          <strong>Fix the scroll anchor and land</strong>
          <span className="ui-tooltip-detail">Disconnected · 0s</span>
        </div>
        <div className="ui-popup ui-glass ui-menu glass-contrast-gallery-menu" role="menu">
          {MENU_ROWS.map((row) => (
            <div key={row} role="menuitem">
              {row}
            </div>
          ))}
        </div>
        <div className="ui-tooltip ui-glass glass-contrast-gallery-tip" role="tooltip">
          <span className="ui-tooltip-text">Show sidebar</span> <KeyHint keys="⌘S" className="ui-tooltip-hint" />
        </div>
      </div>
    </div>
  );
}

const NOTES: Record<Edge, string> = {
  none: "Before: the inner hairline and elevation 2 only; white glass over snow has no edge.",
  ring: "An outer ring of the theme's ink at 12%, light only.",
  lift: "A soft lift (0 4px 14px -4px, black 14%), light only, no ring.",
  floor: "A tint floor: 5% of the ink over the fill in light, so the glass is a step off white.",
  "ring-lift": "Shipped: the outer ink ring and the soft lift, light only; dark draws as before.",
};

export default componentEntry<Props>({
  id: "ui.glass-contrast-edge",
  title: "Glass contrast edge (light glass over a light wallpaper)",
  area: "UI primitives",
  height: 240,
  widths: { narrow: 520, normal: 760, wide: 760 },
  checks: {
    layoutShiftMax: { value: 0, reason: "The candidates are paint only: no surface changes size." },
  },
  covers: ["ui/glass/glass.css"],
  load: async () => GlassContrastEdgeGallery,
  styles: () => import("./GlassContrastEdge.gallery.css"),
  variants: Object.fromEntries(
    (["ring-lift", "none", "ring", "lift", "floor"] as const).map((edge) => [
      edge,
      { props: { edge }, note: NOTES[edge] },
    ]),
  ),
});
