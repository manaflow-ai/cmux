// The videos a sent prompt carried, read back from what it sent the agent (Leo, 2026-10-25: "also
// why dont we have previews of videos we should"): each video's frames note (composer/videoPrompt.ts
// `framesNote`) gives its name, length and size, its link its path, and its first frame image its
// poster. acpmux keeps all three through a reload and a fork, so the bubble's tile comes back with
// them. A video the agent got no frames for (its read failed or timed out, a chat on another
// machine, an agent that takes no images, a prompt past its budget) has no note, but it is still a
// video: it is the same tile, square while its size is unknown, its poster read from the file when
// the host can (SentVideoTile.tsx), never a file chip (Leo, 2026-11-06: "how come this didn't give
// a preview and only has file name?"; 2026-10-26: "We know it's a video. ... Just do the square.").
import type { AcpmuxRow, PromptContentPart, PromptImage } from "../model";
import type { ComposerAttachment } from "../attachments";
import { attachmentPath } from "../fileAttachmentModel";
import { lengthOf } from "../composer/videoPrompt";
import { isVideoName } from "../composer/videoAttachments";
import { localDraftShape } from "../composer/draftMediaShape";
import { chipVideoRatio } from "../composer/videoShape";

/// A video a prompt sent, as its bubble draws it (SentVideoTile.tsx).
export type SentVideo = {
  name: string;
  path: string;
  /// `m:ss` or `h:mm:ss`, as the note says it; unset for a video sent without frames until its
  /// tile reads it.
  length?: string;
  width?: number;
  height?: number;
  /// Its tile's width over height as the composer's chip drew it (composer/videoShape.ts): the sent
  /// tile keeps that box. Unset for one read back from acpmux alone: its size's.
  shape?: number;
  /// Its first frame, the image the prompt sent it as; before acpmux's echo, the composer chip's poster.
  poster?: PromptImage;
};

const NOTE_HEAD = /^Frames from the video (.+) \((\d+(?::\d{2}){1,2}), (\d+)×(\d+)\), in order, at: /;

/// The videos `row` sent, in the order their notes come, then those that went without frames. Read
/// from the row as acpmux recorded it, before the bubble leaves the notes and frames out
/// (`withoutVideoFrames`).
export function sentVideosOf(
  row: Pick<AcpmuxRow, "text" | "images" | "inlineParts" | "retryAttachments">,
): SentVideo[] {
  // The pane's own send, before acpmux's echo: the row keeps the chips it sent (direct.ts), and a
  // video is its tile from the first frame, its poster the chip's, so the echo changes nothing on
  // screen (Leo, 2026-11-07: "know beforehand the size we're going to go for"; "it just sort of
  // needs to readjust and pop up for the video preview").
  const chips = composerVideos(row);
  if (chips.length && chips.every((chip) => chip.poster)) return chips;
  const lines = [
    ...(row.text?.split("\n") ?? []),
    ...(row.inlineParts ?? []).flatMap((part) => (part.kind === "text" ? part.text.split("\n") : [])),
  ];
  const images: PromptImage[] = [
    ...(row.images ?? []),
    ...(row.inlineParts ?? []).filter((part): part is PromptContentPart & PromptImage => part.kind === "image"),
  ];
  const seen = new Set<string>();
  const framed = lines.flatMap((line): SentVideo[] => {
    if (!line.startsWith("Frames from the video ")) return [];
    const note = NOTE_HEAD.exec(line);
    const name = note?.[1];
    if (!note || !name || seen.has(name)) return [];
    const path = videoPath(row, name);
    if (!path) return [];
    seen.add(name);
    const poster = images.find((image) => image.name?.startsWith(`${name} frame at `));
    return [
      {
        name,
        path,
        length: note[2]!,
        width: Number(note[3]),
        height: Number(note[4]),
        ...(poster ? { poster } : {}),
      },
    ];
  });
  // acpmux's record of a video that went as its link alone: its file part, a movie by its type or name.
  // Every file part is a video of its own path: the same recording attached twice went as two
  // uploads, one name at two paths, and only the first had a tile while the second drew as a
  // "Screen Recording ... .mov 179.9 MB" file chip under it (Leo, 2026-11-22: "what is this situation
  // with these attachments"). A copy takes its note's poster and length: one note names them both.
  const found = [...framed];
  const bare = (row.inlineParts ?? []).flatMap((part): SentVideo[] => {
    if (part.kind !== "file" || !isVideoFile(part.name, part.mimeType)) return [];
    const path = attachmentPath(part.uri);
    if (!path || found.some((video) => video.name === part.name && video.path === path)) return [];
    const note = framed.find((video) => video.name === part.name);
    // Its size: its note's, else what acpmux kept with its part (the pane sends it,
    // hub/prompt_images.rs), else the host's read of its file this page made (`noteVideoSize`), so its
    // tile has its box at once.
    const size =
      note?.width && note.height
        ? undefined
        : part.width && part.height
          ? { width: part.width, height: part.height }
          : readSizes.get(path);
    const video = { ...(note ?? { name: part.name }), ...size, path };
    found.push(video);
    return [video];
  });
  if (!chips.length) return [...framed, ...bare];
  // A chip the host never read takes what its note says, when it went with frames all the same; a
  // second copy of one recording (another path, the same name) takes it too.
  return chips.map((chip) => {
    const note =
      !chip.poster &&
      (framed.find((video) => video.name === chip.name && video.path === chip.path) ??
        framed.find((video) => video.name === chip.name));
    // Its note's poster and length, in the box its chip had, at its own path.
    return note ? { ...note, path: chip.path, ...(chip.shape ? { shape: chip.shape } : {}) } : chip;
  });
}

