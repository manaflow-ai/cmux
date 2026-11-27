import { render as renderInTestRoot, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { RenderGraphicPlacement } from "cmux/raw";
import type { ReactElement } from "react";
import {
  RenderGraphics,
  RenderGraphicsBudgetProvider,
} from "../src/components/RenderGraphics";
import {
  decodeRenderGraphicImage,
  RENDER_GRAPHIC_CANVAS_BACKING_BYTE_CAP,
  RENDER_GRAPHIC_CANVAS_COUNT_CAP,
  RENDER_GRAPHIC_DECODED_BYTE_CAP,
} from "../src/lib/renderGraphics";
import { RenderGraphicsDecodeScheduler } from "../src/lib/renderGraphicsDecodeScheduler";
import type { RenderGraphicsModel } from "../src/lib/renderModel";
import type {
  RenderGraphicsDecodeRequest,
  RenderGraphicsDecodeResponse,
} from "../src/workers/renderGraphicsDecoder";

function render(element: ReactElement) {
  const result = renderInTestRoot(
    <RenderGraphicsBudgetProvider>{element}</RenderGraphicsBudgetProvider>,
  );
  return {
    ...result,
    rerender(nextElement: ReactElement) {
      result.rerender(
        <RenderGraphicsBudgetProvider>{nextElement}</RenderGraphicsBudgetProvider>,
      );
    },
  };
}

function zeroBytesBase64(byteCount: number): string {
  const padding = byteCount % 3 === 1 ? "==" : byteCount % 3 === 2 ? "=" : "";
  return `${"A".repeat(Math.ceil(byteCount / 3) * 4 - padding.length)}${padding}`;
}

function placement(
  placementId: number,
  width: number,
  height: number,
  z = 0,
): RenderGraphicPlacement {
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
    z,
  };
}

class WorkingWorker {
  onmessage: ((event: MessageEvent<RenderGraphicsDecodeResponse>) => void) | null = null;
  onerror: ((event: ErrorEvent) => void) | null = null;
  onmessageerror: ((event: MessageEvent) => void) | null = null;
  private terminated = false;

  postMessage(request: RenderGraphicsDecodeRequest): void {
    setTimeout(() => {
      if (this.terminated) return;
      const results = request.images.map((image) => {
        const decoded = decodeRenderGraphicImage(image);
        return {
          id: image.id,
          generation: image.generation,
          pixels: decoded?.pixels.buffer ?? null,
        };
      });
      this.onmessage?.(new MessageEvent("message", {
        data: { requestId: request.requestId, results },
      }));
    }, 0);
  }

  terminate(): void {
    this.terminated = true;
  }
}

