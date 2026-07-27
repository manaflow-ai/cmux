import { render, waitFor } from "@testing-library/react";
import { useCallback } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { CmuxClient, RenderAttachEvent, RenderCursor } from "cmux/browser";
import { useRenderTerminal } from "../src/hooks/useRenderTerminal";

let recoveryDelay = 60_000;

vi.mock("../src/lib/attachRecovery", () => ({
  ATTACH_RECOVERY_STABLE_MS: 60_000,
  attachRecoveryDelay: () => recoveryDelay,
}));

let hostWidth = 800;

class TestStream {
  private index = 0;
  readonly close = vi.fn();

  constructor(private readonly events: RenderAttachEvent[]) {}

  async next(): Promise<RenderAttachEvent> {
    const event = this.events[this.index++];
    if (event !== undefined) return event;
    return await new Promise<RenderAttachEvent>(() => {});
  }
}

function Harness({ client }: { client: CmuxClient }) {
  const onError = useCallback((error: Error) => {
    throw error;
  }, []);
  const { terminalRef } = useRenderTerminal({ client, surface: 7, active: true, onError });
  const hostRef = useCallback((node: HTMLDivElement | null) => {
    if (node !== null) {
      Object.defineProperty(node, "clientWidth", { configurable: true, get: () => hostWidth });
      Object.defineProperty(node, "clientHeight", { configurable: true, get: () => 480 });
      const probe = node.querySelector<HTMLElement>("[data-render-probe]")!;
      probe.getBoundingClientRect = () => ({
        width: 10,
        height: 20,
        x: 0,
        y: 0,
        top: 0,
        right: 10,
        bottom: 20,
        left: 0,
        toJSON: () => ({}),
      });
    }
    terminalRef(node);
  }, [terminalRef]);

  return (
    <div className="terminal-stage">
      <div ref={hostRef}>
        <div data-render-scroll />
        <textarea data-render-input />
        <span data-render-probe>W</span>
      </div>
    </div>
  );
}

describe("render terminal sizing", () => {
  const originalResizeObserver = globalThis.ResizeObserver;

  afterEach(() => {
    globalThis.ResizeObserver = originalResizeObserver;
    hostWidth = 800;
    recoveryDelay = 60_000;
  });

  it("reports an unchanged local fit again after overflow reattachment", async () => {
    recoveryDelay = 0;
    globalThis.ResizeObserver = class {
      observe() {}
      unobserve() {}
      disconnect() {}
    };
    const cursor: RenderCursor = {
      x: 0,
      y: 0,
      style: "bar",
      blink: true,
      visible: true,
      color: null,
    };
    const streams = [
      new TestStream([
        {
          event: "render-state",
          surface: 7,
          size: { cols: 100, rows: 30 },
          cursor,
          default_fg: "#f8f8f2",
          default_bg: "#272822",
          scrollback_rows: 0,
          rows: [],
        },
        { event: "overflow", scope: "surface", surface: 7, error: "subscriber fell behind" },
      ]),
      new TestStream([
        {
          event: "render-state",
          surface: 7,
          size: { cols: 100, rows: 30 },
          cursor,
          default_fg: "#f8f8f2",
          default_bg: "#272822",
          scrollback_rows: 0,
          rows: [],
        },
      ]),
    ];
    const client = {
      attachSurface: vi.fn(async () => streams.shift()!),
      resizeSurface: vi.fn(async () => ({ accepted: true, reservation_id: null })),
      releaseSurfaceSize: vi.fn(async () => ({})),
    } as unknown as CmuxClient;

    const view = render(<Harness client={client} />);

    await waitFor(() => expect(client.attachSurface).toHaveBeenCalledTimes(2), { timeout: 10_000 });
    await waitFor(() => expect(client.resizeSurface).toHaveBeenCalledTimes(2), { timeout: 10_000 });
    expect(client.resizeSurface).toHaveBeenNthCalledWith(1, 7, 80, 24);
    expect(client.resizeSurface).toHaveBeenNthCalledWith(2, 7, 80, 24);
    view.unmount();
    expect(client.releaseSurfaceSize).toHaveBeenCalledWith(7);
  }, 20_000);

  it("does not publish a viewer resize while the attachment is disconnected", async () => {
    let resizeCallback: ResizeObserverCallback | null = null;
    globalThis.ResizeObserver = class {
      constructor(callback: ResizeObserverCallback) {
        resizeCallback = callback;
      }
      observe() {}
      unobserve() {}
      disconnect() {}
    };
    const cursor: RenderCursor = {
      x: 0,
      y: 0,
      style: "bar",
      blink: true,
      visible: true,
      color: null,
    };
    const stream = new TestStream([
      {
        event: "render-state",
        surface: 7,
        size: { cols: 100, rows: 30 },
        cursor,
        default_fg: "#f8f8f2",
        default_bg: "#272822",
        scrollback_rows: 0,
        rows: [],
      },
      { event: "overflow", scope: "surface", surface: 7, error: "subscriber fell behind" },
    ]);
    const client = {
      attachSurface: vi.fn(async () => stream),
      resizeSurface: vi.fn(async () => ({ accepted: true, reservation_id: null })),
      releaseSurfaceSize: vi.fn(async () => ({})),
    } as unknown as CmuxClient;

    render(<Harness client={client} />);

    await waitFor(() => expect(client.resizeSurface).toHaveBeenCalledWith(7, 80, 24));
    await waitFor(() => expect(stream.close).toHaveBeenCalledTimes(1));
    hostWidth = 900;
    resizeCallback!([], {} as ResizeObserver);
    await new Promise((resolve) => setTimeout(resolve, 150));

    expect(client.resizeSurface).toHaveBeenCalledTimes(1);
  });

  it("releases sizing when the render consumer terminates", async () => {
    globalThis.ResizeObserver = class {
      observe() {}
      unobserve() {}
      disconnect() {}
    };
    const client = {
      attachSurface: vi.fn(async () => new TestStream([
        { event: "detached", surface: 7 },
      ])),
      resizeSurface: vi.fn(async () => ({ accepted: true, reservation_id: null })),
      releaseSurfaceSize: vi.fn(async () => ({})),
    } as unknown as CmuxClient;

    render(<Harness client={client} />);

    await waitFor(() => expect(client.releaseSurfaceSize).toHaveBeenCalledWith(7));
  });
});