/// The videos the pane's own row sent, read from the composer's chips (their poster, length and
/// size, composer/videoAttachments.ts): the row the pane draws the moment it sends has no frames
/// note (its text is what the bubble reads). A chip the host could not read, or whose frames were
/// left off (`withoutFrames`), is still its tile, with what the chip knows.
function composerVideos(row: Pick<AcpmuxRow, "retryAttachments">): SentVideo[] {
  // The same recording attached twice is one video (`withoutRepeatedVideos`).
  const seen = new Set<string>();
  const once = (chip: ComposerAttachment) => {
    const key = `${chip.name}\n${chip.size}`;
    return !seen.has(key) && Boolean(seen.add(key));
  };
  return (row.retryAttachments ?? []).flatMap((chip): SentVideo[] => {
    if (chip.kind !== "link" || !chip.path || !isVideoFile(chip.path, chip.mimeType) || !once(chip)) return [];
    const shape =
      chip[localDraftShape]?.forSend() ?? (chip.videoShape || chip.video ? chipVideoRatio(chip) : undefined);
    return [
      {
        name: chip.name,
        path: chip.path,
        ...(chip.video ? chipVideo(chip, chip.video) : {}),
        ...(shape ? { shape } : {}),
      },
    ];
  });
}

function chipVideo(chip: ComposerAttachment, video: NonNullable<ComposerAttachment["video"]>): Partial<SentVideo> {
  return {
    length: lengthOf(video.durationMs),
    width: video.width,
    height: video.height,
    poster: { id: `${chip.id}:poster`, mimeType: "image/jpeg", src: video.poster },
  };
}

/// Whether a sent file is a video: its type says so, or its name is a movie's the host reads.
function isVideoFile(name: string, mimeType: string | undefined): boolean {
  return Boolean(mimeType?.startsWith("video/")) || isVideoName(name);
}

/// The path of the video `name` a row sent: its link part (acpmux's record), or before the echo
/// the composer's chip.
function videoPath(row: Pick<AcpmuxRow, "inlineParts" | "retryAttachments">, name: string): string | undefined {
  for (const part of row.inlineParts ?? [])
    if (part.kind === "file" && part.name === name && part.uri) {
      const path = attachmentPath(part.uri);
      if (path) return path;
    }
  for (const chip of row.retryAttachments ?? [])
    if (chip.kind === "link" && chip.name === name && chip.path) return chip.path;
  return undefined;
}

/// Whether a recorded file part is one of `videos`: the tile draws it, not a file chip. By its
/// path, else by its name: the same recording attached a second time goes as a second upload of it
/// (another path), and it is still that video, never a file chip beside its tile (Leo, 2026-11-22:
/// "WHAT THE FUCK IS THIS SITUATION MAN WITH THESE ATTACHMENTS!?").
export function sentVideoOf(
  part: Exclude<PromptContentPart, { kind: "text" | "image" }>,
  videos: readonly SentVideo[],
): SentVideo | undefined {
  if (part.kind !== "file" || !part.uri) return undefined;
  return sentVideoFor({ name: part.name, path: attachmentPath(part.uri) }, videos);
}

/// The video of `videos` a file of `name` at `path` is (`sentVideoOf`): the one at its path, else
/// the one of its name.
export function sentVideoFor(
  file: { name: string; path?: string },
  videos: readonly SentVideo[],
): SentVideo | undefined {
  return (
    videos.find((video) => video.name === file.name && video.path === file.path) ??
    videos.find((video) => video.name === file.name)
  );
}

/// `parts` with each video once: a second part that is a video already drawn (the same recording
/// attached again: its name and size, whichever upload of it the part names) draws nothing, so one
/// video is one tile. UserBubble.tsx draws these and the row's estimate (bubbleParts.ts
/// `bubbleLayout`) measures them.
export function withoutRepeatedVideos<T extends PromptContentPart>(
  parts: readonly T[],
  videos: readonly SentVideo[],
): T[] {
  const drawn = new Set<string>();
  return parts.filter((given) => {
    const part: PromptContentPart = given;
    if (part.kind === "text" || part.kind === "image") return true;
    const video = sentVideoOf(part, videos);
    if (!video) return true;
    const key = `${video.name}\n${part.size ?? ""}`;
    if (drawn.has(key)) return false;
    drawn.add(key);
    return true;
  });
}

/// The sizes the host read of videos sent without frames (SentVideoTile.tsx `video.info`), by path:
/// a tile drawn again, and the row's estimate (model.ts), take the box the read gave from the first
/// frame. The most recent READ_SIZES_KEPT are kept.
const readSizes = new Map<string, { width: number; height: number }>();
const READ_SIZES_KEPT = 256;

/// Keeps the size the host read of the video at `path`.
export function noteVideoSize(path: string, size: { width: number; height: number }): void {
  readSizes.delete(path);
  readSizes.set(path, { width: size.width, height: size.height });
  if (readSizes.size > READ_SIZES_KEPT) readSizes.delete(readSizes.keys().next().value!);
}
