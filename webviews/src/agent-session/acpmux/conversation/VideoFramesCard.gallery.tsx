// l10n-allow-file: gallery fixtures (a sample video path, its note and painted frames), not shipped UI.
// A `video_frames` call, folded from the ACP updates acpmux sends (mergeToolItem, as the pane folds
// them): Claude Code's `mcp__cmux__video_frames` with the video's path, then its completion, one
// image block per frame and a text block naming the video's length, size and each frame's time.
// The row draws a filmstrip card instead of the call's raw response (Leo, 2026-11-01: "i feel like
// cmux-next should give u better tools to deal with this kind of thing"). `strip` is the
// transcript's; `grid` (a contact sheet) and `poster` (the first frame large, the rest under it)
// are its alternatives.
import { useMemo } from "react";
import { componentEntry } from "../../../gallery/format";
import { mergeToolItem, textFromContent } from "../direct";
import { ImageViewerContext } from "./imageViewerContext";
import type { McpCallRows as McpCallRowsComponent } from "./McpCallRows";
import type { VideoFramesLayout, VideoFramesLayoutContext as LayoutContext } from "./VideoFramesCard";

type Props = { layout: VideoFramesLayout; frames: number; named: boolean };

const path = "/Users/demo/Library/Application Support/cmux/Chat Uploads/screen-recording-sidebar.mp4";
const durationMs = 16_400;

/// A screen-recording-like frame: a window whose sidebar selection and progress move with time.
function paint(index: number, count: number): string {
  const [width, height] = [640, 360];
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ink = canvas.getContext("2d")!;
  const progress = count > 1 ? index / (count - 1) : 0;
  ink.fillStyle = `hsl(${220 + progress * 40} 22% 95%)`;
  ink.fillRect(0, 0, width, height);
  ink.fillStyle = "hsl(220 14% 86%)";
  ink.fillRect(0, 0, width, 28);
  ink.fillRect(0, 0, 150, height);
  ink.fillStyle = "hsl(220 60% 56%)";
  ink.fillRect(8, 44 + Math.round(progress * 6) * 34, 134, 24);
  ink.fillStyle = "hsl(220 12% 70%)";
  for (let line = 0; line < 7; line += 1) ink.fillRect(176, 56 + line * 30, 180 + ((line * 61 + index * 23) % 240), 10);
  ink.fillStyle = "hsl(150 45% 46%)";
  ink.fillRect(176, height - 40, Math.max(12, (width - 200) * progress), 10);
  return canvas.toDataURL("image/jpeg", 0.8);
}

function frameTime(ms: number): string {
  const tenths = Math.round(ms / 100);
  const m = Math.floor(tenths / 600);
  const s = ((tenths % 600) / 10).toFixed(1).padStart(4, "0");
  return `${m}:${s}`;
}

/// The call as the pane folds it from its ACP updates: the call, then its completion.
function framesItem(count: number, named: boolean) {
  const id = "gallery-video-frames";
  const call = mergeToolItem(
    undefined,
    {
      sessionUpdate: "tool_call",
      toolCallId: id,
      title: "mcp__cmux__video_frames",
      kind: "other",
      status: "in_progress",
      rawInput: named ? { path, count } : { count },
    },
    id,
    "",
  );
  const times = Array.from({ length: count }, (_, index) => Math.round((index * durationMs) / count));
  const note = [
    ...(named ? [`Video: ${path}`] : []),
    `Duration: ${frameTime(durationMs)} (16.4 s), 1920x1080, 30 fps`,
    `${count} frames:`,
    ...times.map((ms, index) => `${index + 1}. ${frameTime(ms)}`),
  ].join("\n");
  const images = times.map((_, index) => {
    const data = paint(index, count);
    return {
      type: "content",
      content: { type: "image", mimeType: "image/jpeg", data: data.slice(data.indexOf(",") + 1) },
    };
  });
  const content = [{ type: "content", content: { type: "text", text: note } }, ...images];
  // The pane passes the update's text as the call's output (direct.ts), its images as its images.
  return mergeToolItem(
    call,
    { sessionUpdate: "tool_call_update", toolCallId: id, status: "completed", content },
    id,
    textFromContent(content),
  );
}

/// The row as the pane draws it.
function galleryVideoFrames(McpCallRows: typeof McpCallRowsComponent, Layout: typeof LayoutContext) {
  return function GalleryVideoFrames({ layout, frames, named }: Props) {
    const item = useMemo(() => framesItem(frames, named), [frames, named]);
    return (
      <ImageViewerContext.Provider value={() => {}}>
        <Layout.Provider value={layout}>
          <div style={{ padding: 16 }}>
            <McpCallRows items={[item]} disclosureKey="gallery:video-frames" />
          </div>
        </Layout.Provider>
      </ImageViewerContext.Provider>
    );
  };
}

export default componentEntry<Props>({
  id: "agent-pane.video-frames",
  title: "Video frames an agent looked at",
  area: "Agent pane",
  pane: true,
  height: 420,
  covers: [
    "agent-session/acpmux/conversation/VideoFramesCard.tsx#VideoFramesCard",
    "agent-session/acpmux/conversation/VideoFramesCard.tsx#VideoFramesLayoutContext",
  ],
  load: async () => {
    const [{ McpCallRows }, { VideoFramesLayoutContext }] = await Promise.all([
      import("./McpCallRows"),
      import("./VideoFramesCard"),
    ]);
    return galleryVideoFrames(McpCallRows, VideoFramesLayoutContext);
  },
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css"), import("../chips/chips.css")]),
  widths: { narrow: 420, normal: 720 },
  variants: {
    strip: {
      note: "The transcript's: the video's name (plays it) and length, then a filmstrip of its frames, each with its time; a frame opens large.",
      props: { layout: "strip", frames: 8, named: true },
    },
    grid: {
      note: "Alternative: the frames as a contact sheet that wraps to the pane's width.",
      props: { layout: "grid", frames: 8, named: true },
    },
    poster: {
      note: "Alternative: the first frame large, the rest in a strip under it, the name below.",
      props: { layout: "poster", frames: 8, named: true },
    },
    "strip-many": {
      note: "Sixteen frames: the strip scrolls sideways at the row's width instead of growing tall.",
      props: { layout: "strip", frames: 16, named: true },
    },
    "strip-unnamed": {
      note: "A call that named no file: the card draws its length and frames, with no name to play.",
      props: { layout: "strip", frames: 4, named: false },
    },
  },
});
