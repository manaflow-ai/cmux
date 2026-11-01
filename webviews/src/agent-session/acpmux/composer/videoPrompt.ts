// What an agent gets for an attached video: its link, then a note naming the video and the time of
// each frame, then the frames as image blocks in that order (Leo, 2026-11-01, after a 16 s mp4 went
// to Claude Code as its path alone and the agent ran ffmpeg to see it: "i feel like cmux-next should
// give u better tools to deal with this kind of thing"). An agent cannot watch a video; the frames
// the host read on attach (`video.info`, videoAttachments.ts) are what it looks at. The note and the
// frames are for the agent: the sent bubble draws the video's own tile, never them
// (`withoutVideoFrames`), before acpmux's echo and after a reload alike.
import type { ComposerAttachment, PromptBlock } from "../attachments";
import type { PromptContentPart, PromptImage } from "../model";

/// A time in a video as the note and each frame's name say it: `m:ss.d`, or `h:mm:ss.d` from an hour.
export function frameTime(ms: number): string {
  const tenths = Math.max(0, Math.round(ms / 100));
  const h = Math.floor(tenths / 36_000);
  const m = Math.floor((tenths % 36_000) / 600);
  const s = (tenths % 600) / 10;
  const ss = s.toFixed(1).padStart(4, "0");
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${ss}` : `${m}:${ss}`;
}

/// A video's length as the note says it: `m:ss`, or `h:mm:ss`.
function lengthOf(ms: number): string {
  const total = Math.max(1, Math.round(ms / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = String(total % 60).padStart(2, "0");
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${s}` : `${m}:${s}`;
}

/// The name of a frame's image block: the video's name and the frame's time. The bubble knows a
/// frame by it (`isVideoFrameName`); acpmux keeps it with the image (prompt_images.rs `decode`).
export function frameName(video: string, atMs: number): string {
  return `${video} frame at ${frameTime(atMs)}`;
}

const FRAME_NAME = /\.(mov|mp4|m4v) frame at \d+(:\d{2}){1,2}\.\d$/i;
/// Whether `name` is a video frame's image block name (`frameName`).
export function isVideoFrameName(name: string | undefined): boolean {
  return typeof name === "string" && FRAME_NAME.test(name);
}

/// The note that comes before a video's frames: one line, so the bubble can leave it out whole.
export function framesNote(video: string, durationMs: number, width: number, height: number, times: number[]) {
  // l10n-allow: text for the agent, sent in the prompt, not UI.
  const at = times.map(frameTime).join(", ");
  return `Frames from the video ${video} (${lengthOf(durationMs)}, ${width}×${height}), in order, at: ${at}.`;
}

const NOTE = /^Frames from the video .+ \(\d[\d:]*, \d+×\d+\), in order, at: \d[\d:., ]*\.$/;
/// Whether `text` is a video's frames note (`framesNote`).
export function isFramesNote(text: string): boolean {
  return NOTE.test(text);
}

/// The blocks that go after a video link chip's resource_link: its frames note and its frames.
/// Nothing for any other chip, or a video whose frames were not read.
export function videoFrameBlocks(attachment: ComposerAttachment): PromptBlock[] {
  const video = attachment.kind === "link" ? attachment.video : undefined;
  if (!video?.frames.length) return [];
  return [
    {
      type: "text",
      text: framesNote(
        attachment.name,
        video.durationMs,
        video.width,
        video.height,
        video.frames.map((frame) => frame.atMs),
      ),
    },
    ...video.frames.map(
      (frame): PromptBlock => ({
        type: "image",
        mimeType: "image/jpeg",
        data: frame.data,
        name: frameName(attachment.name, frame.atMs),
      }),
    ),
  ];
}

/// `chips` without their videos' frames: for an agent that takes no images, and for a prompt too
/// large for one acpmux message once its previews went as links (promptBudget.ts).
export function withoutFrames(chips: ComposerAttachment[]): ComposerAttachment[] {
  if (!chips.some((chip) => chip.video?.frames.length)) return chips;
  return chips.map((chip) => (chip.video?.frames.length ? { ...chip, video: { ...chip.video, frames: [] } } : chip));
}

/// A sent prompt's row without its videos' frames and frames notes, which went to the agent only:
/// its images, its recorded parts, and the trailing note lines of its text (a strip prompt's
/// attachments, and so their notes, come after its text and pastes, so no paste range moves).
export function withoutVideoFrames<
  Row extends { text?: string; images?: PromptImage[]; inlineParts?: PromptContentPart[] },
>(row: Row): Row {
  const images = row.images?.filter((image) => !isVideoFrameName(image.name));
  const parts = row.inlineParts?.filter((part) =>
    part.kind === "image" ? !isVideoFrameName(part.name) : !(part.kind === "text" && isFramesNote(part.text)),
  );
  const text = row.text === undefined ? undefined : withoutFramesNotes(row.text);
  if (images?.length === row.images?.length && parts?.length === row.inlineParts?.length && text === row.text)
    return row;
  return {
    ...row,
    ...(row.images ? { images } : {}),
    ...(row.inlineParts ? { inlineParts: parts } : {}),
    ...(text !== undefined ? { text } : {}),
  };
}

/// `text` without the frames notes on its last lines.
export function withoutFramesNotes(text: string): string {
  const lines = text.split("\n");
  let end = lines.length;
  while (end > 0 && isFramesNote(lines[end - 1]!)) end -= 1;
  return end === lines.length ? text : lines.slice(0, end).join("\n").replace(/\n+$/, "");
}
