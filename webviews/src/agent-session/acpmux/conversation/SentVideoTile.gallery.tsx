// l10n-allow-file: gallery fixtures (sample prompts and file names), not shipped UI.
// A prompt that sent a video with its frames (Leo, 2026-10-25: "also why dont we have previews of
// videos we should"): the real UserBubble with acpmux's record of it, its text and parts holding the
// frames note and labels the agent read (composer/videoPrompt.ts) and its images the frames. The
// bubble shows the video's poster with its length and a play glyph beside the prompt's screenshot;
// a click plays it in place, with the player's controls (video-playing). Before #31527 the same
// record drew no video at all. Its tile is the recording's own shape under a sent image's rule (at most
// 160px tall and 480px wide, contain), never a square with bands (Leo, 2026-11-22: "having this
// square is kinda strange"), and a recording placed in the text draws where it was put, in its final
// box from the first frame ("there should be no problem doing so for inline attachments after send").
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { SCREEN_RECORDING_POSTER_JPEG } from "../../../gallery/fixtures/videoPoster";
import { LOGIN_TESTS_MP4 } from "../../../gallery/fixtures/toolImages";
import type { AcpmuxRow, PromptContentPart, PromptImage } from "../model";
import { frameName, framesNote } from "../composer/videoPrompt";
import { attachmentsHoldTheirBoxes, heldUntilReleased, paintShot } from "../../../gallery/fixtures/sentMedia";

/// The host's `video.info` answer for the recording (composer/videoAttachments.ts).
const VIDEO_INFO = {
  durationMs: 42_400,
  width: 1920,
  height: 1080,
  poster: `data:image/jpeg;base64,${SCREEN_RECORDING_POSTER_JPEG}`,
  frames: [],
};
import { ImageViewerContext } from "./imageViewerContext";
import { TurnActionsContext } from "./turnActions";
import { UserBubble } from "./UserBubble";

const VIDEO = "Screen Recording 2026-10-25 at 10.42.13.mov";
const PATH = `/Users/dev/Desktop/${VIDEO}`;
const TIMES = [5300, 15900, 26500, 37100];

/// `frames` false: the video went as its link alone (its read failed or timed out, a chat on another
/// machine, an agent that takes no images), so acpmux's record has its file part and no frames.
/// `video`: the recording's picture size (1920x1080 unless given), which its frames note says and
/// its poster has. `after`: the words after a placed recording. `column`: the chat's width in px (a
/// pane split in half, a third or a quarter). `held`: acpmux's reads answer only when the play
/// releases them (gallery/fixtures/sentMedia.ts). `kept`: a recording sent without frames whose part
/// carries its size, as acpmux keeps it (hub/prompt_images.rs).
type Props = {
  typed: string;
  screenshot: boolean;
  pending?: boolean;
  placed?: boolean;
  frames?: boolean;
  video?: { width: number; height: number };
  after?: string;
  column?: number;
  held?: boolean;
  kept?: boolean;
};

