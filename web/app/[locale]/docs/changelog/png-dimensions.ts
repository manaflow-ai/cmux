import fs from "fs";
import path from "path";

/** Read PNG dimensions from the IHDR chunk: width at byte 16, height at byte 20. */
export function pngDimensions(filePath: string): { width: number; height: number } {
  const abs = path.join(process.cwd(), "public", filePath);
  const buf = fs.readFileSync(abs);
  return {
    width: buf.readUInt32BE(16),
    height: buf.readUInt32BE(20),
  };
}
