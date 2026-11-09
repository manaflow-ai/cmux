// The videos a sent prompt carried, read back from what it sent the agent (Leo, 2026-10-25: "also
// why dont we have previews of videos we should"): each video's frames note (composer/videoPrompt.ts
// `framesNote`) gives its name, length and size, its link its path, and its first frame image its
// poster. acpmux keeps all three through a reload and a fork, so the bubble's tile comes back with
// them. A video the agent got no frames for (its read failed, or the agent takes no images) has no
// note and stays the file chip it was.
import type { AcpmuxRow, PromptContentPart, PromptImage } from "../model";
import { attachmentPath } from "../fileAttachmentModel";
import { lengthOf } from "../composer/videoPrompt";

/// A video a prompt sent, as its bubble draws it (SentVideoTile.tsx).
export type SentVideo = {
  name: string;
  path: string;
  /// `m:ss` or `h:mm:ss`, as the note says it.
  length: string;
  width: number;
  height: number;
  /// Its first frame, the image the prompt sent it as; before acpmux's echo, the composer chip's poster.
  poster?: PromptImage;
};

const NOTE_HEAD = /^Frames from the video (.+) \((\d+(?::\d{2}){1,2}), (\d+)×(\d+)\), in order, at: /;

/// The videos `row` sent with their frames, in the order their notes come. Read from the row as
/// acpmux recorded it, before the bubble leaves the notes and frames out (`withoutVideoFrames`).
export function sentVideosOf(
  row: Pick<AcpmuxRow, "text" | "images" | "inlineParts" | "retryAttachments">,
): SentVideo[] {
  // The pane's own send, before acpmux's echo: the row keeps the chips it sent (direct.ts), and a
  // video that went with its frames is its tile from the first frame, its poster the chip's, so the
  // echo changes nothing on screen (Leo, 2026-11-07: "know beforehand the size we're going to go for").
  const sent = (row.retryAttachments ?? []).flatMap((chip): SentVideo[] =>
    chip.kind === "link" && chip.path && chip.video?.frames.length
      ? [
          {
            name: chip.name,
            path: chip.path,
            length: lengthOf(chip.video.durationMs),
            width: chip.video.width,
            height: chip.video.height,
            poster: { id: `${chip.id}:poster`, mimeType: "image/jpeg", src: chip.video.poster },
          },
        ]
      : [],
  );
  if (sent.length) return sent;
  const lines = [
    ...(row.text?.split("\n") ?? []),
    ...(row.inlineParts ?? []).flatMap((part) => (part.kind === "text" ? part.text.split("\n") : [])),
  ];
  const chips = composerVideos(row);
  if (!lines.some((line) => line.startsWith("Frames from the video "))) return chips;
  const images: PromptImage[] = [
    ...(row.images ?? []),
    ...(row.inlineParts ?? []).filter((part): part is PromptContentPart & PromptImage => part.kind === "image"),
  ];
  const seen = new Set<string>();
  return lines.flatMap((line): SentVideo[] => {
    const note = NOTE_HEAD.exec(line);
    const name = note?.[1];
    if (!note || !name || seen.has(name)) return [];
    const path = videoPath(row, name);
    if (!path) return [];
    seen.add(name);
    // The composer's own poster bytes while it has them, so the tile the prompt landed with keeps
    // its picture through acpmux's echo instead of waiting on a read of its first frame.
    const poster =
      chips.find((chip) => chip.name === name && chip.path === path)?.poster ??
      images.find((image) => image.name?.startsWith(`${name} frame at `));
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
}

/// The videos the pane's own row sent, read from the composer's chips (their poster, length and
/// size, composer/videoAttachments.ts): the row the pane draws the moment it sends has no frames
/// note (its text is what the bubble reads), so without them the tile popped in only with acpmux's
/// echo (Leo, 2026-11-07: "it just sort of needs to readjust and pop up for the video preview").
/// A chip whose frames were left off (`withoutFrames`: an agent that takes no images, or a prompt
/// past its budget) sent the agent only its link, so it stays the file chip its echo draws.
function composerVideos(row: Pick<AcpmuxRow, "retryAttachments">): SentVideo[] {
  return (row.retryAttachments ?? []).flatMap((chip): SentVideo[] =>
    chip.kind === "link" && chip.path && chip.video?.frames.length
      ? [
          {
            name: chip.name,
            path: chip.path,
            length: lengthOf(chip.video.durationMs),
            width: chip.video.width,
            height: chip.video.height,
            poster: { id: `${chip.id}:poster`, mimeType: "image/jpeg", src: chip.video.poster },
          },
        ]
      : [],
  );
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
