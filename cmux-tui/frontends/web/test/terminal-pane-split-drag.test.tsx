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
      split: 42,
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

function terminalPaneProps(onSetSplitRatio: (split: number, ratio: number) => Promise<boolean>) {
  return {
    client: null as CmuxClient | null,
    clients: [] as ClientInfo[],
    onRefreshClients: vi.fn(),
    onSetClientSizing: vi.fn(),
    onUseOnlyClientSizing: vi.fn(),
    onUseAllClientSizing: vi.fn(),
    onDetachClient: vi.fn(),
    onSelectTab: vi.fn(),
    onNewTab: vi.fn(),
    onSplit: vi.fn(),
    onSetSplitRatio,
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
    const onSetSplitRatio = vi.fn(async () => true);
    const props = terminalPaneProps(onSetSplitRatio);
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

    await waitFor(() => expect(onSetSplitRatio).toHaveBeenCalledTimes(1));
    expect(onSetSplitRatio).toHaveBeenCalledWith(42, 0.75);

    rerender(<TerminalPane {...props} screen={screenView(0.75)} />);
    rerender(<TerminalPane {...props} screen={screenView(0.6)} />);
    expect(container.querySelector<HTMLElement>(".pane-leaf")?.style.flex).toContain("60%");
  });

  it("rolls the preview back when set-ratio fails", async () => {
    const onSetSplitRatio = vi.fn(async () => false);
    const props = terminalPaneProps(onSetSplitRatio);
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
      expect(onSetSplitRatio).toHaveBeenCalledTimes(1);
      expect(container.querySelector<HTMLElement>(".pane-leaf")?.style.flex).toContain("50%");
    });
  });

  it("cancels an active drag when the authoritative split is replaced", () => {
    const onSetSplitRatio = vi.fn(async () => true);
    const props = terminalPaneProps(onSetSplitRatio);
    const { getByRole, rerender } = render(<TerminalPane {...props} screen={screenView(0.5)} />);
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

    fireEvent.pointerDown(divider, { pointerId: 9, pointerType: "touch", clientX: 200 });
    const replacement = screenView(0.5);
    if (replacement.layout?.type !== "split") throw new Error("expected split layout");
    replacement.layout.split = 43;
    rerender(<TerminalPane {...props} screen={replacement} />);
    fireEvent.pointerUp(getByRole("separator"), {
      pointerId: 9,
      pointerType: "touch",
      clientX: 300,
    });

    expect(onSetSplitRatio).not.toHaveBeenCalled();
  });
});

describe("TerminalPane shared minimum size", () => {
  it("shows the exact surface viewers in the bottom-left border", () => {
    const props = terminalPaneProps(vi.fn(async () => true));
    props.clients = [
      {
        client: 1,
        transport: "ws",
        name: "browser",
        kind: "web",
        connected_seconds: 10,
        attached: [7],
        sizes: [{ surface: 7, cols: 120, rows: 30 }],
        self: true,
        size_participating: true,
      },
      {
        client: 2,
        transport: "unix",
        name: "small tui",
        kind: "tui",
        connected_seconds: 20,
        attached: [7],
        sizes: [{ surface: 7, cols: 80, rows: 40 }],
        self: false,
        size_participating: true,
      },
    ];

    const { getByRole } = render(<TerminalPane {...props} screen={terminalScreenView()} />);
    const trigger = getByRole("button", { name: "2 clients · 80×30 min" });
    fireEvent.click(trigger);
    fireEvent.click(getByRole("menuitem", { name: "Use all client sizes" }));

    expect(props.onRefreshClients).toHaveBeenCalledOnce();
    expect(props.onUseAllClientSizing).toHaveBeenCalledOnce();
  });

  it("uses the tmux fallback minimum when every attached viewer is excluded", () => {
    const props = terminalPaneProps(vi.fn(async () => true));
    props.clients = [
      {
        client: 1,
        transport: "ws",
        name: "browser",
        kind: "web",
        connected_seconds: 10,
        attached: [7],
        sizes: [{ surface: 7, cols: 120, rows: 30 }],
        self: true,
        size_participating: false,
      },
      {
        client: 2,
        transport: "unix",
        name: "small tui",
        kind: "tui",
        connected_seconds: 20,
        attached: [7],
        sizes: [{ surface: 7, cols: 80, rows: 40 }],
        self: false,
        size_participating: false,
      },
    ];

    const { getByRole } = render(<TerminalPane {...props} screen={terminalScreenView()} />);
    expect(getByRole("button", { name: "2 clients · 80×30 min" })).toBeInTheDocument();
  });

  it("does not show clients viewing another surface on this pane", () => {
    const props = terminalPaneProps(vi.fn(async () => true));
    props.clients = [
      {
        client: 1,
        transport: "ws",
        name: "browser",
        kind: "web",
        connected_seconds: 10,
        attached: [7],
        sizes: [{ surface: 7, cols: 120, rows: 30 }],
        self: true,
        size_participating: true,
      },
      {
        client: 2,
        transport: "unix",
        name: "other tab",
        kind: "tui",
        connected_seconds: 20,
        attached: [8],
        sizes: [{ surface: 8, cols: 80, rows: 40 }],
        self: false,
        size_participating: true,
      },
    ];

    const { queryByRole } = render(<TerminalPane {...props} screen={terminalScreenView()} />);
    expect(queryByRole("button", { name: /clients ·/ })).not.toBeInTheDocument();
  });

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
        size_participating: true,
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
        size_participating: true,
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
      size_participating: true,
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
