// What an agent gets for an attached video: its link, then a note naming the video and the time of
// each frame, then each frame as a one-line label with its time (and whether a scene starts there)
// and its image block (Leo, 2026-11-01, after a 16 s mp4 went
// to Claude Code as its path alone and the agent ran ffmpeg to see it: "i feel like cmux-next should
// give u better tools to deal with this kind of thing"). An agent cannot watch a video; the frames
// the host read on attach (`video.info`, videoAttachments.ts) are what it looks at. The note and the
// frames are for the agent: the sent bubble draws the video's own tile, never them
// (`withoutVideoFrames`), before acpmux's echo and after a reload alike.
import type { ComposerAttachment, PromptBlock } from "../attachments";
import type { PromptContentPart, PromptImage } from "../model";
import type { VideoFrame, VideoInfo } from "./videoAttachments";

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
  // l10n-allow: an image block's name for the agent (prompt_images.rs), matched by FRAME_NAME, not UI.
  return `${video} frame at ${frameTime(atMs)}`;
}

const FRAME_NAME = /\.(mov|mp4|m4v) frame at \d+(:\d{2}){1,2}\.\d$/i;
/// Whether `name` is a video frame's image block name (`frameName`).
export function isVideoFrameName(name: string | undefined): boolean {
  return typeof name === "string" && FRAME_NAME.test(name);
}

/// The label that goes before a frame's image: its name, and where a scene starts, so.
export function frameLabel(video: string, atMs: number, scene: boolean): string {
  // l10n-allow: text for the agent, sent in the prompt, not UI.
  return scene ? `${frameName(video, atMs)} (new scene)` : frameName(video, atMs);
}

/// A `m:ss[.d]` or `h:mm:ss[.d]` time in milliseconds, or undefined.
function timeMs(text: string): number | undefined {
  const parts = text.split(":").map(Number);
  if (parts.length < 2 || parts.length > 3 || parts.some((part) => !Number.isFinite(part))) return undefined;
  return Math.round(parts.reduce((total, part) => total * 60 + part, 0) * 1000);
}

/// The video a sent prompt's saved frames make again (for Retry and Edit after a reload, whose file
/// part keeps no `video`): its frames note (`framesNote`) gives its length and size, each frame's
/// image name (`frameName`) its time, and its label whether a scene starts there. Undefined without
/// the note or a frame.
export function videoFromFrames(
  note: string | undefined,
  frames: readonly { name: string; data: string; scene: boolean }[],
): VideoInfo | undefined {
  const head = note?.match(/^Frames from the video .+ \((\d[\d:]*), (\d+)×(\d+)\), in order, at: /);
  const durationMs = head ? timeMs(head[1]!) : undefined;
  if (!head || durationMs === undefined) return undefined;
  const kept = frames.flatMap((frame): VideoFrame[] => {
    const at = frame.name.match(/ frame at (\d+(?::\d{2}){1,2}\.\d)$/);
    const atMs = at ? timeMs(at[1]!) : undefined;
    return atMs === undefined ? [] : [{ atMs, data: frame.data, ...(frame.scene ? { scene: true as const } : {}) }];
  });
  if (!kept.length) return undefined;
  return {
    durationMs,
    width: Number(head[2]),
    height: Number(head[3]),
    poster: `data:image/jpeg;base64,${kept[0]!.data}`,
    frames: kept,
  };
}

/// A matcher for the text a prompt carried for the agent only, given the names of the prompt's images:
/// a frames note of a video whose frames it carries, and the label of each such frame (its image's
/// name, with or without "(new scene)"). Text only like one, with no such frame image in the prompt,
/// is the person's own and stays.
export type FrameText = (text: string) => boolean;
export function frameTextOf(names: Iterable<string | undefined>): FrameText {
  const labels = new Set<string>();
  const notes: string[] = [];
  for (const name of names) {
    if (!isVideoFrameName(name)) continue;
    labels.add(name!).add(`${name} (new scene)`);
    const video = name!.replace(/ frame at [\d:.]+$/, "");
    // l10n-allow: matches framesNote's text for the agent, not UI.
    notes.push(`Frames from the video ${video} (`);
  }
  if (!labels.size) return () => false;
  return (text) => labels.has(text) || (isFramesNote(text) && notes.some((head) => text.startsWith(head)));
}

