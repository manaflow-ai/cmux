import { describe, expect, it } from "vitest";
import {
  RENDER_ATTACH_MAX_ENCODED_CHARS,
  RENDER_GRAPHIC_MAX_DECODED_BYTES,
  RENDER_GRAPHIC_MAX_ENCODED_CHARS,
  type RenderGraphicImage,
  type RenderGraphicPlacement,
} from "cmux/browser";
import {
  decodeRenderGraphicImage,
  RENDER_GRAPHIC_MAX_CANVAS_DIMENSION,
  resolveRenderGraphicPlacement,
} from "../src/lib/renderGraphics";

const placement: RenderGraphicPlacement = {
  image_id: 9,
  placement_id: 3,
  ordinal: 0,
  x_offset: 2,
  y_offset: 3,
  source_x: 1,
  source_y: 0,
  source_width: 1,
  source_height: 2,
  columns: 2,
  rows: 1,
  grid_cols: 3,
  grid_rows: 2,
  pixel_width: 16,
  pixel_height: 16,
  viewport_col: 1,
  viewport_row: -1,
  viewport_visible: true,
  z: -1,
};

describe("render graphics", () => {
  it("decodes bounded RGB and RGBA pixels into browser RGBA", () => {
    const rgb = decodeRenderGraphicImage({
      id: 9,
      generation: 1,
      width: 2,
      height: 1,
      format: "rgb",
      data: "/wAAAP8A",
    });
    const rgba = decodeRenderGraphicImage({
      id: 10,
      generation: 1,
      width: 1,
      height: 1,
      format: "rgba",
      data: "AAD//w==",
    });

    expect(Array.from(rgb!.pixels)).toEqual([255, 0, 0, 255, 0, 255, 0, 255]);
    expect(Array.from(rgba!.pixels)).toEqual([0, 0, 255, 255]);
  });

  it("rejects dimension mismatches and images beyond the server storage bound", () => {
    const mismatched: RenderGraphicImage = {
      id: 9,
      generation: 1,
      width: 2,
      height: 2,
      format: "rgba",
      data: "/wAA/w==",
    };
    const oversized: RenderGraphicImage = {
      ...mismatched,
      width: 2_500_001,
      height: 1,
      data: "",
    };

    expect(decodeRenderGraphicImage(mismatched)).toBeNull();
    expect(decodeRenderGraphicImage(oversized)).toBeNull();
  });

  it("shares the transport budget and continues decoding after an oversized image", () => {
    expect(RENDER_GRAPHIC_MAX_DECODED_BYTES).toBe(10_000_000);
    expect(RENDER_GRAPHIC_MAX_ENCODED_CHARS).toBe(13_333_336);
    expect(RENDER_ATTACH_MAX_ENCODED_CHARS).toBe(33_554_432);
    expect(RENDER_GRAPHIC_MAX_ENCODED_CHARS).toBeLessThan(RENDER_ATTACH_MAX_ENCODED_CHARS);

    const oversized: RenderGraphicImage = {
      id: 11,
      generation: 1,
      width: RENDER_GRAPHIC_MAX_DECODED_BYTES / 4 + 1,
      height: 1,
      format: "rgba",
      data: "",
    };
    const next: RenderGraphicImage = {
      id: 12,
      generation: 1,
      width: 1,
      height: 1,
      format: "rgba",
      data: "AAD//w==",
    };

    expect(decodeRenderGraphicImage(oversized)).toBeNull();
    expect(Array.from(decodeRenderGraphicImage(next)!.pixels)).toEqual([0, 0, 255, 255]);
  });

  it("resolves source crop, cell origin, pixel offsets, explicit size, and layer", () => {
    const image: RenderGraphicImage = {
      id: 9,
      generation: 1,
      width: 2,
      height: 2,
      format: "rgba",
      data: "/wAA/wD/AP8AAP///////w==",
    };

    expect(resolveRenderGraphicPlacement(image, placement)).toMatchObject({
      key: "9:3:0",
      backingBytes: 8,
      source: { x: 1, y: 0, width: 1, height: 2 },
      layer: "below",
      style: {
        left: "calc(var(--render-cell-width) * 1 + 2px)",
        top: "calc(var(--render-cell-height) * -1 + 3px)",
        width: "calc(var(--render-cell-width) * 2)",
        height: "calc(var(--render-cell-height) * 1)",
      },
    });
  });

  it("drops hidden, missing, and below-background placements", () => {
    const image: RenderGraphicImage = {
      id: 9,
      generation: 1,
      width: 2,
      height: 2,
      format: "rgba",
      data: "/wAA/wD/AP8AAP///////w==",
    };

    expect(resolveRenderGraphicPlacement(image, { ...placement, viewport_visible: false })).toBeNull();
    expect(resolveRenderGraphicPlacement(image, { ...placement, image_id: 10 })).toBeNull();
    expect(resolveRenderGraphicPlacement(image, { ...placement, z: -1_073_741_824 })).toBeNull();
  });

  it("rejects browser-unsafe intrinsic canvas dimensions independently of area", () => {
    const atLimit: RenderGraphicImage = {
      id: 9,
      generation: 1,
      width: RENDER_GRAPHIC_MAX_CANVAS_DIMENSION,
      height: 1,
      format: "rgba",
      data: "",
    };
    const beyondLimit: RenderGraphicImage = {
      ...atLimit,
      width: RENDER_GRAPHIC_MAX_CANVAS_DIMENSION + 1,
    };
    const thinPlacement: RenderGraphicPlacement = {
      ...placement,
      source_x: 0,
      source_width: RENDER_GRAPHIC_MAX_CANVAS_DIMENSION,
      source_height: 1,
    };

    expect(resolveRenderGraphicPlacement(atLimit, thinPlacement)).toMatchObject({
      backingBytes: RENDER_GRAPHIC_MAX_CANVAS_DIMENSION * 4,
      source: { width: RENDER_GRAPHIC_MAX_CANVAS_DIMENSION, height: 1 },
    });
    expect(resolveRenderGraphicPlacement(beyondLimit, {
      ...thinPlacement,
      source_width: RENDER_GRAPHIC_MAX_CANVAS_DIMENSION + 1,
    })).toBeNull();
  });
});
