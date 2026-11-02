// l10n-allow-file: gallery fixtures (sample prompts and file names), not shipped UI.
// A prompt that sent a video with its frames (Leo, 2026-10-25: "also why dont we have previews of
// videos we should"): the real UserBubble with acpmux's record of it, its text and parts holding the
// frames note and labels the agent read (composer/videoPrompt.ts) and its images the frames. The
// bubble shows the video's poster with its length and a play glyph beside the prompt's screenshot;
// a click plays it in Quick Look. Before this change the same record drew no video at all.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { SCREEN_RECORDING_POSTER_JPEG } from "../../../gallery/fixtures/videoPoster";
import type { AcpmuxRow, PromptContentPart, PromptImage } from "../model";
import { frameName, framesNote } from "../composer/videoPrompt";
import { ImageViewerContext } from "./imageViewerContext";
import { TurnActionsContext } from "./turnActions";
import { UserBubble } from "./UserBubble";

const VIDEO = "Screen Recording 2026-10-25 at 10.42.13.mov";
const PATH = `/Users/dev/Desktop/${VIDEO}`;
const TIMES = [5300, 15900, 26500, 37100];
const NOTE = framesNote(VIDEO, 42_400, 1920, 1080, TIMES);
const SCREENSHOT_PNG =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

type Props = { typed: string; screenshot: boolean; pending?: boolean; placed?: boolean };

function GallerySentVideo({ typed, screenshot, pending = false, placed = false }: Props) {
  const frames: PromptImage[] = TIMES.map((atMs, index) => ({
    id: `frame-${index}`,
    mimeType: "image/jpeg",
    name: frameName(VIDEO, atMs),
    width: 1024,
    height: 576,
  }));
  const shot: PromptImage[] = screenshot
    ? [{ id: "shot", mimeType: "image/png", name: "Screenshot.png", width: 1440, height: 900 }]
    : [];
  const parts: PromptContentPart[] = [
    ...(typed ? [{ kind: "text" as const, text: typed }] : []),
    ...shot.map((image) => ({ kind: "image" as const, ...image })),
    { kind: "file", name: VIDEO, uri: `file://${encodeURI(PATH)}`, ...(placed ? { placed: true as const } : {}) },
    { kind: "text", text: NOTE },
    ...frames.flatMap((frame): PromptContentPart[] => [
      { kind: "text", text: frame.name! },
      { kind: "image", ...frame },
    ]),
    ...(placed ? [{ kind: "text" as const, text: "and then it settles." }] : []),
  ];
  const text = parts.flatMap((part) => (part.kind === "text" ? [part.text] : [])).join("\n");
  const row: AcpmuxRow = {
    id: "user-7",
    version: 1,
    at: 0,
    kind: "user",
    text,
    images: [...shot, ...frames],
    inlineParts: parts,
  };
  const [actions] = useState(() => ({
    promptImage: (id: string) =>
      pending
        ? new Promise<never>(() => {})
        : Promise.resolve(
            id === "shot"
              ? `data:image/png;base64,${SCREENSHOT_PNG}`
              : `data:image/jpeg;base64,${SCREEN_RECORDING_POSTER_JPEG}`,
          ),
  }));
  return (
    <ImageViewerContext.Provider value={() => {}}>
      <TurnActionsContext.Provider value={actions}>
        <div className="cv-user" style={{ padding: 16 }}>
          <UserBubble row={row} text={text} />
        </div>
      </TurnActionsContext.Provider>
    </ImageViewerContext.Provider>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.sent-video",
  title: "Sent prompt video",
  area: "Agent pane",
  pane: true,
  height: 260,
  covers: ["agent-session/acpmux/conversation/SentVideoTile.tsx", "agent-session/acpmux/conversation/sentVideos.ts"],
  load: async () => GallerySentVideo,
  variants: {
    "video-and-screenshot": {
      note: "A screenshot and a screen recording with a question. The recording is its poster with its length and a play glyph; its frames note and frames, which the agent read, are not drawn.",
      props: { typed: "Why does the sidebar jump when I open this?", screenshot: true },
    },
    "video-only": {
      note: "A recording sent alone: no empty bubble under it.",
      props: { typed: "", screenshot: false },
    },
    "video-loading": {
      note: "While acpmux reads the poster frame, the tile holds its shape with the play glyph and length.",
      props: { typed: "Watch this", screenshot: false, pending: true },
    },
    "video-placed": {
      note: "A recording placed in the text: its tile sits where it was put.",
      props: { typed: "Open the sidebar:", screenshot: false, placed: true },
    },
  },
});
