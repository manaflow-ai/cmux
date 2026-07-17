import { fireEvent, render, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ClientInfo, CmuxClient } from "cmux/browser";
import { TerminalPane } from "../src/components/TerminalPane";
import type { ScreenView } from "../src/lib/tree";

const attachedTerminal = vi.hoisted(() => ({
  foreignSize: null as { cols: number; rows: number } | null,
  byteHook: vi.fn(),
  renderHook: vi.fn(),
}));

vi.mock("../src/hooks/useAttachedTerminal", () => ({
  useAttachedTerminal: () => {
    attachedTerminal.byteHook();
    return {
      terminalRef: () => undefined,
      focused: false,
      foreignSize: attachedTerminal.foreignSize,
    };
  },
}));

vi.mock("../src/hooks/useRenderTerminal", () => ({
  useRenderTerminal: () => {
    attachedTerminal.renderHook();
    return {
      terminalRef: () => undefined,
      focused: false,
      foreignSize: attachedTerminal.foreignSize,
      model: null,
      history: { active: false, loading: false, total: 0, rows: [] },
      backToLive: vi.fn(),
      sendKey: vi.fn(),
      sendText: vi.fn(),
    };
  },
}));

beforeEach(() => {
  attachedTerminal.foreignSize = null;
  attachedTerminal.byteHook.mockClear();
  attachedTerminal.renderHook.mockClear();
});

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
    client: null as CmuxClient | null,
    clients: [] as ClientInfo[],
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

function terminalScreenView(): ScreenView {
  return {
    ...screenView(0.5),
    layout: { type: "leaf", pane: 1 },
    panes: [{
      id: 1,
      name: null,
      active_tab: 0,
      tabs: [{
        surface: 7,
        kind: "pty",
        browser_source: null,
        name: null,
        title: "shell",
        size: { cols: 126, rows: 38 },
        dead: false,
      }],
    }],
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

describe("TerminalPane shared minimum size", () => {
  it("does not present the shared size as foreign ownership", () => {
    attachedTerminal.foreignSize = { cols: 126, rows: 38 };
    const props = terminalPaneProps(vi.fn(async () => true));
    props.clients = [
      {
        client: 1,
        transport: "ws",
        name: "This browser",
        kind: "web",
        connected_seconds: 10,
        attached: [7],
        sizes: [{ surface: 7, cols: 126, rows: 38 }],
        self: true,
      },
      {
        client: 2,
        transport: "unix",
        name: "office tmux",
        kind: "tui",
        connected_seconds: 20,
        attached: [7],
        sizes: [{ surface: 7, cols: 126, rows: 38 }],
        self: false,
      },
    ];

    const { container, queryByText, rerender } = render(<TerminalPane {...props} screen={terminalScreenView()} />);

    expect(container.querySelector(".terminal-host.foreign-sized")).not.toBeInTheDocument();
    expect(queryByText("shared size 126x38, limited by office tmux")).not.toBeInTheDocument();

    attachedTerminal.foreignSize = null;
    rerender(<TerminalPane {...props} screen={terminalScreenView()} />);
    expect(container.querySelector(".terminal-host.foreign-sized")).not.toBeInTheDocument();
    expect(container.querySelector(".foreign-size-hint")).not.toBeInTheDocument();
  });

  it("does not show an ownership hint for multiple limiting clients", () => {
    attachedTerminal.foreignSize = { cols: 126, rows: 38 };
    const props = terminalPaneProps(vi.fn(async () => true));
    props.clients = [2, 3].map((client) => ({
      client,
      transport: "ws" as const,
      name: `browser ${client}`,
      kind: "web",
      connected_seconds: 10,
      attached: [7],
      sizes: [{ surface: 7, cols: 126, rows: 38 }],
      self: false,
    }));

    const { queryByText } = render(<TerminalPane {...props} screen={terminalScreenView()} />);

    expect(queryByText("shared size 126x38 (smallest client)")).not.toBeInTheDocument();
  });
});

describe("TerminalPane renderer selection", () => {
  it("renders TUI cell chrome while keeping tabs as DOM buttons", () => {
    const props = terminalPaneProps(vi.fn(async () => true));
    props.client = { protocol: 7 } as CmuxClient;

    const { container, getByRole } = render(<TerminalPane {...props} screen={terminalScreenView()} />);

    expect(getByRole("button", { name: "1" })).toHaveClass("active");
    expect(container.querySelector(".tab-rail")).toHaveTextContent("▎");
    expect(container.querySelector(".tab-bar")?.textContent).toContain("┌");
    expect(container.querySelector(".tab-bar")?.textContent).toContain("┐");
    expect(container.querySelectorAll(".pane-side")).toHaveLength(2);
    expect(container.querySelector(".pane-bottom")?.textContent).toBe("└┘");
    expect(container.querySelector(".render-terminal-host")).toBeInTheDocument();
  });

  it("uses render mode only for the identified protocol 7 client", () => {
    const props = terminalPaneProps(vi.fn(async () => true));
    props.client = { protocol: 7 } as CmuxClient;

    const { rerender } = render(<TerminalPane {...props} screen={terminalScreenView()} />);
    expect(attachedTerminal.renderHook).toHaveBeenCalledTimes(1);
    expect(attachedTerminal.byteHook).not.toHaveBeenCalled();

    attachedTerminal.renderHook.mockClear();
    props.client = { protocol: 6 } as CmuxClient;
    rerender(<TerminalPane {...props} screen={terminalScreenView()} />);
    expect(attachedTerminal.byteHook).toHaveBeenCalledTimes(1);
    expect(attachedTerminal.renderHook).not.toHaveBeenCalled();
  });
});
