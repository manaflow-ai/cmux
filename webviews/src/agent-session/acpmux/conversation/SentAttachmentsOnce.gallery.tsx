// l10n-allow-file: gallery fixtures (his recorded prompt's names and words), not shipped UI.
// One send of a pasted screenshot and a screen recording (Leo, 2026-11-22: "WHAT THE FUCK IS THIS
// SITUATION MAN WITH THESE ATTACHMENTS!?"): the real UserBubble with his prompt as acpmux recorded
// it, the screenshot gone as its saved original's link (size 0, no type) and the same recording
// attached twice (two uploads of it). Each attachment draws once, as its kind: the screenshot as
// its picture, the recording as one tile with its poster and length. Before, the screenshot drew as
// "image.png 0 byte" and the recording as its tile plus a 179.9 MB file chip.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { SCREEN_RECORDING_POSTER_JPEG } from "../../../gallery/fixtures/videoPoster";
import { LOGIN_SCREENSHOT_PNG } from "../../../gallery/fixtures/toolImages";
import type { AcpmuxRow, PromptContentPart } from "../model";
import { recordedPromptParts } from "../inlinePrompt";
import { ImageViewerContext } from "./imageViewerContext";
import { TurnActionsContext } from "./turnActions";
import { UserBubble } from "./UserBubble";

const UPLOADS = "/Users/dev/.acpmux/uploads/01a18a35-b1e8-7951-ba2f-703bf916b9a6";
const VIDEO = "Screen Recording 2026-11-22 at 2.11.52 AM.mov";
const VIDEO_SIZE = 188_649_435;
const IMAGE_PATH = `${UPLOADS}/01a202bf-bff1-773e-a292-70c86e8c0d52/image.png`;
const videoPath = (upload: string) => `${UPLOADS}/${upload}/${VIDEO}`;
const fileUri = (path: string) => `file://${encodeURI(path)}`;
const POSTER = `data:image/jpeg;base64,${SCREEN_RECORDING_POSTER_JPEG}`;
const SHOT = `data:image/png;base64,${LOGIN_SCREENSHOT_PNG}`;

/// His prompt's parts as acpmux's history keeps them (session 01a18a35, seq 5359294).
const RECORDED = [
  {
    kind: "file",
    name: "image.png",
    placed: true,
    size: 0,
    uri: fileUri(IMAGE_PATH),
  },
  { kind: "text", text: "ok i guess we still haven't fixed this" },
  {
    kind: "file",
    mimeType: "video/quicktime",
    name: VIDEO,
    placed: true,
    size: VIDEO_SIZE,
    uri: fileUri(videoPath("01a202c0-543b-7499-b2b5-ecd1d33b5c68")),
  },
  {
    kind: "text",
    text: `Frames from the video ${VIDEO} (2:08, 4096×2154), in order, at: 0:00.0.`,
  },
  { kind: "text", text: `${VIDEO} frame at 0:00.0` },
  {
    kind: "image",
    id: "frame-0",
    mimeType: "image/jpeg",
    name: `${VIDEO} frame at 0:00.0`,
  },
  { kind: "text", text: "the same recording again" },
  {
    kind: "file",
    mimeType: "video/quicktime",
    name: VIDEO,
    placed: true,
    size: VIDEO_SIZE,
    uri: fileUri(videoPath("01a202c3-40d0-73b8-b17a-3dacf6bc421b")),
  },
  { kind: "text", text: "new line situation" },
];

type Props = { reads: "answer" | "never" };

function GallerySentOnce({ reads }: Props) {
  const row: AcpmuxRow = {
    id: "user-1",
    version: 1,
    kind: "user",
    at: 0,
    text: "ok i guess we still haven't fixed this",
    images: [
      {
        id: "frame-0",
        mimeType: "image/jpeg",
        name: `${VIDEO} frame at 0:00.0`,
      },
    ],
    inlineParts: recordedPromptParts({
      inlineParts: RECORDED,
    }) as PromptContentPart[],
  };
  const [actions] = useState(() => ({
    promptImage: () => (reads === "never" ? new Promise<never>(() => {}) : Promise.resolve(POSTER)),
  }));
  return (
    <ImageViewerContext.Provider value={() => {}}>
      <TurnActionsContext.Provider value={actions}>
        <div className="cv-user" style={{ padding: 16 }}>
          <UserBubble row={row} text={row.text ?? ""} />
        </div>
      </TurnActionsContext.Provider>
    </ImageViewerContext.Provider>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.sent-attachments-once",
  title: "Sent attachments, each once",
  area: "Agent pane",
  pane: true,
  height: 460,
  covers: [
    "agent-session/acpmux/conversation/UserBubble.tsx",
    "agent-session/acpmux/conversation/sentVideos.ts",
    "agent-session/acpmux/conversation/imageEntries.ts",
  ],
  load: async () => GallerySentOnce,
  variants: {
    "his-prompt": {
      note: 'Leo, 2026-11-22: "WHAT THE FUCK IS THIS SITUATION MAN WITH THESE ATTACHMENTS!?". His recorded prompt: the screenshot that went as its saved original\'s link is its picture (the host reads the file), and the recording attached twice is one tile with its poster and length, never also a .mov chip.',
      props: { reads: "answer" },
      chipHost: { images: { [IMAGE_PATH]: SHOT } },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".cv-user__video img"));
        await ctx.waitFor(() => ctx.document.querySelector(".cv-user__inline-image img, .cv-user__image img"));
      },
    },
    "his-prompt-unread": {
      note: "The same prompt where nothing answers: the host can't read the screenshot's file (another machine's chat), so it is its named chip with no \"0 byte\"; the recording's poster never arrives, so its tile is the plain slot with its play glyph. No slot spins or waits blank forever: a read unanswered past 15 s says the image failed.",
      props: { reads: "never" },
    },
  },
});
