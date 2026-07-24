import { fireEvent, render } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { CmuxClient } from "cmux/browser";
import type { RenderModel } from "../src/lib/renderModel";
import { renderAttrs } from "../src/lib/renderStyles";
import { RenderTerminal } from "../src/components/RenderTerminal";

const renderHook = vi.hoisted(() => ({
  focused: true,
  graphicsEnabled: true,
  historyActive: false,
  sendKey: vi.fn(),
  sendText: vi.fn(),
}));

const model: RenderModel = {
  surface: 7,
  size: { cols: 4, rows: 2 },
  cursor: { x: 2, y: 1, style: "bar", blink: true, visible: true, color: null },
  defaultFg: "#eeeeee",
  defaultBg: "#111111",
  scrollbackRows: 10,
  graphics: {
    generation: 4,
    images: [{
      id: 9,
      generation: 2,
      width: 2,
      height: 2,
      format: "rgba",
      data: "/wAA/wD/AP8AAP///////w==",
    }],
    placements: [
      {
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
      },
      {
        image_id: 9,
        placement_id: 4,
        ordinal: 0,
        x_offset: 0,
        y_offset: 0,
        source_x: 0,
        source_y: 0,
        source_width: 2,
        source_height: 2,
        columns: 1,
        rows: 1,
        grid_cols: 1,
        grid_rows: 1,
        pixel_width: 8,
        pixel_height: 16,
        viewport_col: 0,
        viewport_row: 0,
        viewport_visible: true,
        z: 2,
      },
    ],
  },
  rows: [
    { row: 0, runs: [{ text: "界", fg: null, bg: null, attrs: renderAttrs.bold, width_hint: 2 }] },
    { row: 1, runs: [{ text: "ok  ", fg: "#00ff00", bg: null, attrs: 0, underline: "dashed" }] },
  ],
};

vi.mock("../src/hooks/useRenderTerminal", () => ({
  useRenderTerminal: () => ({
    terminalRef: () => undefined,
    focused: renderHook.focused,
    foreignSize: null,
    model: renderHook.graphicsEnabled ? model : { ...model, graphics: undefined },
    history: {
      active: renderHook.historyActive,
      loading: false,
      total: 10,
      rows: [{ row: 9, runs: [{ text: "old ", fg: null, bg: null, attrs: 0 }] }],
    },
    backToLive: vi.fn(),
    sendKey: renderHook.sendKey,
    sendText: renderHook.sendText,
  }),
}));

beforeEach(() => {
  renderHook.focused = true;
  renderHook.graphicsEnabled = true;
  renderHook.historyActive = false;
  renderHook.sendKey.mockClear();
  renderHook.sendText.mockClear();
});