function GallerySentVideo({
  typed,
  screenshot,
  pending = false,
  placed = false,
  frames: framed = true,
  video = { width: 1920, height: 1080 },
  after = "and then it settles.",
  column,
  held = false,
  kept = false,
}: Props) {
  const note = framesNote(VIDEO, 42_400, video.width, video.height, TIMES);
  // A frame as the host reads it: its longest side at most 1024.
  const frameScale = Math.min(1, 1024 / Math.max(video.width, video.height));
  const frames: PromptImage[] = TIMES.map((atMs, index) => ({
    id: `frame-${index}`,
    mimeType: "image/jpeg",
    name: frameName(VIDEO, atMs),
    width: Math.round(video.width * frameScale),
    height: Math.round(video.height * frameScale),
  }));
  const shot: PromptImage[] = screenshot
    ? [{ id: "shot", mimeType: "image/png", name: "Screenshot.png", width: 1440, height: 900 }]
    : [];
  const parts: PromptContentPart[] = [
    ...(typed ? [{ kind: "text" as const, text: typed }] : []),
    ...shot.map((image) => ({ kind: "image" as const, ...image, ...(placed ? { placed: true as const } : {}) })),
    {
      kind: "file",
      name: VIDEO,
      uri: `file://${encodeURI(PATH)}`,
      ...(placed ? { placed: true as const } : {}),
      ...(kept ? { width: video.width, height: video.height } : {}),
    },
    ...(framed
      ? [
          { kind: "text" as const, text: note },
          ...frames.flatMap((frame): PromptContentPart[] => [
            { kind: "text", text: frame.name! },
            { kind: "image", ...frame },
          ]),
        ]
      : []),
    ...(placed && after ? [{ kind: "text" as const, text: after }] : []),
  ];
  const text = parts.flatMap((part) => (part.kind === "text" ? [part.text] : [])).join("\n");
  const row: AcpmuxRow = {
    id: "user-7",
    version: 1,
    at: 0,
    kind: "user",
    text,
    images: [...shot, ...(framed ? frames : [])],
    inlineParts: parts,
  };
  const [actions] = useState(() => {
    // The poster in the recording's own shape, its longest side 320, as the host reads it.
    const posterScale = 320 / Math.max(video.width, video.height);
    const poster =
      video.width === 1920 && video.height === 1080
        ? `data:image/jpeg;base64,${SCREEN_RECORDING_POSTER_JPEG}`
        : paintShot(
            { width: Math.round(video.width * posterScale), height: Math.round(video.height * posterScale), hue: 210 },
            "image/jpeg",
          );
    // The screenshot's bytes are the 1440x900 its part says, so its box is whole from the first frame.
    const screenshotUrl = paintShot({ width: 1440, height: 900, hue: 30 });
    return {
      promptImage: (id: string) => {
        const url = id === "shot" ? screenshotUrl : poster;
        return pending ? new Promise<never>(() => {}) : held ? heldUntilReleased(url) : Promise.resolve(url);
      },
    };
  });
  return (
    <ImageViewerContext.Provider value={() => {}}>
      <TurnActionsContext.Provider value={actions}>
        <div className="cv-user" style={{ padding: 16, ...(column && { width: column, boxSizing: "border-box" }) }}>
          <UserBubble row={row} text={text} />
        </div>
      </TurnActionsContext.Provider>
    </ImageViewerContext.Provider>
  );
}

/// A placed recording draws where it was put, whole, in its final box from the first frame.
const placedHolds = attachmentsHoldTheirBoxes({ inBubble: true });

