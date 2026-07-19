import { render, waitFor } from "@testing-library/react";
import { useCallback } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { CmuxClient, DecodedAttachEvent } from "cmux/browser";
import { useAttachedTerminal } from "../src/hooks/useAttachedTerminal";

const fitDimensions = { cols: 80, rows: 24 };
const terminalMocks = vi.hoisted(() => ({
  instances: [] as Array<{ options: Record<string, unknown> }>,
}));

vi.mock("@xterm/addon-fit", () => ({
  FitAddon: class {
    proposeDimensions() {
      return fitDimensions;
    }
  },
}));

vi.mock("@xterm/xterm", () => ({
  Terminal: class {
    options: Record<string, unknown>;

    constructor(options: Record<string, unknown>) {
      this.options = options;
      terminalMocks.instances.push(this);
    }

    loadAddon() {}
    open() {}
    reset() {}
    resize() {}
    write(data: Uint8Array, callback?: () => void) {
      if (data.length > 0) {
        this.options.theme = {
          ...(this.options.theme as Record<string, unknown>),
          red: "#replay-red",
          extendedAnsi: ["#replay-extended"],
        };
      }
      callback?.();
    }
    focus() {}
    dispose() {}
    onData() {
      return { dispose() {} };
    }
  },
}));

vi.mock("../src/lib/webglRenderer", () => ({
  tryLoadWebglRenderer: () => null,
}));

class TestStream {
  private index = 0;

  constructor(private readonly events: DecodedAttachEvent[]) {}

  async next(): Promise<DecodedAttachEvent> {
    const event = this.events[this.index++];
    if (event !== undefined) return event;
    return await new Promise<DecodedAttachEvent>(() => {});
  }

  close() {}
}

class GatedTestStream extends TestStream {
  private releaseNext: (() => void) | undefined;
  private reads = 0;

  override async next(): Promise<DecodedAttachEvent> {
    if (this.reads++ === 1) {
      await new Promise<void>((resolve) => {
        this.releaseNext = resolve;
      });
    }
    return await super.next();
  }

  release() {
    this.releaseNext?.();
  }
}

function Harness({ client }: { client: CmuxClient }) {
  const onError = useCallback((error: Error) => {
    throw error;
  }, []);
  const { terminalRef } = useAttachedTerminal({ client, surface: 7, onError });
  return <div className="terminal-stage"><div ref={terminalRef} /></div>;
}

describe("attached terminal sizing", () => {
  const originalResizeObserver = globalThis.ResizeObserver;

  afterEach(() => {
    globalThis.ResizeObserver = originalResizeObserver;
    terminalMocks.instances.length = 0;
  });

  it("reports an unchanged local fit again after overflow reattachment", async () => {
    globalThis.ResizeObserver = class {
      observe() {}
      unobserve() {}
      disconnect() {}
    };
    const streams = [
      new TestStream([
        { event: "vt-state", surface: 7, cols: 100, rows: 30, data: new Uint8Array(), colors: {} },
        { event: "overflow", scope: "surface", surface: 7, error: "subscriber fell behind" },
      ]),
      new TestStream([
        { event: "vt-state", surface: 7, cols: 100, rows: 30, data: new Uint8Array(), colors: {} },
      ]),
    ];
    const client = {
      attachSurface: vi.fn(async () => streams.shift()!),
      resizeSurface: vi.fn(async () => ({ accepted: true, reservation_id: null })),
      releaseSurfaceSize: vi.fn(async () => ({})),
      send: vi.fn(async () => ({})),
    } as unknown as CmuxClient;

    const view = render(<Harness client={client} />);

    await waitFor(() => expect(client.attachSurface).toHaveBeenCalledTimes(2));
    await waitFor(() => expect(client.resizeSurface).toHaveBeenCalledTimes(2));
    expect(client.resizeSurface).toHaveBeenNthCalledWith(1, 7, 80, 24);
    expect(client.resizeSurface).toHaveBeenNthCalledWith(2, 7, 80, 24);
    view.unmount();
    expect(client.releaseSurfaceSize).toHaveBeenCalledWith(7);
  });

  it("releases sizing when the attach consumer terminates", async () => {
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
      send: vi.fn(async () => ({})),
    } as unknown as CmuxClient;

    render(<Harness client={client} />);

    await waitFor(() => expect(client.releaseSurfaceSize).toHaveBeenCalledWith(7));
  });

  it("applies sparse palette overrides after replay and on color changes", async () => {
    globalThis.ResizeObserver = class {
      observe() {}
      unobserve() {}
      disconnect() {}
    };
    const stream = new GatedTestStream([
      {
        event: "vt-state",
        surface: 7,
        cols: 80,
        rows: 24,
        data: new Uint8Array([1]),
        colors: { palette: { "1": "#112233", "20": "#445566" } },
      },
      {
        event: "colors-changed",
        surface: 7,
        fg: null,
        bg: null,
        cursor: null,
        selection_bg: null,
        selection_fg: null,
        palette: { "2": "#778899", "21": "#aabbcc" },
      },
    ]);
    const client = {
      attachSurface: vi.fn(async () => stream),
      resizeSurface: vi.fn(async () => ({ accepted: true, reservation_id: null })),
      releaseSurfaceSize: vi.fn(async () => ({})),
      send: vi.fn(async () => ({})),
    } as unknown as CmuxClient;

    const view = render(<Harness client={client} />);

    await waitFor(() => {
      const theme = terminalMocks.instances[0]?.options.theme as Record<string, unknown>;
      expect(theme.red).toBe("#112233");
      expect((theme.extendedAnsi as string[])[4]).toBe("#445566");
    });
    stream.release();
    await waitFor(() => {
      const theme = terminalMocks.instances[0]?.options.theme as Record<string, unknown>;
      expect(theme.green).toBe("#778899");
      expect((theme.extendedAnsi as string[])[5]).toBe("#aabbcc");
      expect(theme.red).not.toBe("#replay-red");
      expect((theme.extendedAnsi as string[])[4]).toBeUndefined();
    });
    view.unmount();
  });
});