beforeEach(() => {
  vi.stubGlobal("Worker", WorkingWorker);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("RenderGraphics canvas resource policy", () => {
  it.each(["onerror", "onmessageerror"] as const)(
    "falls back to local decoding after worker %s",
    async (failureCallback) => {
      class FailingWorker {
        onmessage: ((event: MessageEvent) => void) | null = null;
        onerror: ((event: ErrorEvent) => void) | null = null;
        onmessageerror: ((event: MessageEvent) => void) | null = null;

        postMessage(): void {
          setTimeout(() => {
            if (failureCallback === "onerror") {
              this.onerror?.(new ErrorEvent("error"));
            } else {
              this.onmessageerror?.(new MessageEvent("messageerror"));
            }
          }, 0);
        }

        terminate(): void {}
      }
      vi.stubGlobal("Worker", FailingWorker);
      const graphics: RenderGraphicsModel = {
        generation: 1n,
        images: [{
          id: 1,
          generation: 1n,
          width: 1,
          height: 1,
          format: "rgba",
          data: "AAAAAA==",
        }],
        placements: [placement(1, 1, 1)],
      };

      const { container } = render(
        <RenderGraphics graphics={graphics}>
          <div>terminal</div>
        </RenderGraphics>,
      );

      await waitFor(() => {
        expect(container.querySelectorAll("[data-graphic-placement]")).toHaveLength(1);
      });
    },
  );

  it("does not decode a large image on the browser thread after worker failure", async () => {
    class FailingWorker {
      onmessage: ((event: MessageEvent) => void) | null = null;
      onerror: ((event: ErrorEvent) => void) | null = null;
      onmessageerror: ((event: MessageEvent) => void) | null = null;

      postMessage(): void {
        setTimeout(() => this.onerror?.(new ErrorEvent("error")), 0);
      }

      terminate(): void {}
    }
    vi.stubGlobal("Worker", FailingWorker);
    const width = 1_000;
    const height = 1_000;
    const graphics: RenderGraphicsModel = {
      generation: 1n,
      images: [{
        id: 1,
        generation: 1n,
        width: 1,
        height: 1,
        format: "rgba",
        data: "AAAAAA==",
      }, {
        id: 2,
        generation: 1n,
        width,
        height,
        format: "rgba",
        data: zeroBytesBase64(width * height * 4),
      }],
      placements: [
        placement(1, 1, 1),
        { ...placement(2, width, height), image_id: 2 },
      ],
    };

    const { container } = render(
      <RenderGraphics graphics={graphics}>
        <div>terminal</div>
      </RenderGraphics>,
    );

    await waitFor(() => {
      expect(container.querySelectorAll("[data-graphic-placement]")).toHaveLength(1);
    });
    expect(container.querySelector("[data-graphic-placement='2:2:0']")).toBeNull();
  });

  it("retries a valid large image after a transient worker failure", async () => {
    let workerCount = 0;
    class RecoveringWorker {
      onmessage: ((event: MessageEvent<RenderGraphicsDecodeResponse>) => void) | null = null;
      onerror: ((event: ErrorEvent) => void) | null = null;
      onmessageerror: ((event: MessageEvent) => void) | null = null;
      private readonly fails: boolean;
      private terminated = false;

      constructor() {
        workerCount += 1;
        this.fails = workerCount === 1;
      }

      postMessage(request: RenderGraphicsDecodeRequest): void {
        setTimeout(() => {
          if (this.terminated) return;
          if (this.fails) {
            this.onerror?.(new ErrorEvent("error"));
            return;
          }
          this.onmessage?.(new MessageEvent("message", {
            data: {
              requestId: request.requestId,
              results: request.images.map((image) => {
                const decoded = decodeRenderGraphicImage(image);
                return {
                  id: image.id,
                  generation: image.generation,
                  pixels: decoded?.pixels.buffer ?? null,
                };
              }),
            },
          }));
        }, 0);
      }

      terminate(): void {
        this.terminated = true;
      }
    }
    vi.stubGlobal("Worker", RecoveringWorker);
    const width = 257;
    const height = 256;
    const graphics: RenderGraphicsModel = {
      generation: 1n,
      images: [{
        id: 1,
        generation: 1n,
        width,
        height,
        format: "rgba",
        data: zeroBytesBase64(width * height * 4),
      }],
      placements: [placement(1, width, height)],
    };

    const { container } = render(
      <RenderGraphics graphics={graphics}>
        <div>terminal</div>
      </RenderGraphics>,
    );

    await waitFor(() => {
      expect(container.querySelectorAll("[data-graphic-placement]")).toHaveLength(1);
    });
    expect(workerCount).toBe(2);
  });

  it("continues with later owners after large-image worker retries are exhausted", async () => {
    class FailingWorker {
      onmessage: ((event: MessageEvent) => void) | null = null;
      onerror: ((event: ErrorEvent) => void) | null = null;
      onmessageerror: ((event: MessageEvent) => void) | null = null;

      postMessage(): void {
        setTimeout(() => this.onerror?.(new ErrorEvent("error")), 0);
      }

      terminate(): void {}
    }
    vi.stubGlobal("Worker", FailingWorker);
    const scheduler = new RenderGraphicsDecodeScheduler();
    const largeImage = (id: number) => ({
      id,
      generation: 1n,
      width: 257,
      height: 256,
      format: "rgba" as const,
      data: zeroBytesBase64(257 * 256 * 4),
    });
    const smallImage = {
      id: 3,
      generation: 1n,
      width: 1,
      height: 1,
      format: "rgba" as const,
      data: "AAAAAA==",
    };
    const smallComplete = vi.fn();

    scheduler.schedule(Symbol("large-a"), [largeImage(1)], vi.fn());
    scheduler.schedule(Symbol("large-b"), [largeImage(2)], vi.fn());
    scheduler.schedule(Symbol("small"), [smallImage], smallComplete);

    await waitFor(() => expect(smallComplete).toHaveBeenCalledTimes(1));
    expect(smallComplete.mock.calls[0]?.[0]?.[0]?.pixels).not.toBeNull();
    scheduler.dispose();
  });

  it("chunks aggregate browser-thread decoding after worker failure", async () => {
    class FailingWorker {
      onmessage: ((event: MessageEvent) => void) | null = null;
      onerror: ((event: ErrorEvent) => void) | null = null;
      onmessageerror: ((event: MessageEvent) => void) | null = null;

      postMessage(): void {
        setTimeout(() => this.onerror?.(new ErrorEvent("error")), 0);
      }

      terminate(): void {}
    }
    vi.stubGlobal("Worker", FailingWorker);
    const width = 256;
    const height = 128;
    const byteLength = width * height * 4;
    const graphics: RenderGraphicsModel = {
      generation: 1n,
      images: Array.from({ length: 3 }, (_, index) => ({
        id: index + 1,
        generation: 1n,
        width,
        height,
        format: "rgba" as const,
        data: zeroBytesBase64(byteLength),
      })),
      placements: Array.from(
        { length: 3 },
        (_, index) => ({ ...placement(index + 1, width, height), image_id: index + 1 }),
      ),
    };

    const { container } = render(
      <RenderGraphics graphics={graphics}>
        <div>terminal</div>
      </RenderGraphics>,
    );

    await waitFor(() => {
      expect(container.querySelectorAll("[data-graphic-placement]")).toHaveLength(3);
    });
  });

  it("decodes asynchronously and bounds aggregate backing for repeated large placements", async () => {
    const width = 1_000;
    const height = 1_000;
    const placementCount = 512;
    const graphics: RenderGraphicsModel = {
      generation: 1n,
      images: [{
        id: 1,
        generation: 1n,
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
    expect(container.querySelectorAll("[data-graphic-placement]")).toHaveLength(0);
    await waitFor(
      () => expect(container.querySelectorAll("[data-graphic-placement]")).toHaveLength(16),
      { timeout: 5_000 },
    );
    const canvases = [...container.querySelectorAll<HTMLCanvasElement>(
      "[data-graphic-placement]",
    )];
    const backingBytes = canvases.reduce(
      (total, canvas) => total + canvas.width * canvas.height * 4,
      0,
    );

    expect(placementCount * width * height * 4).toBe(2_048_000_000);
    expect(canvases).toHaveLength(16);
    expect(backingBytes).toBe(64_000_000);
    expect(backingBytes).toBeLessThanOrEqual(RENDER_GRAPHIC_CANVAS_BACKING_BYTE_CAP);
  });

  it("scans maximum-scale placements once when the backing budget fills early", () => {
    let visibilityReads = 0;
    const width = 1_024;
    const height = 1_024;
    const placementCount = 16_384;
    const placements = Array.from({ length: placementCount }, (_, index) => {
      const candidate = placement(index + 1, width, height);
      Object.defineProperty(candidate, "viewport_visible", {
        configurable: true,
        enumerable: true,
        get: () => {
          visibilityReads += 1;
          return true;
        },
      });
      return candidate;
    });
    const graphics: RenderGraphicsModel = {
      generation: 1n,
      images: [{
        id: 1,
        generation: 1n,
        width,
        height,
        format: "rgba",
        data: zeroBytesBase64(width * height * 4),
      }],
      placements,
    };

    render(
      <RenderGraphics graphics={graphics}>
        <div>terminal</div>
      </RenderGraphics>,
    );

    expect(visibilityReads).toBeLessThanOrEqual(placementCount * 2);
  });

  it("preserves the topmost placement under the backing cap", async () => {
    const width = 1_024;
    const height = 1_024;
    const graphics: RenderGraphicsModel = {
      generation: 1n,
      images: [{
        id: 1,
        generation: 1n,
        width,
        height,
        format: "rgba",
        data: zeroBytesBase64(width * height * 4),
      }],
      placements: [
        placement(17, width, height, 2),
        ...Array.from(
          { length: 16 },
          (_, index) => placement(index + 1, width, height),
        ),
      ],
    };

    const { container } = render(
      <RenderGraphics graphics={graphics}>
        <div>terminal</div>
      </RenderGraphics>,
    );
    await waitFor(
      () => expect(container.querySelectorAll("[data-graphic-placement]")).toHaveLength(16),
      { timeout: 5_000 },
    );
    const canvases = [...container.querySelectorAll<HTMLCanvasElement>(
      "[data-graphic-placement]",
    )];
    const backingBytes = canvases.reduce(
      (total, canvas) => total + canvas.width * canvas.height * 4,
      0,
    );

    expect(backingBytes).toBe(RENDER_GRAPHIC_CANVAS_BACKING_BYTE_CAP);
    expect(canvases.map((canvas) => canvas.dataset.graphicPlacement)).toEqual(
      [
        ...Array.from({ length: 15 }, (_, index) => `1:${index + 2}:0`),
        "1:17:0",
      ],
    );
  });

  it("refills the canvas budget from lower-priority placements after byte rejections", async () => {
    const width = 1_024;
    const height = 257;
    const fullPlacementCount = RENDER_GRAPHIC_CANVAS_COUNT_CAP;
    const graphics: RenderGraphicsModel = {
      generation: 1n,
      images: [{
        id: 1,
        generation: 1n,
        width,
        height,
        format: "rgba",
        data: zeroBytesBase64(width * height * 4),
      }],
      placements: [
        ...Array.from(
          { length: fullPlacementCount },
          (_, index) => placement(index + 1, width, height, 1),
        ),
        placement(fullPlacementCount + 1, 1, 1),
      ],
    };

    const { container } = render(
      <RenderGraphics graphics={graphics}>
        <div>terminal</div>
      </RenderGraphics>,
    );

    await waitFor(() => {
      expect(container.querySelectorAll("[data-graphic-placement]").length).toBeGreaterThan(0);
    });
    expect(container.querySelectorAll("[data-graphic-placement]")).toHaveLength(64);
    expect(
      container.querySelector(
        `[data-graphic-placement='1:${fullPlacementCount + 1}:0']`,
      ),
    ).not.toBeNull();
  });

  it("reads layout geometry only for candidates considered under the canvas cap", async () => {
    let viewportColumnReads = 0;
    const placementCount = 16_384;
    const placements = Array.from({ length: placementCount }, (_, index) => {
      const candidate = placement(index + 1, 1, 1, index);
      Object.defineProperty(candidate, "viewport_col", {
        configurable: true,
        enumerable: true,
        get: () => {
          viewportColumnReads += 1;
          return 0;
        },
      });
      return candidate;
    });
    const graphics: RenderGraphicsModel = {
      generation: 1n,
      images: [{
        id: 1,
        generation: 1n,
        width: 1,
        height: 1,
        format: "rgba",
        data: "AAAAAA==",
      }],
      placements,
    };

    const { container } = render(
      <RenderGraphics graphics={graphics}>
        <div>terminal</div>
      </RenderGraphics>,
    );

    await waitFor(() => {
      expect(container.querySelectorAll("[data-graphic-placement]"))
        .toHaveLength(RENDER_GRAPHIC_CANVAS_COUNT_CAP);
    });
    expect(viewportColumnReads).toBeLessThanOrEqual(RENDER_GRAPHIC_CANVAS_COUNT_CAP * 2);
  });

  it("prunes every placement for an image rejected by the decoded-byte budget", () => {
    class PausedWorker {
      onmessage: ((event: MessageEvent<RenderGraphicsDecodeResponse>) => void) | null = null;
      onerror: ((event: ErrorEvent) => void) | null = null;
      onmessageerror: ((event: MessageEvent) => void) | null = null;
      postMessage(): void {}
      terminate(): void {}
    }
    vi.stubGlobal("Worker", PausedWorker);
    const decodedBytes = 10_000_000;
    const data = zeroBytesBase64(decodedBytes);
    const image = (id: number) => ({
      id,
      generation: 1n,
      width: decodedBytes / 4,
      height: 1,
      format: "rgba" as const,
      data,
    });
    const admitted: RenderGraphicsModel = {
      generation: 1n,
      images: Array.from({ length: 6 }, (_, index) => image(index + 1)),
      placements: Array.from(
        { length: 6 },
        (_, index) => ({ ...placement(index + 1, 1, 1, 2), image_id: index + 1 }),
      ),
    };
    let sourceReads = 0;
    const rejectedPlacements = Array.from({ length: 16_384 }, (_, index) => {
      const candidate = { ...placement(index + 1, 1, 1, 1), image_id: 7 };
      Object.defineProperty(candidate, "source_x", {
        configurable: true,
        enumerable: true,
        get: () => {
          sourceReads += 1;
          return 0;
        },
      });
      return candidate;
    });
    const rejected: RenderGraphicsModel = {
      generation: 1n,
      images: [image(7)],
      placements: rejectedPlacements,
    };

    render(
      <>
        <RenderGraphics graphics={admitted}>
          <div>admitted terminal</div>
        </RenderGraphics>
        <RenderGraphics graphics={rejected}>
          <div>rejected terminal</div>
        </RenderGraphics>
      </>,
    );

    expect(sourceReads).toBeLessThanOrEqual(8);
  });

  it("shares one backing budget across terminal surfaces and releases it on unmount", async () => {
    const width = 1_024;
    const height = 1_024;
    const graphics: RenderGraphicsModel = {
      generation: 1n,
      images: [{
        id: 1,
        generation: 1n,
        width,
        height,
        format: "rgba",
        data: zeroBytesBase64(width * height * 4),
      }],
      placements: Array.from(
        { length: 16 },
        (_, index) => placement(index + 1, width, height),
      ),
    };
    const surfaces = (includeFirst: boolean) => (
      <>
        {includeFirst && (
          <section data-testid="first" key="first">
            <RenderGraphics graphics={graphics}>
              <div>first terminal</div>
            </RenderGraphics>
          </section>
        )}
        <section data-testid="second" key="second">
          <RenderGraphics graphics={graphics}>
            <div>second terminal</div>
          </RenderGraphics>
        </section>
      </>
    );
    const { container, getByTestId, rerender } = render(surfaces(true));

    await waitFor(
      () => expect(container.querySelectorAll("[data-graphic-placement]")).toHaveLength(16),
      { timeout: 5_000 },
    );
    const backingBytes = [...container.querySelectorAll<HTMLCanvasElement>(
      "[data-graphic-placement]",
    )].reduce((total, canvas) => total + canvas.width * canvas.height * 4, 0);
    expect(backingBytes).toBe(RENDER_GRAPHIC_CANVAS_BACKING_BYTE_CAP);

    rerender(surfaces(false));
    await waitFor(() => {
      expect(getByTestId("second").querySelectorAll("[data-graphic-placement]"))
        .toHaveLength(16);
    });
  });

  it("isolates graphics budgets between independent React roots", async () => {
    const width = 1_024;
    const height = 1_024;
    const graphics: RenderGraphicsModel = {
      generation: 1n,
      images: [{
        id: 1,
        generation: 1n,
        width,
        height,
        format: "rgba",
        data: zeroBytesBase64(width * height * 4),
      }],
      placements: Array.from(
        { length: 16 },
        (_, index) => placement(index + 1, width, height),
      ),
    };
    const first = render(
      <RenderGraphics graphics={graphics}>
        <div>first app</div>
      </RenderGraphics>,
    );
    await waitFor(
      () => expect(first.container.querySelectorAll("[data-graphic-placement]")).toHaveLength(16),
      { timeout: 5_000 },
    );

    const second = render(
      <RenderGraphics graphics={graphics}>
        <div>second app</div>
      </RenderGraphics>,
    );

    await waitFor(
      () => expect(second.container.querySelectorAll("[data-graphic-placement]")).toHaveLength(16),
      { timeout: 5_000 },
    );
    expect(first.container.querySelectorAll("[data-graphic-placement]")).toHaveLength(16);
  });

  it("caps tiny placements by canvas count independently of backing bytes", async () => {
    const placementCount = RENDER_GRAPHIC_CANVAS_COUNT_CAP + 1_000;
    const graphics: RenderGraphicsModel = {
      generation: 1n,
      images: [{
        id: 1,
        generation: 1n,
        width: 1,
        height: 1,
        format: "rgba",
        data: "AAAAAA==",
      }],
      placements: Array.from(
        { length: placementCount },
        (_, index) => placement(index + 1, 1, 1),
      ),
    };

    const { container } = render(
      <RenderGraphics graphics={graphics}>
        <div>terminal</div>
      </RenderGraphics>,
    );

    await waitFor(() => {
      expect(container.querySelectorAll("[data-graphic-placement]"))
        .toHaveLength(RENDER_GRAPHIC_CANVAS_COUNT_CAP);
    });
  });

  it("keeps the top 512 placements from one oversized owner list", async () => {
    const placementCount = RENDER_GRAPHIC_CANVAS_COUNT_CAP + 1_000;
    const graphics: RenderGraphicsModel = {
      generation: 1n,
      images: [{
        id: 1,
        generation: 1n,
        width: 1,
        height: 1,
        format: "rgba",
        data: "AAAAAA==",
      }],
      placements: Array.from(
        { length: placementCount },
        (_, index) => placement(index + 1, 1, 1, index),
      ),
    };

    const { container } = render(
      <RenderGraphics graphics={graphics}>
        <div>terminal</div>
      </RenderGraphics>,
    );

    await waitFor(() => {
      expect(container.querySelectorAll("[data-graphic-placement]"))
        .toHaveLength(RENDER_GRAPHIC_CANVAS_COUNT_CAP);
    });
    const keys = [...container.querySelectorAll<HTMLElement>("[data-graphic-placement]")]
      .map((canvas) => canvas.dataset.graphicPlacement);
    expect(keys[0]).toBe(`1:${placementCount - RENDER_GRAPHIC_CANVAS_COUNT_CAP + 1}:0`);
    expect(keys.at(-1)).toBe(`1:${placementCount}:0`);
  });

  it("counts duplicate placement identities as distinct canvas allocations", async () => {
    const placementCount = RENDER_GRAPHIC_CANVAS_COUNT_CAP + 1_000;
    const duplicate = placement(1, 1, 1);
    const graphics: RenderGraphicsModel = {
      generation: 1n,
      images: [{
        id: 1,
        generation: 1n,
        width: 1,
        height: 1,
        format: "rgba",
        data: "AAAAAA==",
      }],
      placements: Array.from({ length: placementCount }, () => ({ ...duplicate })),
    };

    const { container } = render(
      <RenderGraphics graphics={graphics}>
        <div>terminal</div>
      </RenderGraphics>,
    );

    await waitFor(() => {
      expect(container.querySelectorAll("[data-graphic-placement]"))
        .toHaveLength(RENDER_GRAPHIC_CANVAS_COUNT_CAP);
    });
  });

  it("admits decoded image buffers under one browser-wide byte cap", async () => {
    let requestedImages = 0;
    class RecordingWorker {
      onmessage: ((event: MessageEvent<RenderGraphicsDecodeResponse>) => void) | null = null;
      onerror: ((event: ErrorEvent) => void) | null = null;
      onmessageerror: ((event: MessageEvent) => void) | null = null;
      private terminated = false;

      postMessage(request: RenderGraphicsDecodeRequest): void {
        requestedImages += request.images.length;
        setTimeout(() => {
          if (this.terminated) return;
          this.onmessage?.(new MessageEvent("message", {
            data: {
              requestId: request.requestId,
              results: request.images.map((image) => ({
                id: image.id,
                generation: image.generation,
                pixels: null,
              })),
            },
          }));
        }, 0);
      }

      terminate(): void {
        this.terminated = true;
      }
    }
    vi.stubGlobal("Worker", RecordingWorker);
    const decodedBytes = 10_000_000;
    const graphics: RenderGraphicsModel = {
      generation: 1n,
      images: [{
        id: 1,
        generation: 1n,
        width: decodedBytes / 4,
        height: 1,
        format: "rgba",
        data: zeroBytesBase64(decodedBytes),
      }],
      placements: [placement(1, 1, 1)],
    };
    const surfaceCount = Math.floor(RENDER_GRAPHIC_DECODED_BYTE_CAP / decodedBytes) + 1;

    render(
      <>
        {Array.from({ length: surfaceCount }, (_, index) => (
          <RenderGraphics graphics={graphics} key={index}>
            <div>terminal {index}</div>
          </RenderGraphics>
        ))}
      </>,
    );

    await waitFor(() => {
      expect(requestedImages).toBe(Math.floor(RENDER_GRAPHIC_DECODED_BYTE_CAP / decodedBytes));
    });
    expect(surfaceCount * decodedBytes).toBeGreaterThan(RENDER_GRAPHIC_DECODED_BYTE_CAP);
  });

  it("bounds concurrent decoder workers across graphics owners", async () => {
    let activeWorkers = 0;
    let maxActiveWorkers = 0;
    let startedRequests = 0;
    const workers: PausedWorker[] = [];
    class PausedWorker {
      onmessage: ((event: MessageEvent<RenderGraphicsDecodeResponse>) => void) | null = null;
      onerror: ((event: ErrorEvent) => void) | null = null;
      onmessageerror: ((event: MessageEvent) => void) | null = null;
      private request: RenderGraphicsDecodeRequest | null = null;
      private terminated = false;

      constructor() {
        activeWorkers += 1;
        maxActiveWorkers = Math.max(maxActiveWorkers, activeWorkers);
        workers.push(this);
      }

      postMessage(request: RenderGraphicsDecodeRequest): void {
        this.request = request;
        startedRequests += 1;
      }

      complete(): void {
        const request = this.request;
        if (request === null) throw new Error("worker has no pending request");
        this.request = null;
        this.onmessage?.(new MessageEvent("message", {
          data: {
            requestId: request.requestId,
            results: request.images.map((image) => ({
              id: image.id,
              generation: image.generation,
              pixels: null,
            })),
          },
        }));
      }

      terminate(): void {
        if (this.terminated) return;
        this.terminated = true;
        activeWorkers -= 1;
      }
    }
    vi.stubGlobal("Worker", PausedWorker);
    const graphics: RenderGraphicsModel = {
      generation: 1n,
      images: [{
        id: 1,
        generation: 1n,
        width: 1,
        height: 1,
        format: "rgba",
        data: "AAAAAA==",
      }],
      placements: [placement(1, 1, 1)],
    };

    render(
      <>
        {Array.from({ length: 8 }, (_, index) => (
          <RenderGraphics graphics={graphics} key={index}>
            <div>terminal {index}</div>
          </RenderGraphics>
        ))}
      </>,
    );

    await waitFor(() => expect(startedRequests).toBeGreaterThan(0));
    expect(maxActiveWorkers).toBeLessThanOrEqual(2);
    expect(workers).toHaveLength(2);
    workers[0]!.complete();
    await waitFor(() => expect(startedRequests).toBeGreaterThan(2));
    expect(workers).toHaveLength(2);
  });

  it("cancels a superseded decode before publishing stale pixels", async () => {
    const first: RenderGraphicsModel = {
      generation: 1n,
      images: [{
        id: 1,
        generation: 1n,
        width: 1,
        height: 1,
        format: "rgba",
        data: zeroBytesBase64(4),
      }],
      placements: [placement(1, 1, 1)],
    };
    const second: RenderGraphicsModel = {
      generation: 2n,
      images: [{
        id: 1,
        generation: 2n,
        width: 2,
        height: 1,
        format: "rgba",
        data: zeroBytesBase64(8),
      }],
      placements: [placement(1, 2, 1)],
    };
    const { container, rerender } = render(
      <RenderGraphics graphics={first}>
        <div>terminal</div>
      </RenderGraphics>,
    );
    rerender(
      <RenderGraphics graphics={second}>
        <div>terminal</div>
      </RenderGraphics>,
    );

    await waitFor(() => {
      const canvases = container.querySelectorAll<HTMLCanvasElement>(
        "[data-graphic-placement]",
      );
      expect(canvases).toHaveLength(1);
      expect(canvases[0]).toHaveAttribute("width", "2");
    });
  });

  it("keeps an in-flight decoder across placement-only updates", async () => {
    let workers = 0;
    let terminations = 0;
    class PausedWorker {
      onmessage: ((event: MessageEvent<RenderGraphicsDecodeResponse>) => void) | null = null;
      onerror: ((event: ErrorEvent) => void) | null = null;
      onmessageerror: ((event: MessageEvent) => void) | null = null;

      constructor() {
        workers += 1;
      }

      postMessage(): void {}

      terminate(): void {
        terminations += 1;
      }
    }
    vi.stubGlobal("Worker", PausedWorker);
    const image = {
      id: 1,
      generation: 1n,
      width: 1,
      height: 1,
      format: "rgba" as const,
      data: zeroBytesBase64(4),
    };
    const first: RenderGraphicsModel = {
      generation: 1n,
      images: [image],
      placements: [placement(1, 1, 1)],
    };
    const movedPlacement = { ...placement(1, 1, 1), viewport_col: 1 };
    const second: RenderGraphicsModel = {
      generation: 2n,
      images: [{ ...image }],
      placements: [movedPlacement],
    };
    const { rerender } = render(
      <RenderGraphics graphics={first}>
        <div>terminal</div>
      </RenderGraphics>,
    );
    await waitFor(() => expect(workers).toBe(1));

    rerender(
      <RenderGraphics graphics={second}>
        <div>terminal</div>
      </RenderGraphics>,
    );
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(workers).toBe(1);
    expect(terminations).toBe(0);
  });

  it("restores a reused canvas backing store after a placement-only update", async () => {
    class FakeImageData {
      readonly colorSpace = "srgb";
      constructor(
        readonly data: Uint8ClampedArray,
        readonly width: number,
        readonly height: number,
      ) {}
    }
    const context = {
      clearRect: vi.fn(),
      putImageData: vi.fn(),
    };
    vi.stubGlobal("ImageData", FakeImageData);
    const getContext = vi.spyOn(HTMLCanvasElement.prototype, "getContext")
      .mockReturnValue(context as unknown as CanvasRenderingContext2D);
    const image = {
      id: 1,
      generation: 1n,
      width: 1,
      height: 1,
      format: "rgba" as const,
      data: zeroBytesBase64(4),
    };
    const first: RenderGraphicsModel = {
      generation: 1n,
      images: [image],
      placements: [placement(1, 1, 1)],
    };
    const second: RenderGraphicsModel = {
      generation: 2n,
      images: [{ ...image }],
      placements: [{ ...placement(1, 1, 1), viewport_col: 1 }],
    };

    try {
      const { container, rerender } = render(
        <RenderGraphics graphics={first}>
          <div>terminal</div>
        </RenderGraphics>,
      );
      await waitFor(() => expect(context.putImageData).toHaveBeenCalledTimes(1));
      const canvas = container.querySelector<HTMLCanvasElement>(
        "[data-graphic-placement]",
      )!;

      rerender(
        <RenderGraphics graphics={second}>
          <div>terminal</div>
        </RenderGraphics>,
      );
      await waitFor(() => expect(context.putImageData).toHaveBeenCalledTimes(2));

      expect(container.querySelector("[data-graphic-placement]")).toBe(canvas);
      expect(canvas.width).toBe(1);
      expect(canvas.height).toBe(1);
    } finally {
      getContext.mockRestore();
    }
  });

  it("does not recalculate placement admission for a pixel-only image update", async () => {
    const placements = [placement(1, 1, 1)];
    const first: RenderGraphicsModel = {
      generation: 1n,
      images: [{
        id: 1,
        generation: 1n,
        width: 1,
        height: 1,
        format: "rgba",
        data: zeroBytesBase64(4),
      }],
      placements,
    };
    const second: RenderGraphicsModel = {
      generation: 2n,
      images: [{
        ...first.images[0]!,
        generation: 2n,
      }],
      placements,
    };
    const { container, rerender } = render(
      <RenderGraphics graphics={first}>
        <div>terminal</div>
      </RenderGraphics>,
    );
    await waitFor(
      () => expect(container.querySelectorAll("[data-graphic-placement]")).toHaveLength(1),
    );
    const queueMicrotaskSpy = vi.spyOn(globalThis, "queueMicrotask");
    queueMicrotaskSpy.mockClear();

    rerender(
      <RenderGraphics graphics={second}>
        <div>terminal</div>
      </RenderGraphics>,
    );

    expect(queueMicrotaskSpy).not.toHaveBeenCalled();
  });
});
