import { act, fireEvent, render, waitFor } from "@testing-library/react";
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

  it("exposes split state and resizes with the orientation arrow keys", async () => {
    const onSetSplitRatio = vi.fn(async () => true);
    const props = terminalPaneProps(onSetSplitRatio);
    const { getByRole } = render(<TerminalPane {...props} screen={screenView(0.5)} />);
    const divider = getByRole("separator");

    expect(divider).toHaveAttribute("tabindex", "0");
    expect(divider).toHaveAttribute("aria-valuemin", "5");
    expect(divider).toHaveAttribute("aria-valuemax", "95");
    expect(divider).toHaveAttribute("aria-valuenow", "50");

    fireEvent.keyDown(divider, { key: "ArrowRight" });

    await waitFor(() => expect(onSetSplitRatio).toHaveBeenCalledWith(42, 0.55));
  });

  it("queues repeated arrow-key adjustments without dropping input", async () => {
    const onSetSplitRatio = vi.fn(async (_split: number, _ratio: number) => true);
    const props = terminalPaneProps(onSetSplitRatio);
    const { getByRole } = render(<TerminalPane {...props} screen={screenView(0.5)} />);
    const divider = getByRole("separator");

    fireEvent.keyDown(divider, { key: "ArrowRight" });
    fireEvent.keyDown(divider, { key: "ArrowRight" });
    fireEvent.keyDown(divider, { key: "ArrowRight" });

    await waitFor(() => expect(onSetSplitRatio).toHaveBeenCalledTimes(1));
    expect(onSetSplitRatio.mock.calls[0]?.[0]).toBe(42);
    expect(onSetSplitRatio.mock.calls[0]?.[1]).toBeCloseTo(0.65);
  });

  it("debounces locally completed key repeats into one authoritative commit", async () => {
    vi.useFakeTimers();
    try {
      const onSetSplitRatio = vi.fn(async (_split: number, _ratio: number) => true);
      const props = terminalPaneProps(onSetSplitRatio);
      const { getByRole } = render(<TerminalPane {...props} screen={screenView(0.5)} />);
      const divider = getByRole("separator");

      fireEvent.keyDown(divider, { key: "ArrowRight" });
      await act(async () => Promise.resolve());
      fireEvent.keyDown(divider, { key: "ArrowRight" });
      await act(async () => Promise.resolve());
      fireEvent.keyDown(divider, { key: "ArrowRight" });
      await act(async () => Promise.resolve());

      expect(onSetSplitRatio).not.toHaveBeenCalled();
      await act(async () => vi.advanceTimersByTimeAsync(99));
      expect(onSetSplitRatio).not.toHaveBeenCalled();
      await act(async () => vi.advanceTimersByTimeAsync(1));
      expect(onSetSplitRatio).toHaveBeenCalledTimes(1);
      expect(onSetSplitRatio.mock.calls[0]?.[1]).toBeCloseTo(0.65);
    } finally {
      vi.useRealTimers();
    }
  });

  it("preserves a reversal queued behind an in-flight keyboard adjustment", async () => {
    vi.useFakeTimers();
    let resolveFirst: (succeeded: boolean) => void = (_succeeded) => {
      throw new Error("first request was not started");
    };
    const onSetSplitRatio = vi.fn((_split: number, ratio: number) => {
      if (ratio !== 0.55) return Promise.resolve(true);
      return new Promise<boolean>((resolve) => {
        resolveFirst = resolve;
      });
    });
    try {
      const props = terminalPaneProps(onSetSplitRatio);
      const { getByRole } = render(<TerminalPane {...props} screen={screenView(0.5)} />);
      const divider = getByRole("separator");

      fireEvent.keyDown(divider, { key: "ArrowRight" });
      await act(async () => vi.advanceTimersByTimeAsync(100));
      expect(onSetSplitRatio).toHaveBeenCalledTimes(1);
      fireEvent.keyDown(divider, { key: "ArrowLeft" });
      await act(async () => vi.advanceTimersByTimeAsync(100));
      expect(onSetSplitRatio).toHaveBeenCalledTimes(1);
      await act(async () => resolveFirst(true));
      await act(async () => vi.advanceTimersByTimeAsync(100));

      expect(onSetSplitRatio).toHaveBeenCalledTimes(2);
      expect(onSetSplitRatio.mock.calls[1]?.[0]).toBe(42);
      expect(onSetSplitRatio.mock.calls[1]?.[1]).toBeCloseTo(0.5);
    } finally {
      vi.useRealTimers();
    }
  });

  it("unlocks pointer dragging after the server confirms a keyboard adjustment", async () => {
    const onSetSplitRatio = vi.fn(async () => true);
    const props = terminalPaneProps(onSetSplitRatio);
    const { getByRole, rerender } = render(<TerminalPane {...props} screen={screenView(0.5)} />);
    const divider = getByRole("separator");
    const setPointerCapture = vi.fn();
    Object.defineProperty(divider, "setPointerCapture", { value: setPointerCapture });

    fireEvent.keyDown(divider, { key: "ArrowRight" });
    await waitFor(() => expect(onSetSplitRatio).toHaveBeenCalledWith(42, 0.55));
    rerender(<TerminalPane {...props} screen={screenView(0.55)} />);
    fireEvent.pointerDown(getByRole("separator"), {
      pointerId: 12,
      pointerType: "mouse",
      button: 0,
      clientX: 220,
    });

    expect(setPointerCapture).toHaveBeenCalledWith(12);
  });

  it("cancels a queued keyboard adjustment when its split is replaced", async () => {
    let resolveFirst: (succeeded: boolean) => void = (_succeeded) => {
      throw new Error("first request was not started");
    };
    const onSetSplitRatio = vi.fn(() => new Promise<boolean>((resolve) => {
      resolveFirst = resolve;
    }));
    const props = terminalPaneProps(onSetSplitRatio);
    const { getByRole, rerender } = render(<TerminalPane {...props} screen={screenView(0.5)} />);
    const divider = getByRole("separator");

    fireEvent.keyDown(divider, { key: "ArrowRight" });
    fireEvent.keyDown(divider, { key: "ArrowRight" });
    await waitFor(() => expect(onSetSplitRatio).toHaveBeenCalledTimes(1));

    const replacement = screenView(0.5);
    if (replacement.layout?.type !== "split") throw new Error("expected split layout");
    replacement.layout.split = 43;
    rerender(<TerminalPane {...props} screen={replacement} />);
    await act(async () => resolveFirst(true));

    expect(onSetSplitRatio).toHaveBeenCalledTimes(1);
  });

  it("uses a later authoritative ratio after a keyboard transaction settles", async () => {
    const onSetSplitRatio = vi.fn(async (_split: number, _ratio: number) => true);
    const props = terminalPaneProps(onSetSplitRatio);
    const { getByRole, rerender } = render(<TerminalPane {...props} screen={screenView(0.5)} />);
    const divider = getByRole("separator");

    fireEvent.keyDown(divider, { key: "ArrowRight" });
    fireEvent.keyDown(divider, { key: "ArrowRight" });
    fireEvent.keyDown(divider, { key: "ArrowRight" });
    await waitFor(() => expect(onSetSplitRatio).toHaveBeenCalledTimes(1));
    expect(onSetSplitRatio.mock.calls[0]?.[1]).toBeCloseTo(0.65);

    rerender(<TerminalPane {...props} screen={screenView(0.65)} />);
    rerender(<TerminalPane {...props} screen={screenView(0.55)} />);
    const updatedDivider = getByRole("separator");
    expect(updatedDivider).toHaveAttribute("aria-valuenow", "55");

    fireEvent.keyDown(updatedDivider, { key: "ArrowRight" });
    await waitFor(() => expect(onSetSplitRatio).toHaveBeenCalledTimes(2));
    expect(onSetSplitRatio.mock.calls[1]?.[1]).toBeCloseTo(0.6);
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

  it("bases a keyboard nudge on a pending pointer ratio", async () => {
    let resolvePointer: (succeeded: boolean) => void = (_succeeded) => {
      throw new Error("pointer request was not started");
    };
    const onSetSplitRatio = vi.fn((_split: number, ratio: number) => {
      if (ratio !== 0.75) return Promise.resolve(true);
      return new Promise<boolean>((resolve) => {
        resolvePointer = resolve;
      });
    });
    const props = terminalPaneProps(onSetSplitRatio);
    const { getByRole } = render(<TerminalPane {...props} screen={screenView(0.5)} />);
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

    fireEvent.pointerDown(divider, { pointerId: 13, pointerType: "mouse", button: 0, clientX: 200 });
    fireEvent.pointerUp(divider, { pointerId: 13, pointerType: "mouse", button: 0, clientX: 300 });
    await waitFor(() => expect(onSetSplitRatio).toHaveBeenCalledWith(42, 0.75));

    fireEvent.keyDown(divider, { key: "ArrowRight" });
    await waitFor(() => expect(onSetSplitRatio).toHaveBeenCalledTimes(2));
    expect(onSetSplitRatio.mock.calls[1]?.[1]).toBeCloseTo(0.8);
    resolvePointer(true);
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

describe("TerminalPane stacks", () => {
  it("renders collapsed title rows around the expanded pane", () => {
    const props = terminalPaneProps(vi.fn(async () => true));
    props.client = { protocol: 9 } as CmuxClient;
    const screen: ScreenView = {
      ...screenView(0.5),
      layout: { type: "stack", panes: [1, 2, 3], expanded: 2 },
      activePane: 2,
      panes: [1, 2, 3].map((id) => ({
        id,
        name: null,
        active_tab: 0,
        tabs: [{
          surface: id + 10,
          kind: "pty" as const,
          browser_source: null,
          name: null,
          title: `shell ${id}`,
          size: { cols: 80, rows: 24 },
          dead: false,
        }],
      })),
    };

    const { container, queryByRole, rerender } = render(<TerminalPane {...props} screen={screen} />);
    const stack = container.querySelector(".pane-stack");
    expect(stack).toBeInTheDocument();
    expect(stack?.querySelectorAll(".pane-leaf.collapsed")).toHaveLength(2);
    expect(stack?.querySelectorAll(":scope > .pane-leaf.expanded")).toHaveLength(1);
    expect(stack?.querySelectorAll(":scope > .stack-pane-headers")).toHaveLength(2);
    expect(stack?.children[0]).toHaveClass("stack-pane-headers", "before");
    expect(stack?.children[1]).toHaveClass("expanded");
    expect(stack?.children[2]).toHaveClass("stack-pane-headers", "after");
    expect(attachedTerminal.renderHook).toHaveBeenCalledTimes(1);

    const firstHeader = stack!.children[0]!.querySelector(".stack-pane-header")!;
    fireEvent.click(firstHeader);
    expect(props.onSelectPane).toHaveBeenCalledWith(1);

    props.onSelectPane.mockClear();
    fireEvent.contextMenu(firstHeader);
    expect(props.onSelectPane).not.toHaveBeenCalled();

    fireEvent.focusIn(stack!.children[2]!.querySelector(".stack-pane-header")!);
    expect(props.onSelectPane).not.toHaveBeenCalled();

    fireEvent.click(stack!.children[2]!.querySelector(".stack-pane-header")!);
    expect(props.onSelectPane).toHaveBeenCalledWith(3);

    fireEvent.contextMenu(stack!.querySelector(".pane-leaf.expanded .terminal-panel")!, {
      clientX: 10,
      clientY: 10,
    });
    expect(queryByRole("menu")).toBeInTheDocument();
    rerender(
      <TerminalPane
        {...props}
        screen={{
          ...screen,
          activePane: 3,
          layout: { type: "stack", panes: [1, 2, 3], expanded: 3 },
        }}
      />,
    );
    expect(queryByRole("menu")).toBeNull();
    expect(document.activeElement).toBe(
      container.querySelector(".pane-leaf.expanded [data-render-input]"),
    );
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

describe("TerminalPane stack indexing", () => {
  it("does not scan the full pane list for every stack row", () => {
    const panes: ScreenView["panes"] = Array.from({ length: 13 }, (_, index) => ({
      id: index + 1,
      name: null,
      active_tab: 0,
      tabs: [{
        surface: index + 100,
        kind: "pty" as const,
        browser_source: null,
        name: null,
        title: `pane ${index + 1}`,
        size: { cols: 80, rows: 24 },
        dead: false,
      }],
    }));
    let findCalls = 0;
    const trackedPanes = new Proxy(panes, {
      get(target, property, receiver) {
        if (property === "find") findCalls += 1;
        return Reflect.get(target, property, receiver);
      },
    });
    const screen: ScreenView = {
      ...screenView(0.5),
      panes: trackedPanes,
      layout: {
        type: "stack",
        panes: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13],
        expanded: 7,
      },
      activePane: 7,
    };

    render(<TerminalPane {...terminalPaneProps(vi.fn(async () => true))} screen={screen} />);

    expect(findCalls).toBe(0);
  });
});
