import { fireEvent, render } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { CmuxClient } from "cmux/browser";
import type { RenderModel } from "../src/lib/renderModel";
import { renderAttrs } from "../src/lib/renderStyles";
import { RenderTerminal } from "../src/components/RenderTerminal";

const renderHook = vi.hoisted(() => ({
  focused: true,
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
    model,
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
});
