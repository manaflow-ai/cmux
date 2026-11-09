// l10n-allow-file: gallery fixtures (sample file names and pasted text), not shipped UI.
// An attachment chip's remove × (RemoveGlyph.tsx; Leo, 2026-11-06: "Also this close button, this is
// bad clarity. Like it just is. Why is this like this?"). The strip's image, pasted-text and file
// chips with their × shown, as the pointer on each would show it. `inverted` ships; the others are
// the designs it was picked over, drawn here by overriding the shipped badge.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { ComposerAttachment } from "../attachments";

type Design = "before" | "surface" | "inverted" | "gutter";
type Props = { design: Design };

const BADGES = ".acpmux-attachment-remove";

const DESIGNS: Record<Design, string> = {
  // Base: 82% of the composer's glass (13% of the text over a see-through page), a 1 px × and a
  // hairline ring; the × fades in over the chip's label.
  before: `
    [data-remove-design=before] ${BADGES} {
      border-radius: 8px;
      background: color-mix(in srgb, var(--acpmux-composer-bg) 82%, transparent);
      box-shadow: 0 0 0 var(--cmux-hairline, 0.5px) var(--acpmux-composer-edge);
      color: var(--agent-text);
    }
    [data-remove-design=before] .acpmux-remove-glyph path { stroke-width: 1; }`,
  // The composer's opaque surface as the disc, the text as the ×, a strong ring.
  surface: `
    [data-remove-design=surface] ${BADGES} {
      background: var(--acpmux-composer-solid, var(--acpmux-base, Canvas));
      box-shadow: 0 0 0 1px var(--agent-border-strong, color-mix(in srgb, var(--agent-text) 30%, transparent));
      color: var(--agent-text);
    }`,
  inverted: "",
  // The shipped badge, and the text card's first lines keep clear of its corner.
  gutter: `
    [data-remove-design=gutter] .acpmux-text-card__lines { padding-right: var(--ds-space-5); box-sizing: border-box; }`,
};

const pasted = [
  "Map cmux Cloud link architecture",
  "Read the Cloud link client, the relay and the pairing flow;",
  "say which side owns reconnect and where the token lives.",
  ...Array.from({ length: 14 }, (_, index) => `  step ${index + 4}: trace the handshake`),
].join("\n");

/** A picture `width`×`height` in `hue`, light near the top-right corner where the × sits. */
function shot(width: number, height: number, hue: number): string {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ink = canvas.getContext("2d")!;
  const fill = ink.createLinearGradient(0, height, width, 0);
  fill.addColorStop(0, `hsl(${hue} 30% 18%)`);
  fill.addColorStop(1, `hsl(${hue} 40% 82%)`);
  ink.fillStyle = fill;
  ink.fillRect(0, 0, width, height);
  const url = canvas.toDataURL("image/png");
  return url.slice(url.indexOf(",") + 1);
}

function fixtures(): ComposerAttachment[] {
  return [
    { id: "shot", kind: "image", name: "image.png", mimeType: "image/png", size: 1, data: shot(800, 600, 220) },
    {
      id: "paste",
      kind: "pasted",
      name: "Map cmux Cloud link",
      mimeType: "text/plain",
      size: pasted.length,
      text: pasted,
    },
    {
      id: "file",
      kind: "link",
      name: "cloud-link-architecture.md",
      mimeType: "text/markdown",
      size: 18_400,
      path: "/Users/sample/Desktop/cloud-link-architecture.md",
    },
  ];
}

/// Every × is drawn, solid where it ships: its glyph at 8 px (never scaled) inside its badge.
const glyphsCrisp: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelectorAll(BADGES).length >= 3);
  for (const badge of ctx.document.querySelectorAll<HTMLElement>(BADGES)) {
    const glyph = badge.querySelector("svg")!;
    const box = glyph.getBoundingClientRect();
    if (box.width !== 8 || box.height !== 8) throw new Error(`a × glyph is ${box.width}×${box.height}, not 8×8`);
    if (glyph.getAttribute("viewBox") !== "0 0 8 8") throw new Error("a × glyph is scaled from another view box");
  }
};

export default componentEntry<Props>({
  id: "agent-pane.attachment-remove",
  title: "Attachment remove ×",
  area: "Composer",
  pane: true,
  height: 260,
  widths: { normal: 620, narrow: 340 },
  covers: [
    "agent-session/acpmux/composer/RemoveGlyph.tsx#RemoveGlyph",
    "agent-session/acpmux/composer/attachmentIntake.tsx#AttachmentStrip",
  ],
  styles: () => Promise.all([import("../styles.css"), import("../composerAttachments.css")]).then(() => undefined),
  load: () =>
    import("./attachmentIntake").then(
      ({ AttachmentStrip }) =>
        function Gallery({ design }: Props) {
          return (
            <div
              className="acpmux-shell"
              style={{ padding: "var(--ds-space-5)", display: "block", height: "auto" }}
              data-remove-design={design}
            >
              {/* The pointer on every chip at once: each × shown. */}
              <style>{`[data-remove-design] ${BADGES} { opacity: 1; }${DESIGNS[design]}`}</style>
              <div className="acpmux-composer">
                <div className="acpmux-composer-box ui-glass" style={{ minHeight: 112 }}>
                  <AttachmentStrip attachments={fixtures()} onRemove={() => {}} onExpand={() => {}} />
                  <div style={{ padding: "var(--ds-space-4)" }}>Which side owns reconnect?</div>
                </div>
              </div>
            </div>
          );
        },
    ),
  variants: {
    before: {
      note: "Before: a 1 px × on 82% of the composer's glass, which is itself 13% of the text over a see-through page. Over the pasted card's first line it reads as a faint × printed on the text.",
      props: { design: "before" },
    },
    surface: {
      note: "The composer's opaque surface as the disc with the text's × and a strong ring. Solid, but in a dark theme the disc is nearly the card's own colour, so the control is found by its ring alone.",
      props: { design: "surface" },
      play: glyphsCrisp,
    },
    inverted: {
      note: "Shipped. A solid disc in the text's colour with the page's opaque base as an 8 px ×, drawn at its own size (no scaled glyph), and a ring of the base to cut it from a bright thumbnail. The contrast of the text itself in light and dark; shown at once on hover, no fade.",
      props: { design: "inverted" },
      play: glyphsCrisp,
    },
    gutter: {
      note: "The shipped badge, and the text card's lines stop 24 px short of the corner so the × never covers a word. Costs the card's widest lines on every paste, shown or not; the solid badge alone already keeps the label legible.",
      props: { design: "gutter" },
      play: glyphsCrisp,
    },
  },
});