export default componentEntry<Props>({
  id: "agent-pane.sent-video",
  title: "Sent prompt video",
  area: "Agent pane",
  pane: true,
  height: 420,
  covers: ["agent-session/acpmux/conversation/SentVideoTile.tsx", "agent-session/acpmux/conversation/sentVideos.ts"],
  load: async () => GallerySentVideo,
  variants: {
    "video-and-screenshot": {
      note: "A screenshot and a screen recording with a question. The recording is its poster with its length and a play glyph; its frames note and frames, which the agent read, are not drawn.",
      props: { typed: "Why does the sidebar jump when I open this?", screenshot: true },
    },
    "video-playing": {
      note: "Leo, 2026-11-02: \"this i can't play a video preview inside cmux next? i feel like i should be able to\". A click on the poster's ▶ plays the recording in place: the tile becomes the reply's player, playing with sound and its scrub, mute and pause, with Expand and Open in tab, on the URL the host streams the file by in byte ranges (`media.load`). Held still at 1 s for the capture.",
      props: { typed: "Why does the sidebar jump when I open this?", screenshot: true },
      chipHost: { media: { [PATH]: `data:video/mp4;base64,${LOGIN_TESTS_MP4}` } },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".cv-user__video img"));
        await ctx.click({ selector: ".cv-user__video" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-user__video-player .cv-media__frame.is-playing"));
        const video = ctx.document.querySelector<HTMLVideoElement>(".cv-user__video-player video")!;
        video.pause();
        video.currentTime = 1;
        await ctx.waitFor(() => !video.seeking && video.readyState >= 2);
      },
    },
    "video-expanded": {
      note: 'Leo, 2026-11-03: "i can neither preview a vid in place nor have it pop up anymore". A double-click on the poster opens the recording large over the pane, playing with its controls, as a sent image opens in its viewer; Close brings the tile back. Held still at 1 s for the capture.',
      props: { typed: "Why does the sidebar jump when I open this?", screenshot: true },
      chipHost: { media: { [PATH]: `data:video/mp4;base64,${LOGIN_TESTS_MP4}` } },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".cv-user__video img"));
        const tile = ctx.document.querySelector<HTMLElement>(".cv-user__video")!;
        const view = ctx.document.defaultView!;
        tile.dispatchEvent(new view.MouseEvent("dblclick", { bubbles: true }));
        const playing = ".acpmux-image-viewer .cv-media__frame.is-playing video";
        await ctx.waitFor(() => ctx.document.querySelector(playing));
        const video = ctx.document.querySelector<HTMLVideoElement>(playing)!;
        video.pause();
        video.currentTime = 1;
        await ctx.waitFor(() => !video.seeking && video.readyState >= 2);
      },
    },
    "video-expanded-click-outside": {
      note: 'Leo, 2026-11-12: "The video playing thing, I need to be able to, like, click outside of the video and have that exit as well, but right now it\'s not doing that. It works for attachments like pictures though." The recording open large and playing; a click on the video leaves it open, a click beside it closes the viewer and brings the tile back, as beside an image in the image viewer.',
      props: { typed: "Why does the sidebar jump when I open this?", screenshot: true },
      chipHost: { media: { [PATH]: `data:video/mp4;base64,${LOGIN_TESTS_MP4}` } },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".cv-user__video img"));
        const tile = ctx.document.querySelector<HTMLElement>(".cv-user__video")!;
        const view = ctx.document.defaultView!;
        tile.dispatchEvent(new view.MouseEvent("dblclick", { bubbles: true }));
        const playing = ".acpmux-image-viewer .cv-media__frame.is-playing video";
        await ctx.waitFor(() => ctx.document.querySelector(playing));
        const press = (element: Element) => {
          for (const type of ["mousedown", "mouseup", "click"])
            element.dispatchEvent(new view.MouseEvent(type, { bubbles: true, cancelable: true, detail: 1 }));
        };
        press(ctx.document.querySelector(playing)!);
        if (!ctx.document.querySelector(".acpmux-image-viewer")) throw new Error("a click on the video closed it");
        press(ctx.document.querySelector(".acpmux-image-viewer .cv-media-stage")!);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-image-viewer") === null);
      },
    },
    "video-unplayable": {
      note: 'Leo, 2026-11-04: "i can neither preview a vid in place nor have it pop up anymore :(". A chat on another machine whose host will not stream the recording (an older daemon there, a file outside the chat\'s folders) and Quick Look refuses too: the click says so on the tile instead of doing nothing.',
      props: { typed: "Why does the sidebar jump when I open this?", screenshot: true },
      chipHost: { refused: ["media.load", "video.quickLook"] },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".cv-user__video img"));
        await ctx.click({ selector: ".cv-user__video" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-user__video-unplayable"));
      },
    },
    "video-unplayable-alone": {
      note: "The same refusal for a recording sent alone, its note over the poster in the play glyph's place.",
      props: { typed: "", screenshot: false },
      chipHost: { refused: ["media.load", "video.quickLook"] },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".cv-user__video img"));
        await ctx.click({ selector: ".cv-user__video" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-user__video-unplayable"));
      },
    },
    "video-only": {
      note: "A recording sent alone: no empty bubble under it.",
      props: { typed: "", screenshot: false },
    },
    "video-loading": {
      note: "While acpmux reads the poster frame, the tile holds its shape with the play glyph and length.",
      props: { typed: "Watch this", screenshot: false, pending: true },
    },
    "video-without-frames": {
      note: "Leo, 2026-11-06: \"how come this didn't give a preview and only has file name?\". A recording that went to the agent as its link alone (its read failed or timed out, a chat on another machine, an agent that takes no images) was a file chip with its name. It is the same tile: the host reads its poster, length and size from the file. A record from before acpmux kept a video's size has no size until that read, so its tile is the square until then (sent-video-without-frames-kept: one sent now has its box at once).",
      props: { typed: "The sidebar jumps when I open it", screenshot: false, placed: true, frames: false },
      chipHost: { videos: { [PATH]: VIDEO_INFO } },
    },
    "video-without-frames-unread": {
      note: "The same recording where the host cannot read the file (a chat on another machine): the square with its play glyph, never a file chip. A click still plays it.",
      props: { typed: "The sidebar jumps when I open it", screenshot: false, placed: true, frames: false },
      chipHost: { refused: ["video.info"] },
    },
    "video-without-frames-and-screenshot": {
      note: "A frameless recording beside a screenshot, in the attachment row above the bubble: its tile with its poster read from the file, then the screenshot.",
      props: { typed: "Why does the sidebar jump when I open this?", screenshot: true, frames: false },
      chipHost: { videos: { [PATH]: VIDEO_INFO } },
    },
    "video-placed": {
      note: "A recording placed in the text: its tile sits where it was put, in its final box from the first frame.",
      props: { typed: "Open the sidebar:", screenshot: false, placed: true, held: true },
      play: placedHolds,
    },
    "video-and-screenshot-placed-mid-sentence": {
      note: "A screenshot and a recording placed mid-sentence: each where it was put, each whole in its own shape.",
      height: 480,
      props: { typed: "Open the sidebar:", screenshot: true, placed: true, held: true },
      play: placedHolds,
    },
    "video-placed-loading": {
      note: "The same while acpmux reads the poster and the screenshot: each tile's box is its final one from the first frame, so nothing moves when they land.",
      height: 480,
      props: { typed: "Open the sidebar:", screenshot: true, placed: true, pending: true },
    },
    "sent-video-wide": {
      note: 'Leo, 2026-11-22: "having this square is kinda strange". His 0:04 screen recording (1406×434) placed mid-text: a 480×148 tile of the whole recording, no bands above and below, its play glyph and length on it; was a 160px square with the recording letterboxed in its middle.',
      props: {
        typed: "The plan list",
        screenshot: false,
        placed: true,
        video: { width: 1406, height: 434 },
        after: "keeps its old items.",
        held: true,
      },
      play: placedHolds,
    },
    "sent-video-wide-alone": {
      note: "The wide recording sent alone, no words: its tile in the strip, its own shape, no empty bubble.",
      props: { typed: "", screenshot: false, video: { width: 1406, height: 434 }, held: true },
      play: attachmentsHoldTheirBoxes(),
    },
    "sent-video-wide-after-text": {
      note: "Words, then the wide recording last: nothing after it.",
      props: {
        typed: "The plan list:",
        screenshot: false,
        placed: true,
        video: { width: 1406, height: 434 },
        after: "",
        held: true,
      },
      play: placedHolds,
    },
    "sent-video-16-9": {
      note: "A 16:9 recording (1920×1080) placed mid-text: 284×160, whole.",
      props: { typed: "Here", screenshot: false, placed: true, held: true },
      play: placedHolds,
    },
    "sent-video-portrait": {
      note: "A phone recording held upright (1080×1920) placed mid-text: 90×160, whole, never cropped to a wider box.",
      height: 320,
      props: {
        typed: "On the phone",
        screenshot: false,
        placed: true,
        video: { width: 1080, height: 1920 },
        after: "it jumps.",
        held: true,
      },
      play: placedHolds,
    },
    "sent-video-square": {
      note: "A square recording (1080×1080) placed mid-text: 160×160.",
      props: { typed: "Square", screenshot: false, placed: true, video: { width: 1080, height: 1080 }, held: true },
      play: placedHolds,
    },
    "sent-video-without-frames-kept": {
      note: "A wide recording that went without frames, its size kept with its part by acpmux: its box is its own shape from the first frame; the host's read only fills it with the poster.",
      props: {
        typed: "The plan list",
        screenshot: false,
        placed: true,
        frames: false,
        kept: true,
        video: { width: 1406, height: 434 },
      },
      chipHost: {
        videos: {
          [PATH]: {
            ...VIDEO_INFO,
            width: 1406,
            height: 434,
            // The host's poster is the recording's own shape; painted when the stage reads it.
            get poster() {
              return paintShot({ width: 320, height: 99, hue: 210 }, "image/jpeg");
            },
          },
        },
      },
      play: placedHolds,
    },
    "sent-video-half": {
      note: "The wide recording mid-text in a pane split in half (720px).",
      props: {
        typed: "The plan list",
        screenshot: false,
        placed: true,
        video: { width: 1406, height: 434 },
        after: "keeps its old items.",
        column: 720,
        held: true,
      },
      play: placedHolds,
    },
    "sent-video-third": {
      note: "The same in a pane split in thirds (480px): the tile scales down whole with the bubble.",
      props: {
        typed: "The plan list",
        screenshot: false,
        placed: true,
        video: { width: 1406, height: 434 },
        after: "keeps its old items.",
        column: 480,
        held: true,
      },
      play: placedHolds,
    },
    "sent-video-quarter": {
      note: "The same in a pane split in quarters (360px): a short wide tile, its play glyph scaled to it.",
      props: {
        typed: "The plan list",
        screenshot: false,
        placed: true,
        video: { width: 1406, height: 434 },
        after: "keeps its old items.",
        column: 360,
        held: true,
      },
      play: placedHolds,
    },
  },
});