describe("RenderTerminal DOM grid", () => {
  it("renders one absolute row per model row, authoritative run width, and server cursor geometry", () => {
    const { container } = render(
      <RenderTerminal client={{ protocol: 7 } as CmuxClient} surface={7} active error={null} onError={vi.fn()} />,
    );

    expect(container.querySelectorAll(".render-row")).toHaveLength(2);
    expect(container.querySelector(".render-row")?.textContent).toBe("界");
    expect(container.querySelector<HTMLElement>(".render-grid")?.style.width)
      .toBe("calc(var(--render-cell-width) * 4)");
    expect(container.querySelector<HTMLElement>(".render-run")?.style.width)
      .toBe("calc(var(--render-cell-width) * 2)");
    expect(container.querySelector(".render-cursor-bar.render-cursor-blink")).toHaveStyle({
      left: "calc(var(--render-cell-width) * 2)",
      top: "calc(var(--render-cell-height) * 1)",
    });
  });

  it("routes mobile navigation through terminal-mode-aware named keys", () => {
    const { getByLabelText } = render(
      <RenderTerminal client={{ protocol: 7 } as CmuxClient} surface={7} active error={null} onError={vi.fn()} />,
    );

    fireEvent.click(getByLabelText("Left arrow"));
    expect(renderHook.sendKey).toHaveBeenCalledWith("left");
    expect(renderHook.sendText).not.toHaveBeenCalled();
  });

  it("renders one row layer with real backgrounds when graphics are absent", () => {
    renderHook.graphicsEnabled = false;
    const { container } = render(
      <RenderTerminal client={{ protocol: 7 } as CmuxClient} surface={7} active error={null} onError={vi.fn()} />,
    );

    expect(container.querySelectorAll(".render-row-background")).toHaveLength(0);
    expect(container.querySelectorAll(".render-row")).toHaveLength(2);
    expect(container.querySelector(".render-row .render-run")).toHaveStyle({
      backgroundColor: "#111111",
    });
  });

  it("renders cropped Kitty placements around terminal text in z order", () => {
    const { container } = render(
      <RenderTerminal client={{ protocol: 7 } as CmuxClient} surface={7} active error={null} onError={vi.fn()} />,
    );

    const below = container.querySelector<HTMLElement>(".render-graphics-below");
    const above = container.querySelector<HTMLElement>(".render-graphics-above");
    const cropped = below?.querySelector<HTMLCanvasElement>("[data-graphic-placement='9:3:0']");
    expect(cropped).toHaveAttribute("width", "1");
    expect(cropped).toHaveAttribute("height", "2");
    expect(cropped?.style.left).toBe("calc(var(--render-cell-width) * 1 + 2px)");
    expect(cropped?.style.top).toBe("calc(var(--render-cell-height) * -1 + 3px)");
    expect(cropped?.style.width).toBe("calc(var(--render-cell-width) * 2)");
    expect(cropped?.style.height).toBe("calc(var(--render-cell-height) * 1)");
    expect(above?.querySelector("[data-graphic-placement='9:4:0']")).not.toBeNull();

    const gridChildren = [...container.querySelector(".render-grid")!.children];
    const background = container.querySelector<HTMLElement>(".render-row-background");
    expect(background?.querySelector(".render-run")).toHaveStyle({ backgroundColor: "#111111" });
    expect(container.querySelector<HTMLElement>(".render-row .render-run")?.style.backgroundColor)
      .toBe("transparent");
    expect(gridChildren.indexOf(background!)).toBeLessThan(gridChildren.indexOf(below!));
    expect(gridChildren.indexOf(below!)).toBeLessThan(
      gridChildren.findIndex((child) => child.classList.contains("render-row")),
    );
    expect(gridChildren.indexOf(above!)).toBeGreaterThan(
      gridChildren.findIndex((child) => child.classList.contains("render-row")),
    );
  });

  it("hides live Kitty placements while displaying scrollback history", () => {
    renderHook.historyActive = true;
    const { container } = render(
      <RenderTerminal client={{ protocol: 7 } as CmuxClient} surface={7} active error={null} onError={vi.fn()} />,
    );

    expect(container.querySelectorAll("[data-graphic-placement]")).toHaveLength(0);
    expect(container.querySelectorAll(".render-row-background")).toHaveLength(0);
    expect(container.querySelector(".render-row .render-run")).toHaveStyle({
      backgroundColor: "#111111",
    });
  });

  it("draws source crops and releases canvas backing stores on unmount", () => {
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
    try {
      const { container, unmount } = render(
        <RenderTerminal client={{ protocol: 7 } as CmuxClient} surface={7} active error={null} onError={vi.fn()} />,
      );
      const canvases = [...container.querySelectorAll<HTMLCanvasElement>("[data-graphic-placement]")];

      expect(context.putImageData).toHaveBeenCalledWith(
        expect.objectContaining({ width: 2, height: 2 }),
        -1,
        -0,
        1,
        0,
        1,
        2,
      );
      unmount();
      expect(canvases.every((canvas) => canvas.width === 0 && canvas.height === 0)).toBe(true);
    } finally {
      getContext.mockRestore();
      vi.unstubAllGlobals();
    }
  });
});
