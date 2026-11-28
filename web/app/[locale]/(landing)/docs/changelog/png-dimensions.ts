import { closeSync, openSync, readSync } from "node:fs";
import { join } from "node:path";

// A PNG file starts with a fixed 8-byte signature, followed by the IHDR chunk:
// a 4-byte length, the 4-byte type "IHDR", then 13 data bytes whose first two
// big-endian uint32 fields are the pixel width and height (PNG spec, 11.2.2).
const SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] as const;
const IHDR_TYPE_OFFSET = SIGNATURE.length + 4;
const WIDTH_OFFSET = IHDR_TYPE_OFFSET + 4;
const HEIGHT_OFFSET = WIDTH_OFFSET + 4;
const PREFIX_LENGTH = HEIGHT_OFFSET + 4;

/**
 * Returns the pixel size of a PNG served from `public/`.
 *
 * `publicPath` is the URL path used on the site (for example
 * `/changelog/foo.png`). Only the file prefix up to the IHDR size fields is
 * read, so large screenshots are never loaded into memory.
 */
export function pngDimensions(publicPath: string): { width: number; height: number } {
  const header = readPrefix(join(process.cwd(), "public", publicPath), PREFIX_LENGTH);
  if (header.length < PREFIX_LENGTH) {
    throw new Error(
      `${publicPath} is too short to be a PNG (${header.length} of ${PREFIX_LENGTH} header bytes)`,
    );
  }
  if (!SIGNATURE.every((byte, i) => header[i] === byte)) {
    throw new Error(`${publicPath} does not start with the PNG signature`);
  }
  if (header.toString("latin1", IHDR_TYPE_OFFSET, IHDR_TYPE_OFFSET + 4) !== "IHDR") {
    throw new Error(`${publicPath} has no IHDR chunk after the PNG signature`);
  }
  const width = header.readUInt32BE(WIDTH_OFFSET);
  const height = header.readUInt32BE(HEIGHT_OFFSET);
  if (width === 0 || height === 0) {
    throw new Error(`${publicPath} declares an empty image (${width}x${height})`);
  }
  return { width, height };
}

function readPrefix(absolutePath: string, length: number): Buffer {
  const out = Buffer.alloc(length);
  const fd = openSync(absolutePath, "r");
  let filled = 0;
  try {
    while (filled < length) {
      const n = readSync(fd, out, filled, length - filled, filled);
      if (n === 0) break;
      filled += n;
    }
  } finally {
    closeSync(fd);
  }
  return out.subarray(0, filled);
}
