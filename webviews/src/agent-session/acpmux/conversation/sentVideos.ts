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
  const bare = (row.inlineParts ?? []).flatMap((part): SentVideo[] => {
    if (part.kind !== "file" || seen.has(part.name) || !isVideoFile(part.name, part.mimeType)) return [];
    const path = attachmentPath(part.uri);
    if (!path) return [];
    seen.add(part.name);
    return [{ name: part.name, path }];
  });
  if (!chips.length) return [...framed, ...bare];
  // A chip the host never read takes what its note says, when it went with frames all the same.
  return chips.map((chip) => {
    const note = !chip.poster && framed.find((video) => video.name === chip.name && video.path === chip.path);
    // Its note's poster and length, in the box its chip had.
    return note ? { ...note, ...(chip.shape ? { shape: chip.shape } : {}) } : chip;
  });
}

/// The videos the pane's own row sent, read from the composer's chips (their poster, length and
/// size, composer/videoAttachments.ts): the row the pane draws the moment it sends has no frames
/// note (its text is what the bubble reads). A chip the host could not read, or whose frames were
/// left off (`withoutFrames`), is still its tile, with what the chip knows.
function composerVideos(row: Pick<AcpmuxRow, "retryAttachments">): SentVideo[] {
  return (row.retryAttachments ?? []).flatMap((chip): SentVideo[] =>
    chip.kind === "link" && chip.path && isVideoFile(chip.path, chip.mimeType)
      ? [
          {
            name: chip.name,
            path: chip.path,
            ...(chip.video ? chipVideo(chip, chip.video) : {}),
            ...(chip.videoShape || chip.video ? { shape: chipVideoRatio(chip) } : {}),
          },
        ]
      : [],
  );
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

/// Whether a recorded file part is one of `videos`: the tile draws it, not a file chip.
export function sentVideoOf(
  part: Exclude<PromptContentPart, { kind: "text" | "image" }>,
  videos: readonly SentVideo[],
): SentVideo | undefined {
  if (part.kind !== "file" || !part.uri) return undefined;
  const path = attachmentPath(part.uri);
  return videos.find((video) => video.name === part.name && video.path === path);
}
