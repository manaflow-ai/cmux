// One shape for an attached video, from its paste to its sent message (Leo, 2026-11-10: "the preview
// placeholder boxes are incongruent between the initial load, then the second load, and the chat
// attachment itself. the calculations are not right"). The shape is the video's own width over
// height, held between VIDEO_RATIO's bounds, read once from the file's header when it is pasted,
// dropped or picked (a few small reads, never its media). The composer's loading tile, its chip with
// or without the poster, and the sent message's tile all draw that one shape, each at its own
// height; a video whose header gives no size is the square (Leo, 2026-10-26: "Just do the square").
// The host's read (`video.info`) only fills the box with the poster: it never sizes it.

/// The narrowest and widest a video's tile draws, as width over height: a tall phone recording or a
/// wide screen recording is cropped to fill past those bounds rather than drawn as a sliver.
export const VIDEO_RATIO = { min: 0.75, max: 1.6 } as const;

/// The tile's width over its height for a video of `size`: its own shape within VIDEO_RATIO, the
/// square while no size is known.
export function videoRatio(size: { width?: number; height?: number } | undefined): number {
  if (!size?.width || !size.height) return 1;
  return Math.min(VIDEO_RATIO.max, Math.max(VIDEO_RATIO.min, size.width / size.height));
}

/// A chip's tile shape, kept from the paste on (`ComposerAttachment.videoShape`); for a chip that came
/// without one (a draft read back with its video), its video's.
export function chipVideoRatio(chip: { videoShape?: number; video?: { width: number; height: number } }): number {
  return chip.videoShape ?? videoRatio(chip.video);
}

/// The style that gives a video's tile its shape: its CSS (composerAttachments.css, markdownField.css
/// `[data-video-shape]`) makes the width this ratio of the tile's height, wherever the tile is drawn.
export function videoShapeStyle(ratio: number | undefined): Record<string, string> {
  return { "--acpmux-video-ratio": String(ratio ?? 1) };
}

/// How long a pasted video's tile is held unseen for its header (as an image's is,
/// attachmentIntakeModel.ts HEADER_WAIT_MS): past it, the tile shows square.
export const VIDEO_HEADER_WAIT_MS = 120;

/// The most of a movie's metadata box read at once: `moov` of a long recording holds its sample
/// tables, but its track headers come first, so only their boxes are read.
const MAX_BOX_READ = 64 * 1024;

type Size = { width: number; height: number };

async function bytes(file: Blob, at: number, length: number): Promise<DataView> {
  return new DataView(await file.slice(at, at + length).arrayBuffer());
}

const kind = (view: DataView, at: number) =>
  String.fromCharCode(view.getUint8(at), view.getUint8(at + 1), view.getUint8(at + 2), view.getUint8(at + 3));

/// Each box in `file` from `start` to `end`: its type, where its body starts and where it ends. Reads
/// only the 16 bytes of each box's header.
async function* boxes(file: Blob, start: number, end: number) {
  let at = start;
  // A movie's top level has a handful of boxes and a track a few more: a bound against a corrupt file.
  for (let count = 0; at + 8 <= end && count < 64; count += 1) {
    const head = await bytes(file, at, 16);
    if (head.byteLength < 8) return;
    let size = head.getUint32(0);
    let body = at + 8;
    if (size === 1) {
      if (head.byteLength < 16) return;
      size = Number(head.getBigUint64(8));
      body = at + 16;
    } else if (size === 0) size = end - at;
    if (size < body - at || at + size > end) return;
    yield { type: kind(head, 4), body, end: at + size };
    at += size;
  }
}

/// The display size a track header (`tkhd`) gives: its width and height (16.16 fixed point) turned
/// by its matrix, so a phone recording held upright is tall. Undefined for a track with no picture.
function trackSize(view: DataView): Size | undefined {
  const version = view.getUint8(0);
  // The matrix and size follow the version's times: 32-bit in version 0, 64-bit in version 1.
  const matrix = version === 1 ? 52 : 40;
  if (view.byteLength < matrix + 44) return undefined;
  const width = view.getUint32(matrix + 36) / 65536;
  const height = view.getUint32(matrix + 40) / 65536;
  if (!(width > 0 && height > 0)) return undefined;
  // a and b of the matrix (16.16): a quarter turn has a = 0.
  const a = view.getInt32(matrix);
  const b = view.getInt32(matrix + 4);
  const turned = a === 0 && b !== 0;
  return turned ? { width: height, height: width } : { width, height };
}

/// The picture size of the movie `file` (QuickTime or MP4) from its track headers, wherever its
/// `moov` is (a screen recording writes it after its media): undefined for a file that is not one.
export async function videoHeaderSize(file: Blob): Promise<Size | undefined> {
  for await (const top of boxes(file, 0, file.size)) {
    if (top.type !== "moov") continue;
    for await (const trak of boxes(file, top.body, top.end)) {
      if (trak.type !== "trak") continue;
      for await (const box of boxes(file, trak.body, trak.end)) {
        if (box.type !== "tkhd") continue;
        const size = trackSize(await bytes(file, box.body, Math.min(MAX_BOX_READ, box.end - box.body)));
        if (size) return { width: Math.round(size.width), height: Math.round(size.height) };
        break;
      }
    }
    return undefined;
  }
  return undefined;
}

/// Each pasted file's one header read: the loading tile and the chip it becomes ask the same read.
const reads = new WeakMap<Blob, Promise<number | undefined>>();

/// The shape `file`'s tile takes from its first frame: its header's ratio (videoRatio) when the
/// header answers within VIDEO_HEADER_WAIT_MS, undefined after that (the tile is then square). Asked
/// again for the same file, the same answer: a late header never reshapes a tile already shown.
export function videoShapeOf(file: Blob): Promise<number | undefined> {
  let read = reads.get(file);
  if (!read) {
    read = new Promise<number | undefined>((resolve) => {
      // timeout: an unreadable file must not hold its tile unseen.
      const deadline = setTimeout(() => resolve(undefined), VIDEO_HEADER_WAIT_MS);
      void videoHeaderSize(file)
        .catch(() => undefined)
        .then((size) => {
          clearTimeout(deadline);
          resolve(size ? videoRatio(size) : undefined);
        });
    });
    reads.set(file, read);
  }
  return read;
}
