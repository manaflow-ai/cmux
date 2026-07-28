import { render, waitFor } from "@testing-library/react";
import { useCallback } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { CmuxClient, DecodedAttachEvent } from "cmux/browser";
import { useAttachedTerminal } from "../src/hooks/useAttachedTerminal";

const fitDimensions = { cols: 80, rows: 24 };
const terminalMocks = vi.hoisted(() => ({
  instances: [] as Array<{
    options: Record<string, unknown>;
    writes: Array<string | Uint8Array>;
  }>,
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
    writes: Array<string | Uint8Array> = [];

    constructor(options: Record<string, unknown>) {
      this.options = options;
      terminalMocks.instances.push(this);
    }

    loadAddon() {}
    open() {}
    reset() {}
    resize() {}
    write(data: string | Uint8Array, callback?: () => void) {
      this.writes.push(data);
      if (data instanceof Uint8Array && data.length > 0) {
        this.options.theme = {
          ...(this.options.theme as Record<string, unknown>),
          red: "#replay-red",
          extendedAnsi: ["#replay-extended"],
        };
        this.options.cursorStyle = "underline";
        this.options.cursorBlink = true;
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
        colors: {
          palette: { "1": "#112233", "20": "#445566" },
          cursor_style: "bar",
          cursor_blink: false,
        },
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
      {
        event: "resized",
        surface: 7,
        cols: 100,
        rows: 30,
        data: new Uint8Array([2]),
        replay: new Uint8Array([2]),
        colors: {
          fg: null,
          bg: null,
          cursor: null,
          selection_bg: null,
          selection_fg: null,
          palette: { "3": "#abcdef", "22": "#fedcba" },
          cursor_style: "bar",
          cursor_blink: false,
        },
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
      expect(terminalMocks.instances[0]?.writes[1]).toBe(
        "\x1b]104\x1b\\\x1b]4;1;#112233\x1b\\\x1b]4;20;#445566\x1b\\",
      );
    });
    stream.release();
    await waitFor(() => {
      expect(terminalMocks.instances[0]?.writes[2]).toBe(
        "\x1b]104\x1b\\\x1b]4;2;#778899\x1b\\\x1b]4;21;#aabbcc\x1b\\",
      );
      expect(terminalMocks.instances[0]?.writes[3]).toEqual(new Uint8Array([2]));
      expect(terminalMocks.instances[0]?.writes[4]).toBe(
        "\x1b]104\x1b\\\x1b]4;3;#abcdef\x1b\\\x1b]4;22;#fedcba\x1b\\",
      );
      const theme = terminalMocks.instances[0]?.options.theme as Record<string, unknown>;
      expect(theme.red).not.toBe("#replay-red");
      expect(terminalMocks.instances[0]?.options.cursorStyle).toBe("underline");
      expect(terminalMocks.instances[0]?.options.cursorBlink).toBe(true);
    });
    view.unmount();
  });

  it("reapplies authoritative palette after RIS resets the browser mirror", async () => {
    globalThis.ResizeObserver = class {
      observe() {}
      unobserve() {}
      disconnect() {}
    };
    const client = {
      attachSurface: vi.fn(async () => new TestStream([
        {
          event: "vt-state",
          surface: 7,
          cols: 80,
          rows: 24,
          data: new Uint8Array(),
          colors: { palette: { "4": "#112233" } },
        },
        { event: "output", surface: 7, data: new Uint8Array([0x1b, 0x63]) },
        {
          event: "colors-changed",
          surface: 7,
          fg: null,
          bg: null,
          cursor: null,
          selection_bg: null,
          selection_fg: null,
          palette: { "4": "#112233" },
        },
      ])),
      resizeSurface: vi.fn(async () => ({ accepted: true, reservation_id: null })),
      releaseSurfaceSize: vi.fn(async () => ({})),
      send: vi.fn(async () => ({})),
    } as unknown as CmuxClient;

    const view = render(<Harness client={client} />);

    await waitFor(() => {
      expect(terminalMocks.instances[0]?.writes).toEqual([
        new Uint8Array(),
        "\x1b]104\x1b\\\x1b]4;4;#112233\x1b\\",
        new Uint8Array([0x1b, 0x63]),
        "\x1b]104\x1b\\\x1b]4;4;#112233\x1b\\",
      ]);
    });
    view.unmount();
  });

  it("preserves replay palette when a protocol-v6 server omits sparse metadata", async () => {
    globalThis.ResizeObserver = class {
      observe() {}
      unobserve() {}
      disconnect() {}
    };
    const client = {
      attachSurface: vi.fn(async () => new TestStream([
        {
          event: "vt-state",
          surface: 7,
          cols: 80,
          rows: 24,
          data: new Uint8Array([1]),
          colors: { fg: "#eeeeee" },
        },
      ])),
      resizeSurface: vi.fn(async () => ({ accepted: true, reservation_id: null })),
      releaseSurfaceSize: vi.fn(async () => ({})),
      send: vi.fn(async () => ({})),
    } as unknown as CmuxClient;

    const view = render(<Harness client={client} />);

    await waitFor(() => {
      expect(terminalMocks.instances[0]?.writes).toEqual([
        "\x1b]10;#eeeeee\x1b\\",
        new Uint8Array([1]),
      ]);
      const theme = terminalMocks.instances[0]?.options.theme as Record<string, unknown>;
      expect(theme.foreground).not.toBe("#eeeeee");
      expect(theme.red).toBe("#replay-red");
    });
    view.unmount();
  });

  it("keeps live OSC colors out of xterm's restore theme", async () => {
    globalThis.ResizeObserver = class {
      observe() {}
      unobserve() {}
      disconnect() {}
    };
    const restoreForeground = new Uint8Array([0x1b, 0x5d, 0x31, 0x31, 0x30, 0x1b, 0x5c]);
    const client = {
      attachSurface: vi.fn(async () => new TestStream([
        {
          event: "vt-state",
          surface: 7,
          cols: 80,
          rows: 24,
          data: new Uint8Array(),
          colors: {},
        },
        {
          event: "colors-changed",
          surface: 7,
          fg: "#112233",
          bg: "#223344",
          cursor: "#334455",
          selection_bg: null,
          selection_fg: null,
          palette: {},
        },
        { event: "output", surface: 7, data: restoreForeground },
      ])),
      resizeSurface: vi.fn(async () => ({ accepted: true, reservation_id: null })),
      releaseSurfaceSize: vi.fn(async () => ({})),
      send: vi.fn(async () => ({})),
    } as unknown as CmuxClient;

    const view = render(<Harness client={client} />);

    await waitFor(() => {
      expect(terminalMocks.instances[0]?.writes).toEqual([
        new Uint8Array(),
        "\x1b]10;#112233\x1b\\\x1b]11;#223344\x1b\\\x1b]12;#334455\x1b\\",
        "\x1b]104\x1b\\",
        restoreForeground,
      ]);
      const theme = terminalMocks.instances[0]?.options.theme as Record<string, unknown>;
      expect(theme.foreground).not.toBe("#112233");
      expect(theme.background).not.toBe("#223344");
      expect(theme.cursor).not.toBe("#334455");
      expect(document.querySelector<HTMLElement>(".terminal-stage")?.style.getPropertyValue(
        "--surface-background",
      )).toBe("#223344");
    });
    view.unmount();
  });
});
