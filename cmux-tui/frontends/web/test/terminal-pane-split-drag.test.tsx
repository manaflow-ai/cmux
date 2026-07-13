import { fireEvent, render, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { TerminalPane } from "../src/components/TerminalPane";
import type { ScreenView } from "../src/lib/tree";

vi.mock("../src/hooks/useAttachedTerminal", () => ({
  useAttachedTerminal: () => ({ terminalRef: () => undefined, focused: false }),
}));

function screenView(ratio: number, zoomedPane: number | null = null): ScreenView {
  return {
    id: 10,
    workspaceId: 9,
    label: "test",
    active: true,
    pane: null,
    tab: null,
    panes: [],
    layout: {
      type: "split",
      dir: "right",
      ratio,
      a: { type: "leaf", pane: 1 },
      b: { type: "leaf", pane: 2 },
    },
    activePane: 1,
    zoomedPane,
    unread: false,
  };
}

function terminalPaneProps(onSetRatio: (pane: number, dir: "right" | "down", ratio: number) => Promise<boolean>) {
  return {
    client: null,
    onSelectTab: vi.fn(),
    onNewTab: vi.fn(),
    onSplit: vi.fn(),
    onSetRatio,
    onSelectPane: vi.fn(),
    onZoomPane: vi.fn(),
    onClosePane: vi.fn(),
    onCloseSurface: vi.fn(),
    onRenamePane: vi.fn(),
    onRenameSurface: vi.fn(),
  };
}

describe("TerminalPane split dividers", () => {
  it("renders a divider for a split and hides it while zoomed", () => {
    const props = terminalPaneProps(vi.fn(async () => true));
    const { queryByRole, rerender } = render(<TerminalPane {...props} screen={screenView(0.5)} />);
    expect(queryByRole("separator")).toHaveAttribute("aria-orientation", "vertical");
    rerender(<TerminalPane {...props} screen={screenView(0.5, 1)} />);
    expect(queryByRole("separator")).toBeNull();
  });

  it("previews pointer movement, commits once, and reconciles to server layout", async () => {
    const onSetRatio = vi.fn(async () => true);
    const props = terminalPaneProps(onSetRatio);
    const { getByRole, container, rerender } = render(
      <TerminalPane {...props} screen={screenView(0.5)} />,
    );
    const divider = getByRole("separator");
    const group = divider.parentElement as HTMLDivElement;
    group.getBoundingClientRect = () => ({
      x: 100,
      y: 50,
      left: 100,
      top: 50,
      right: 500,
      bottom: 250,
      width: 400,
      height: 200,
      toJSON: () => ({}),
    });
    Object.defineProperties(divider, {
      setPointerCapture: { value: vi.fn() },
      hasPointerCapture: { value: vi.fn(() => true) },
      releasePointerCapture: { value: vi.fn() },
    });

    fireEvent.pointerDown(divider, { pointerId: 7, pointerType: "touch", clientX: 300, clientY: 100 });
    fireEvent.pointerMove(divider, { pointerId: 7, pointerType: "touch", clientX: 400, clientY: 100 });
    expect(container.querySelector<HTMLElement>(".pane-leaf")?.style.flex).toContain("75%");
    fireEvent.pointerUp(divider, { pointerId: 7, pointerType: "touch", clientX: 400, clientY: 100 });

    await waitFor(() => expect(onSetRatio).toHaveBeenCalledTimes(1));
    expect(onSetRatio).toHaveBeenCalledWith(1, "right", 0.75);

    rerender(<TerminalPane {...props} screen={screenView(0.75)} />);
    rerender(<TerminalPane {...props} screen={screenView(0.6)} />);
    expect(container.querySelector<HTMLElement>(".pane-leaf")?.style.flex).toContain("60%");
  });

  it("rolls the preview back when set-ratio fails", async () => {
    const onSetRatio = vi.fn(async () => false);
    const props = terminalPaneProps(onSetRatio);
    const { getByRole, container } = render(<TerminalPane {...props} screen={screenView(0.5)} />);
    const divider = getByRole("separator");
    const group = divider.parentElement as HTMLDivElement;
    group.getBoundingClientRect = () => ({
      x: 0,
      y: 0,
      left: 0,
      top: 0,
      right: 400,
      bottom: 200,
      width: 400,
      height: 200,
      toJSON: () => ({}),
    });
    Object.defineProperties(divider, {
      setPointerCapture: { value: vi.fn() },
      hasPointerCapture: { value: vi.fn(() => false) },
    });

    fireEvent.pointerDown(divider, { pointerId: 8, pointerType: "mouse", button: 0, clientX: 200 });
    fireEvent.pointerUp(divider, { pointerId: 8, pointerType: "mouse", button: 0, clientX: 300 });

    await waitFor(() => {
      expect(onSetRatio).toHaveBeenCalledTimes(1);
      expect(container.querySelector<HTMLElement>(".pane-leaf")?.style.flex).toContain("50%");
    });
  });
});
