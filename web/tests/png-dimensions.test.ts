import { describe, expect, test } from "bun:test";
import { pngDimensions } from "../app/[locale]/docs/changelog/png-dimensions";

describe("pngDimensions", () => {
  test("reads true width and height from the IHDR chunk", () => {
    // The IHDR header packs width at byte 16 and height at byte 20. Reading the
    // wrong offset (e.g. 24) lands on bit-depth/color-type bytes and yields a
    // garbage ~134M height, which blew up the changelog images.
    const { width, height } = pngDimensions(
      "/changelog/0.61.0-command-palette.png",
    );
    expect(width).toBe(1172);
    expect(height).toBe(1006);
  });
});
