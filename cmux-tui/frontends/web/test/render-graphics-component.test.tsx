import { render } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import type { RenderGraphicPlacement } from "cmux/browser";
import { RenderGraphics } from "../src/components/RenderGraphics";
import type { RenderGraphicsModel } from "../src/lib/renderModel";

// A rendered terminal surface may reserve at most 64 MiB for placement canvases.
const DOCUMENTED_CANVAS_BACKING_BYTE_CAP = 64 * 1024 * 1024;

function zeroBytesBase64(byteCount: number): string {
  const padding = byteCount % 3 === 1 ? "==" : byteCount % 3 === 2 ? "=" : "";
  return `${"A".repeat(Math.ceil(byteCount / 3) * 4 - padding.length)}${padding}`;
}

function placement(placementId: number, width: number, height: number): RenderGraphicPlacement {
  return {
    image_id: 1,
    placement_id: placementId,
    ordinal: 0,
    x_offset: 0,
    y_offset: 0,
    source_x: 0,
    source_y: 0,
    source_width: width,
    source_height: height,
    columns: 1,
    rows: 1,
    grid_cols: 1,
    grid_rows: 1,
    pixel_width: width,
    pixel_height: height,
    viewport_col: 0,
    viewport_row: 0,
    viewport_visible: true,
    z: 0,
  };
}

describe("RenderGraphics canvas resource policy", () => {
  it("bounds aggregate backing for repeated large placements", () => {
    const width = 1_000;
    const height = 1_000;
    const placementCount = 512;
    const graphics: RenderGraphicsModel = {
      generation: 1,
      images: [{
        id: 1,
        generation: 1,
        width,
        height,
        format: "rgba",
        data: zeroBytesBase64(width * height * 4),
      }],
      placements: Array.from(
        { length: placementCount },
        (_, index) => placement(index + 1, width, height),
      ),
    };

    const { container } = render(
      <RenderGraphics graphics={graphics}>
        <div>terminal</div>
      </RenderGraphics>,
    );
    const canvases = [...container.querySelectorAll<HTMLCanvasElement>(
      "[data-graphic-placement]",
    )];
    const backingBytes = canvases.reduce(
      (total, canvas) => total + canvas.width * canvas.height * 4,
      0,
    );

    expect(canvases).toHaveLength(placementCount);
    expect(backingBytes).toBe(2_048_000_000);
    expect(backingBytes).toBeLessThanOrEqual(DOCUMENTED_CANVAS_BACKING_BYTE_CAP);
  });
});
