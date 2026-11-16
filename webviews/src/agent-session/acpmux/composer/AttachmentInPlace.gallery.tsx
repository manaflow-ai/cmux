// l10n-allow-file: gallery fixtures (a sample prompt), not shipped UI.
// An attachment loading while the person types on (Leo, 2026-11-09: "the loading placeholder for
// attachments goes to the top... when it actually loads, it gets smashed in between text that you
// were typing if u were typing as it loaded. so the placeholders should be right at the composer in
// and instant"). The placeholder shows at once where the attachment ends, and the read picture takes
// that same place; the words typed meanwhile stay whole around it (composer/inlineAttachments.tsx,
// test/composer-attachment-loads-in-place.test.ts).
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";

type Phase =
  /// Shipped: the placeholder in the text where it was pasted, the words typed after it.
  | "in-text"
  /// Shipped: the read ended, the picture in the placeholder's place.
  | "in-text-ready"
  /// Shipped: a paste where no attachment can go (a code block) loads in the strip and stays there.
  | "strip-home"
  /// Before: the placeholder up in the strip while the words are typed.
  | "before-strip"
  /// Before: the read ended and the picture went in at the caret, in the middle of a word.
  | "before-smashed";
type Props = { phase: Phase };

/** A screenshot-shaped picture, `width`×`height`, for the chip the read makes. */
function shot(width: number, height: number): string {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ink = canvas.getContext("2d")!;
  const fill = ink.createLinearGradient(0, height, width, 0);
  fill.addColorStop(0, "hsl(215 30% 20%)");
  fill.addColorStop(1, "hsl(215 40% 80%)");
  ink.fillStyle = fill;
  ink.fillRect(0, 0, width, height);
  return canvas.toDataURL("image/png");
}

export default componentEntry<Props>({
  id: "agent-pane.composer-attachment-in-place",
  title: "Composer: an attachment loads in its place while the person types",
  area: "Composer",
  pane: true,
  height: 260,
  widths: { normal: 620, narrow: 340 },
  covers: ["agent-session/acpmux/composer/inlineAttachments.tsx#useInlineAttachments"],
  styles: () =>
    Promise.all([import("../styles.css"), import("../markdownField.css"), import("../composerAttachments.css")]).then(
      () => undefined,
    ),
  load: () =>
    Promise.all([import("./pasteLoading"), import("./pasteLoadingLook")]).then(
      ([{ PasteLoadingMark }, { PASTE_LOADING_CLASS }]) =>
        function Gallery({ phase }: Props) {
          const [read, setRead] = useState(phase === "in-text-ready" || phase === "before-smashed");
          const [picture] = useState(() => shot(1280, 800));
          const tile = (
            <span
              className={`acpmux-md-inline-chip ${PASTE_LOADING_CLASS}`}
              data-state="loading"
              data-paste-look="glass-ring"
              aria-busy="true"
              aria-label="Image"
            >
              <PasteLoadingMark look="glass-ring" size={14} className="acpmux-md-inline-spinner" upload={undefined} />
            </span>
          );
          const chip = (
            <span className="acpmux-md-inline-chip" data-state="ready" data-chip="strip" data-loaded="">
              <span className="acpmux-attachment acpmux-attachment-image">
                <img alt="Screenshot of the settings page" draggable={false} src={picture} />
              </span>
            </span>
          );
          const inline = (
            <span className="acpmux-md-inline" data-inline-attachment="shot">
              {read ? chip : tile}
            </span>
          );
          const stripTile = read ? (
            <span className="acpmux-attachment acpmux-attachment-image">
              <img alt="Screenshot of the settings page" draggable={false} src={picture} />
            </span>
          ) : (
            <span
              className={`acpmux-attachment acpmux-attachment-image acpmux-attachment-pending ${PASTE_LOADING_CLASS}`}
              data-paste-look="glass-ring"
              aria-busy="true"
              aria-label="Image"
            >
              <PasteLoadingMark look="glass-ring" size={14} className="acpmux-md-inline-spinner" upload={undefined} />
            </span>
          );
          const strip = phase === "strip-home" || phase === "before-strip";
          const text =
            phase === "before-smashed" ? (
              <p>Compare with the old one, the toggle mo{inline}ved left.</p>
            ) : phase === "before-strip" || phase === "strip-home" ? (
              <p>Compare with the old one, the toggle moved left.</p>
            ) : (
              <p>Compare {inline}with the old one, the toggle moved left.</p>
            );
          return (
            <div className="acpmux-shell" style={{ padding: "var(--ds-space-5)", display: "block", height: "auto" }}>
              <div className="acpmux-composer">
                <div
                  className="acpmux-composer-box ui-glass ui-glass-floats ui-glass-material"
                  data-attachment-view="inline"
                  style={{ minHeight: 112 }}
                >
                  {strip && <fieldset className="acpmux-attachments">{stripTile}</fieldset>}
                  <div className="acpmux-md" style={{ padding: "var(--ds-space-4)" }}>
                    {phase === "strip-home" && <pre>npm test</pre>}
                    {text}
                  </div>
                </div>
              </div>
              <button type="button" data-stage="read" style={{ marginTop: 12 }} onClick={() => setRead(true)}>
                Finish the read
              </button>
            </div>
          );
        },
    ),
  variants: {
    "in-text": {
      note: "Shipped. The placeholder is in the text where it was pasted from the first frame, and the words typed while it loads go on after it.",
      props: { phase: "in-text" },
    },
    "in-text-ready": {
      note: "Shipped. The read ended: the picture comes up in the placeholder's own node, the words on either side as typed.",
      props: { phase: "in-text-ready" },
    },
    "strip-home": {
      note: "Shipped. Pasted where no attachment can go (a code block), it loads in the strip and stays there: never put in at the caret the person moved to.",
      props: { phase: "strip-home" },
    },
    "before-strip": {
      note: "Before: a draft read that answered while it loaded took the placeholder out of the text, up into the strip.",
      props: { phase: "before-strip" },
    },
    "before-smashed": {
      note: "Before: the read ended and the picture went in at the caret, splitting the word being typed.",
      props: { phase: "before-smashed" },
    },
  },
});