/// The names of the images in `blocks` (a prompt's), for `frameTextOf`.
export function imageNames(blocks: readonly PromptBlock[]): (string | undefined)[] {
  return blocks.flatMap((block) => (block.type === "image" ? [block.name] : []));
}

/// The names of a row's images and image parts, for `frameTextOf`.
export function rowImageNames(row: {
  images?: readonly { name?: string }[];
  inlineParts?: readonly PromptContentPart[];
}): (string | undefined)[] {
  return [
    ...(row.images ?? []).map((image) => image.name),
    ...(row.inlineParts ?? []).flatMap((part) => (part.kind === "image" ? [part.name] : [])),
  ];
}

/// The note that comes before a video's frames: one line, so the bubble can leave it out whole.
export function framesNote(video: string, durationMs: number, width: number, height: number, times: number[]) {
  const at = times.map(frameTime).join(", ");
  // l10n-allow: text for the agent, sent in the prompt, not UI.
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
    ...video.frames.flatMap((frame): PromptBlock[] => [
      { type: "text", text: frameLabel(attachment.name, frame.atMs, frame.scene === true) },
      { type: "image", mimeType: "image/jpeg", data: frame.data, name: frameName(attachment.name, frame.atMs) },
    ]),
  ];
}

/// `chips` without their videos' frames: for an agent that takes no images, and for a prompt too
/// large for one acpmux message once its previews went as links (promptBudget.ts).
export function withoutFrames(chips: ComposerAttachment[]): ComposerAttachment[] {
  if (!chips.some((chip) => chip.video?.frames.length)) return chips;
  return chips.map((chip) => (chip.video?.frames.length ? { ...chip, video: { ...chip.video, frames: [] } } : chip));
}

/// A sent prompt's row without its videos' frames, frames notes and frame labels, which went to the
/// agent only: its images, its recorded parts, and the note and label lines of its text. With paste
/// ranges only its last lines go (a strip prompt's attachments, and so their notes, come after its
/// text and pastes, so no range moves); without, every such line goes (a video placed mid-text).
export function withoutVideoFrames<
  Row extends { text?: string; images?: PromptImage[]; inlineParts?: PromptContentPart[]; pasted?: unknown[] },
>(row: Row): Row {
  const isFrame = frameTextOf(rowImageNames(row));
  const images = row.images?.filter((image) => !isVideoFrameName(image.name));
  const parts = row.inlineParts?.filter((part) =>
    part.kind === "image" ? !isVideoFrameName(part.name) : !(part.kind === "text" && isFrame(part.text)),
  );
  const text = row.text === undefined ? undefined : withoutFramesNotes(row.text, isFrame, !row.pasted?.length);
  if (images?.length === row.images?.length && parts?.length === row.inlineParts?.length && text === row.text)
    return row;
  return {
    ...row,
    ...(row.images ? { images } : {}),
    ...(row.inlineParts ? { inlineParts: parts } : {}),
    ...(text !== undefined ? { text } : {}),
  };
}

/// `text` without the frames notes and frame labels (`isFrame`, from `frameTextOf`) on its last lines,
/// or on any line (`anywhere`).
export function withoutFramesNotes(text: string, isFrame: FrameText, anywhere = false): string {
  const lines = text.split("\n");
  if (anywhere) {
    const kept = lines.filter((line) => !isFrame(line));
    return kept.length === lines.length ? text : kept.join("\n").replace(/\n{3,}/g, "\n\n").replace(/\n+$/, "");
  }
  let end = lines.length;
  while (end > 0 && isFrame(lines[end - 1]!)) end -= 1;
  return end === lines.length ? text : lines.slice(0, end).join("\n").replace(/\n+$/, "");
}
