import { render, waitFor } from "@testing-library/react";
import { useCallback } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { CmuxClient, DecodedAttachEvent } from "cmux/browser";
import { useAttachedTerminal } from "../src/hooks/useAttachedTerminal";

const fitDimensions = { cols: 80, rows: 24 };

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
    }

    loadAddon() {}
    open() {}
    reset() {}
    resize() {}
    write() {}
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
});
