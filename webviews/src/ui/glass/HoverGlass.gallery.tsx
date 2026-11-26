// l10n-allow-file: hover glass gallery fixtures, not shipped UI.
// Every hover tooltip and hover preview on the one glass (Leo, 2026-11-20: "WHERE IS THE GLASS
// EVERYWHERE ALL THESE STUPID F***ING HOVER TOOLTIPS AND HOVER PREVIEW SHIT"): the tooltip, a title
// tooltip, a link's hover card, the header icons' preview and the thread minimap's card, over a
// wallpaper and transcript text, with the real classes the shipped surfaces carry (glass.css,
// desktop.css). `text-floor` lays each over crisp text with no blur under it, as a see-through page
// does over the composer: the underlay keeps --surface-text-min. `off` is the solid look (Reduce
// Transparency, and appearance.liquidGlass off once it ships): the opaque popup surface, no blur.
import { type CSSProperties } from "react";
import { componentEntry } from "../../gallery/format";
import { KeyHint } from "../KeyHint";
import wallpaper from "../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";

type Look = "glass" | "text-floor" | "off";
type Props = { look: Look; scheme: "light" | "dark" };

const TRANSCRIPT =
  "Ran the suite on the fleet: 412 passed, 3 skipped. The composer keeps its height while the model menu is open, and the chat under it never reads through a list row.";

function HoverGlassGallery({ look, scheme }: Props) {
  const off = look === "off";
  const floor = look === "text-floor";
  // Off: what glass.css's Reduce Transparency rules set, scoped to this stage.
  const solid = off
    ? ({
        "--glass-tint": "var(--glass-opaque)",
        "--glass-backdrop": "none",
        "--tooltip-tint": "var(--surface-popup)",
      } as CSSProperties)
    : {};
  // Text floor: the underlay a see-through Chromium page lays under a text-carrying glass that nothing
  // blurs under (glass.css "TEXT ON GLASS KEEPS ITS FLOOR").
  const under = floor
    ? ({
        background:
          "linear-gradient(var(--glass-tint), var(--glass-tint)), color-mix(in srgb, var(--glass-surface) var(--surface-text-min), transparent)",
      } as CSSProperties)
    : {};
  const place: CSSProperties = { position: "relative", inset: "auto", margin: 0, ...solid, ...under };
  return (
    <div
      style={
        {
          colorScheme: scheme,
          padding: "var(--ds-space-6)",
          minHeight: 460,
          background: off ? "var(--cmux-surface-solid)" : `url("${wallpaper}") center / cover`,
          color: "var(--cmux-text)",
          "--cmux-text": scheme === "dark" ? "rgb(240 240 242)" : "rgb(26 26 29)",
          "--cmux-surface-solid": scheme === "dark" ? "rgb(28 28 30)" : "rgb(252 252 252)",
          "--glass-surface": "var(--cmux-surface-solid)",
        } as CSSProperties
      }
    >
      <p>
        {look} · {scheme}
      </p>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(3, minmax(0, 1fr))", gap: "var(--ds-space-6)" }}>
        <section style={{ position: "relative" }}>
          <p style={{ position: "absolute", inset: 0, margin: 0, opacity: 0.9 }}>{TRANSCRIPT}</p>
          <p style={{ position: "relative" }}>Tooltip</p>
          <div className="ui-tooltip ui-glass" style={{ ...place, width: "fit-content" }}>
            Show sidebar <KeyHint keys="⌘S" className="ui-tooltip-hint" />
          </div>
          <p style={{ position: "relative" }}>Title tooltip</p>
          <div className="ui-title-tooltip ui-glass" style={{ ...place, position: "relative", width: "fit-content" }}>
            ~/Projects/cmux/webviews/src/ui/glass/glass.css
          </div>
        </section>
        <section style={{ position: "relative" }}>
          <p style={{ position: "absolute", inset: 0, margin: 0, opacity: 0.9 }}>{TRANSCRIPT}</p>
          <p style={{ position: "relative" }}>Link hover card</p>
          <div className="ui-tooltip ui-card ui-glass" style={{ ...place, maxWidth: 260 }}>
            <strong>Pull request</strong>
            <div>Glass on every hover tooltip and preview</div>
            <div style={{ opacity: 0.7 }}>3 checks passed</div>
          </div>
        </section>
        <section style={{ position: "relative" }}>
          <p style={{ position: "absolute", inset: 0, margin: 0, opacity: 0.9 }}>{TRANSCRIPT}</p>
          <p style={{ position: "relative" }}>Header icon preview</p>
          <div className="ui-card ui-glass acpmux-header-preview" style={{ ...place, width: 176, padding: 8 }}>
            <div style={{ height: 48, borderRadius: 4, background: "var(--ds-surface-inset)", marginBottom: 8 }} />
            <strong>Browser</strong> <KeyHint keys="⌘⇧B" />
          </div>
          <p style={{ position: "relative" }}>Thread minimap card</p>
          <div
            className="acpmux-minimap__card ui-glass ui-glass-transient"
            style={{ ...place, padding: 8, maxWidth: 280 }}
          >
            <div>Make the hover previews glass</div>
            <div style={{ opacity: 0.7 }}>Done: every tooltip and card draws the one glass.</div>
          </div>
        </section>
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.hover-glass",
  title: "Hover tooltips and previews on glass",
  area: "Pages",
  height: 500,
  covers: [
    "ui/glass/glass.css",
    "ui/Tooltip.tsx",
    "ui/titleTooltips.ts",
    "agent-session/acpmux/header/HeaderToolPreview.tsx#HeaderToolPreview",
  ],
  load: async () => HoverGlassGallery,
  variants: Object.fromEntries(
    (["light", "dark"] as const).flatMap((scheme) =>
      (["glass", "text-floor", "off"] as const).map((look) => [
        `${look}-${scheme}`,
        {
          props: { look, scheme },
          note:
            look === "glass"
              ? "The shared hover glass: tooltip tint or hover card material over the frost."
              : look === "text-floor"
                ? "No blur under it (over the composer): the underlay keeps --surface-text-min under the text."
                : "Off / Reduce Transparency: the solid popup surface, no blur.",
        },
      ]),
    ),
  ),
});
