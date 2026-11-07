// l10n-allow-file: gallery fixtures (sample prompts and file names), not shipped UI.
// Leo, 2026-11-07: "when an attachment is inside of the composer, it's at a smaller size, and when it
// gets sent up, it gets slightly expanded just a bit. And that recalculation is jarring". A screenshot
// and a screen recording wait in a composer's strip as chips; Send hands them to the real UserBubble
// as the pane's own row draws them before acpmux's echo, each preview laid out at its final size from
// the first frame. The variants are how the preview gets from the chip to its slot (sendMorph.ts):
// `move` (the product's) draws its first frame over the chip and moves there; `grow` scales up from
// the chip's size in its slot; `fade` is the swap with no move, as before.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { SCREEN_RECORDING_POSTER_JPEG } from "../../../gallery/fixtures/videoPoster";
import type { AcpmuxRow, PromptContentPart, PromptImage } from "../model";
import { frameName, framesNote } from "../composer/videoPrompt";
import { ImageViewerContext } from "./imageViewerContext";
import { chipRef, noteSendOrigins, type SendMorphStyle } from "./sendMorph";
import { TurnActionsContext } from "./turnActions";
import { UserBubble } from "./UserBubble";

const VIDEO = "Screen Recording 2026-11-07 at 06.51.20.mov";
const PATH = `/Users/dev/Desktop/${VIDEO}`;
const POSTER = `data:image/jpeg;base64,${SCREEN_RECORDING_POSTER_JPEG}`;
const NOTE = framesNote(VIDEO, 12_400, 1920, 1080, [0]);
/// A 1440x900 screenshot: a solid PNG the page draws, so its header names its size.
function screenshot(): string {
  const canvas = document.createElement("canvas");
  canvas.width = 1440;
  canvas.height = 900;
  const context = canvas.getContext("2d")!;
  context.fillStyle = "#3a7bd5";
  context.fillRect(0, 0, canvas.width, canvas.height);
  context.fillStyle = "#f2f4f8";
  context.fillRect(80, 80, 1280, 120);
  return canvas.toDataURL("image/png");
}

const TYPED = "Why does the sidebar jump when I open this?";

function sentRow(shot: string): { row: AcpmuxRow; text: string } {
  const image: PromptImage = { id: "send-shot", mimeType: "image/png", name: "Screenshot.png", src: shot };
  const frame: PromptImage = { id: "send-frame", mimeType: "image/jpeg", name: frameName(VIDEO, 0), src: POSTER };
  const parts: PromptContentPart[] = [
    { kind: "text", text: TYPED },
    { kind: "image", ...image },
    { kind: "file", name: VIDEO, uri: `file://${encodeURI(PATH)}` },
    { kind: "text", text: NOTE },
    { kind: "text", text: frame.name! },
    { kind: "image", ...frame },
  ];
  const text = parts.flatMap((part) => (part.kind === "text" ? [part.text] : [])).join("\n");
  return {
    row: { id: "local-send", version: 1, at: 0, kind: "user", text, images: [image, frame], inlineParts: parts },
    text,
  };
}

function SendTransitionGallery({ variant }: { variant: SendMorphStyle }) {
  const [shot] = useState(screenshot);
  const [sent, setSent] = useState<{ row: AcpmuxRow; text: string }>();
  const [actions] = useState(() => ({ promptImage: async () => undefined }));
  const send = () => {
    noteSendOrigins([{ id: "send-shot" }, { id: "send-video", path: PATH }]);
    setSent(sentRow(shot));
  };
  return (
    <ImageViewerContext.Provider value={() => {}}>
      <TurnActionsContext.Provider value={actions}>
        <main
          data-send-morph={variant}
          data-send-transition
          style={{ display: "flex", flexDirection: "column", height: "100%", padding: 16, boxSizing: "border-box" }}
        >
          <div style={{ flex: 1, display: "flex", flexDirection: "column", justifyContent: "flex-end" }}>
            {sent && (
              <div className="cv-user">
                <UserBubble row={sent.row} text={sent.text} />
              </div>
            )}
          </div>
          <div className="ui-glass" style={{ borderRadius: 12, padding: 12, marginTop: 16 }}>
            {!sent && (
              <fieldset className="acpmux-attachments">
                <div className="acpmux-attachment-slot" ref={chipRef("send-shot")}>
                  <div className="acpmux-attachment acpmux-attachment-image">
                    <img alt="Screenshot" src={shot} />
                  </div>
                </div>
                <div className="acpmux-attachment-slot" data-gallery-chip="video" ref={chipRef("send-video")}>
                  <div className="acpmux-attachment acpmux-attachment-image acpmux-attachment-video">
                    <img alt="" src={POSTER} />
                  </div>
                </div>
              </fieldset>
            )}
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8 }}>
              <span>{sent ? "" : TYPED}</span>
              <button type="button" className="ui-button" data-send onClick={sent ? () => setSent(undefined) : send}>
                {sent ? "Reset" : "Send"}
              </button>
            </div>
          </div>
        </main>
      </TurnActionsContext.Provider>
    </ImageViewerContext.Provider>
  );
}

export default componentEntry<{ variant: SendMorphStyle }>({
  id: "agent-pane.send-transition",
  title: "Sent attachment transition",
  area: "Agent pane",
  pane: true,
  height: 520,
  anchors: [{ selector: "[data-send-transition]" }],
  covers: [
    "agent-session/acpmux/conversation/sendMorph.ts",
    "agent-session/acpmux/conversation/UserBubble.tsx",
    "agent-session/acpmux/conversation/SentVideoTile.tsx",
  ],
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("../composerAttachments.css"),
    ]),
  load: async () => SendTransitionGallery,
  variants: {
    move: {
      note: "The product's: each preview's first frame is over its chip, then it moves to its slot at its final size; the row and the text beside it are in place from the first frame.",
      props: { variant: "move" },
    },
    grow: {
      note: "Each preview sits in its slot and scales up from its chip's size around its center; the row fades in.",
      props: { variant: "grow" },
    },
    fade: {
      note: "Before: the chips leave and the previews appear in their slots at a larger size in the same frame.",
      props: { variant: "fade" },
    },
  },
});
