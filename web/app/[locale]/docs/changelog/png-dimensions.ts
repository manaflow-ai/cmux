import fs from "fs";
import path from "path";

/** Read PNG dimensions from the IHDR chunk: width at byte 16, height at byte 20. */
export function pngDimensions(filePath: string): { width: number; height: number } {
  const abs = path.join(process.cwd(), "public", filePath);
  // The IHDR width/height live in the first 24 bytes; read only those instead
  // of pulling the whole (multi-MB) image into memory at render time.
  const buf = Buffer.alloc(24);
  const fd = fs.openSync(abs, "r");
  try {
    fs.readSync(fd, buf, 0, 24, 0);
  } finally {
    fs.closeSync(fd);
  }
  return {
    width: buf.readUInt32BE(16),
    height: buf.readUInt32BE(20),
  };
}
