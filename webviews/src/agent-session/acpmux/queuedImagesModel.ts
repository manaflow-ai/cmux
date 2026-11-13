import type { QueuedPromptImage } from "./model";
import { isVideoFrameName } from "./composer/videoPrompt";

/// The most tiles a row draws when not edited: past it, the last place is "+N".
export const QUEUED_TILES_SHOWN = 6;

/// One tile of a queued prompt: an image, or a video with every frame of it the prompt carries.
export type QueuedTile =
  | { kind: "image"; image: QueuedPromptImage }
  | { kind: "video"; name: string; poster: QueuedPromptImage; ids: string[]; durationMs?: number };

/// One video the prompt carries, as its file part says (`video`): its name, length and how many
/// frames it sent, for its tile.
export type QueuedVideo = { name: string; durationMs?: number; frames?: number };

/// `images` as tiles, in order: a video's frames go in one tile, at its first frame. A video's frames
/// come together and in time order (composer/videoPrompt.ts `videoFrameBlocks`), so a frame joins
/// the tile just before it when that tile is its video's and has frames left. `videos`, the prompt's
/// videos in order, gives each tile its own video's length and frame count, so two videos of one
/// name stay two tiles even when the times go on across them; a video the parts don't describe (a
/// record from before a reload) ends where the time stops going on or passes its length (a frame's name rounds it to a tenth).
export function queuedTiles(images: readonly QueuedPromptImage[], videos?: readonly QueuedVideo[]): QueuedTile[] {
  const tiles: QueuedTile[] = [];
  const unused = [...(videos ?? [])];
  let lastAt = -1;
  let left: number | undefined;
  let lengthMs: number | undefined;
  for (const image of images) {
    const frame = isVideoFrameName(image.name) ? image.name!.match(/^(.+) frame at ([\d:.]+)$/) : null;
    if (!frame) {
      tiles.push({ kind: "image", image });
      continue;
    }
    const name = frame[1]!;
    const at = frame[2]!.split(":").reduce((total, part) => total * 60 + Number(part), 0);
    const last = tiles.at(-1);
    const goesOn =
      left === undefined ? at > lastAt && (lengthMs === undefined || at * 1000 <= lengthMs + 50) : left > 0;
    if (last?.kind === "video" && last.name === name && goesOn) {
      last.ids.push(image.id);
      if (left !== undefined) left--;
    } else {
      const index = unused.findIndex((video) => video.name === name);
      const video = index < 0 ? undefined : unused.splice(index, 1)[0];
      const durationMs = video?.durationMs;
      tiles.push({ kind: "video", name, poster: image, ids: [image.id], ...(durationMs ? { durationMs } : {}) });
      left = video?.frames ? video.frames - 1 : undefined;
      lengthMs = durationMs;
    }
    lastAt = at;
  }
  return tiles;
}
