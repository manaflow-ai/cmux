// l10n-allow-file: gallery fixture labels, not shipped UI.
// The hover surfaces' material, side by side over a busy chat: the tooltip (ui/Tooltip.tsx) and a
// link's hover card (chips/LinkHoverCard.tsx) as they draw today, as a real material (a strong
// blur that keeps the colour under it, a thin translucent tint, a hairline rim and a soft shadow, as
// Quick Look and Finder's hover cards are), and as a crisp solid card with no glass (Leo, 2026-11-05:
// "this awkward wannabe glass but kind of just opaque thing").
import { componentEntry } from "../gallery/format";

type Look = "current" | "material" | "solid" | "control";
type Props = { looks?: Look[] };

const NAMES: Record<Look, string> = { current: "Today", material: "Material", solid: "Solid", control: "Blur only" };

function Backdrop() {
  return (
    <div className="hm-backdrop" aria-hidden="true">
      <p>
        I've merged the fix, but it covers one cause. The reply only shows when the turn ends part is Austin's
        #32958, which keeps the working line live while the tools run.
      </p>
      <div className="hm-shot" />
      <p>
        <code>webviews/src/ui/glass/glass.css</code> draws every tooltip and hover card; the native panel draws
        the same tint behind the app's own hover windows.
      </p>
    </div>
  );
}

function Column({ look }: { look: Look }) {
  return (
    <section className={`hm-column hm-look--${look}`}>
      <h3 className="hm-name">{NAMES[look]}</h3>
      <div className="hm-stage">
        <Backdrop />
        {look === "control" && <div className="hm-blur-control" />}
        <div className="ui-tooltip ui-glass hm-tooltip" role="tooltip">
          <span className="ui-tooltip-label">
            <span className="ui-tooltip-text">Fork from here</span>
          </span>
          <span className="ui-tooltip-detail">Start a new thread. This one stays as it is.</span>
        </div>
        <div className="ui-tooltip ui-card ui-glass ui-glass-floats cv-link-preview hm-card">
          <div className="cv-link-preview__content">
            <div className="cv-link-preview__head">
              <span className="cv-link-preview__icon">◆</span>
              <span className="cv-link-preview__titles">
                <span className="cv-link-preview__site">manaflow-ai/cmux#32958</span>
                <span className="cv-link-preview__target">github.com</span>
              </span>
            </div>
            <div className="hm-card-body">Agent chat: the working line stays live while tools run</div>
          </div>
        </div>
      </div>
    </section>
  );
}

function HoverMaterialGallery({ looks = ["current", "material", "solid"] }: Props) {
  return (
    <div className="hm-grid">
      {looks.map((look) => (
        <Column key={look} look={look} />
      ))}
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.hover-material",
  title: "Hover surface material",
  area: "UI primitives",
  height: 360,
  widths: { narrow: 420, normal: 980, wide: 1200 },
  covers: ["ui/Tooltip.tsx#Tooltip", "agent-session/acpmux/chips/LinkHoverCard.tsx#LinkHoverCard"],
  load: async () => HoverMaterialGallery,
  styles: () =>
    Promise.all([
      import("./HoverMaterial.gallery.css"),
      import("./controls.css"),
      import("../agent-session/acpmux/chips/linkCard.css"),
    ]),
  variants: {
    compare: { note: "Today, a real material and a crisp solid card over the same chat." },
    shipped: { note: "The shipped hover material alone.", props: { looks: ["current"] } },
    "blur-control": {
      note: "A bare 24px backdrop blur over the chat, no tint: shows whether this engine draws backdrop blur at all.",
      props: { looks: ["control"] },
    },
  },
});
