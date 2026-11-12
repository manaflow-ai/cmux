// l10n-allow-file: gallery fixtures (a sample prompt), not shipped UI.
// A pasted screenshot while the composer still reads it, at the caret in the prompt's text and in the
// strip (composer/pasteLoading.tsx; Leo, 2026-11-07: "do we necessarily need a spinner for it? Or
// should it just sort of, like, be dimmed to start and then, like, gradually become more there as it
// actually loads in? ... Or actually, could we do both? Right now we just have a solid color with a
// spinner. But actually, why do we have a solid color thing anyway? Shouldn't it also be glass?").
// Every arm is the composer's glass, dim at first and coming up; they differ in what shows once the
// read passes 400 ms (pastePlaceholder.experiment.ts). The `chip` arms (Leo, 2026-11-11: "this 3
// stage attachment thing is still there") have no loading tile: the chip it becomes, in its final
// box, from the first frame (attachmentIntake.tsx PendingTile). `chip` ships.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { experimentArm } from "../../../experiments/experiment";
import { pastePlaceholderLook } from "./pastePlaceholder.experiment";

type Look = "chip" | "chip-blur" | "chip-bar" | "glass-ring" | "glass-bar" | "glass-dim" | "solid";
type Props = { look?: Look; ready?: boolean };

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

const readyButton = { selector: "[data-stage=ready]" };
const loaded = (ctx: PlayContext) => ctx.document.querySelector(".acpmux-md-inline-chip[data-state=ready] img");

export const pasteLoadingScript = [
  {
    name: "the paste: the loading chip at the caret (a late indicator after 400 ms in the glass arms)",
    run: async (ctx: PlayContext) => {
      await ctx.waitFor(() => ctx.document.querySelector(".acpmux-md-inline-chip[data-state=loading]"));
    },
  },
  {
    name: "the read ends: the chip in the loading one's place",
    run: async (ctx: PlayContext) => {
      await ctx.click(readyButton);
      await ctx.waitFor(() => loaded(ctx));
    },
  },
];

export default componentEntry<Props>({
  id: "agent-pane.composer-paste-loading",
  title: "Composer: a pasted attachment loading at the caret",
  area: "Composer",
  pane: true,
  height: 240,
  widths: { normal: 620, narrow: 340 },
  covers: ["agent-session/acpmux/composer/pasteLoading.tsx#PasteLoadingMark"],
  styles: () =>
    Promise.all([import("../styles.css"), import("../markdownField.css"), import("../composerAttachments.css")]).then(
      () => undefined,
    ),
  experiment: { definition: pastePlaceholderLook, script: pasteLoadingScript },
  load: () =>
    Promise.all([
      import("./pasteLoading"),
      import("./pasteLoadingLook"),
      import("../conversation/icons"),
      import("./attachmentIntake"),
    ]).then(
      ([{ PasteLoadingMark }, { PASTE_LOADING_CLASS, isChipLook }, { Spinner }, { PendingTile }]) =>
        function Gallery({ look: given, ready: readyAtFirst = false }: Props) {
          const look = given ?? experimentArm(pastePlaceholderLook);
          const [ready, setReady] = useState(readyAtFirst);
          const [picture] = useState(() => shot(1280, 800));
          // `solid`: the tile before this change, a solid fill and a spinner from the first frame.
          // A `chip` look: the chip itself while it loads, its picture from the file at once.
          const tile = isChipLook(look) ? (
            <span className="acpmux-md-inline-chip" data-state="loading" data-chip="strip">
              <PendingTile
                chip={{
                  id: "shot",
                  name: "image.png",
                  image: true,
                  size: { width: 1280, height: 800 },
                  preview: picture,
                }}
                look={look}
                name="Image"
                remove={null}
                upload={undefined}
              />
            </span>
          ) : look === "solid" ? (
            <span className="acpmux-md-inline-chip" data-state="loading" aria-busy="true" aria-label="Image">
              <Spinner loading size={14} className="acpmux-md-inline-spinner" />
            </span>
          ) : (
            <span
              className={`acpmux-md-inline-chip ${PASTE_LOADING_CLASS}`}
              data-state="loading"
              data-paste-look={look}
              aria-busy="true"
              aria-label="Image"
            >
              <PasteLoadingMark look={look} size={14} className="acpmux-md-inline-spinner" upload={undefined} />
            </span>
          );
          const chip = (
            <span
              className="acpmux-md-inline-chip"
              data-state="ready"
              data-chip="strip"
              {...(isChipLook(look) ? {} : { "data-loaded": "" })}
            >
              <span className="acpmux-attachment acpmux-attachment-image">
                <img alt="Screenshot of the narrow sidebar" draggable={false} src={picture} />
              </span>
            </span>
          );
          return (
            <div className="acpmux-shell" style={{ padding: "var(--ds-space-5)", display: "block", height: "auto" }}>
              <div className="acpmux-composer">
                <div
                  className="acpmux-composer-box ui-glass ui-glass-floats ui-glass-material"
                  data-attachment-view="inline"
                  style={{ minHeight: 112 }}
                >
                  <div className="acpmux-md" style={{ padding: "var(--ds-space-4)" }}>
                    <p>
                      The sidebar clips here{" "}
                      <span className="acpmux-md-inline" data-inline-attachment="shot">
                        {ready ? chip : tile}
                      </span>{" "}
                      when the window is narrow.
                    </p>
                  </div>
                </div>
              </div>
              <button type="button" data-stage="ready" style={{ marginTop: 12 }} onClick={() => setReady(true)}>
                Finish the read
              </button>
            </div>
          );
        },
    ),
  variants: {
    chip: {
      note: "Shipped. No loading tile: the pasted screenshot is its chip from the first frame, its own picture in its thumbnail's box at the caret. When the read ends the chip takes its place at the same size, so nothing changes size or moves. A file with no picture yet shows its kind's glyph in the same box.",
      props: { look: "chip" },
    },
    "chip-blur": {
      note: "The chip in its final box from the first frame, its picture soft until the read ends, then sharp in place (as a pasted screenshot uploads in another desktop chat app). Reads as still working, but the soft picture is a second look of the same chip.",
      props: { look: "chip-blur" },
    },
    "chip-bar": {
      note: "The chip in its final box from the first frame; a thin bar along its foot once the read passes 400 ms. Says a long read is working, but adds a mark the sent message never has.",
      props: { look: "chip-bar" },
    },
    "glass-ring": {
      note: "Before. The composer's glass at the caret, dim at first and coming up over a second; a small ring fades in only once the read passes 400 ms.",
      props: { look: "glass-ring" },
    },
    "glass-bar": {
      note: "The same glass and dim; a thin bar along the tile's foot fills once the read passes 400 ms. Reads as progress it does not know.",
      props: { look: "glass-bar" },
    },
    "glass-dim": {
      note: "The same glass and dim, no indicator at all. A slow read (a large screen recording) gives no sign it is still working.",
      props: { look: "glass-dim" },
    },
    solid: {
      note: "Before: a solid fill with a spinner from the first frame, so even a quick paste flashed one.",
      props: { look: "solid" },
    },
    ready: {
      note: "The read ended: the chip, the same size and place as the loading chip of the shipped look.",
      props: { look: "chip", ready: true },
    },
  },
});
