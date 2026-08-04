import { fireEvent, render, waitFor } from "@testing-library/react";
import { useCallback } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type {
  CmuxClient,
  ReadScrollbackResult,
  RenderAttachEvent,
  RenderCursor,
} from "cmux/raw";
import { useRenderTerminal } from "../src/hooks/useRenderTerminal";

class TestStream {
  private readonly events: RenderAttachEvent[] = [];
  private wake: ((event: RenderAttachEvent) => void) | null = null;
  readonly close = vi.fn(() => {
    this.deliver({ event: "detached", surface: 7 });
  });

  push(event: RenderAttachEvent) {
    this.deliver(event);
  }

  async next(): Promise<RenderAttachEvent> {
    const event = this.events.shift();
    if (event !== undefined) return event;
    return await new Promise<RenderAttachEvent>((resolve) => {
      this.wake = resolve;
    });
  }

  private deliver(event: RenderAttachEvent) {
    const wake = this.wake;
    if (wake === null) {
      this.events.push(event);
      return;
    }
    this.wake = null;
    wake(event);
  }
}

function Harness({ client }: { client: CmuxClient }) {
  const onError = useCallback((error: Error) => {
    throw error;
  }, []);
  const { terminalRef, history, model } = useRenderTerminal({
    client,
    surface: 7n,
    active: true,
    onError,
  });
  const hostRef = useCallback((node: HTMLDivElement | null) => {
    if (node !== null) {
      Object.defineProperty(node, "clientWidth", { configurable: true, value: 800 });
      Object.defineProperty(node, "clientHeight", { configurable: true, value: 480 });
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
    <div
      className="terminal-stage"
      data-history-active={history.active}
      data-history-epoch={history.epoch}
      data-model-epoch={model?.historyEpoch}
    >
      <div ref={hostRef} data-terminal-host>
        <div data-render-scroll />
        <textarea data-render-input />
        <span data-render-probe>W</span>
      </div>
    </div>
  );
}

function page(epoch: bigint): ReadScrollbackResult {
  return {
    start: 0,
    total: 4,
    epoch,
    rows: Array.from({ length: 4 }, (_, row) => ({
      row,
      runs: [{ text: `epoch ${epoch} row ${row}`, fg: null, bg: null, attrs: 0 }],
    })),
  };
}

describe("render terminal history", () => {
  const originalResizeObserver = globalThis.ResizeObserver;

  afterEach(() => {
    globalThis.ResizeObserver = originalResizeObserver;
  });

  it("coalesces epoch refreshes while history is active and preserves the scroll anchor", async () => {
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
    const stream = new TestStream();
    let finishSecondRead!: (result: ReadScrollbackResult) => void;
    const secondRead = new Promise<ReadScrollbackResult>((resolve) => {
      finishSecondRead = resolve;
    });
    const readScrollback = vi.fn()
      .mockResolvedValueOnce(page(1n))
      .mockReturnValueOnce(secondRead)
      .mockResolvedValueOnce(page(3n));
    const client = {
      attachSurface: vi.fn(async () => stream),
      readScrollback,
      resizeSurface: vi.fn(async () => ({ accepted: true, reservation_id: null })),
      releaseSurfaceSize: vi.fn(async () => ({})),
    } as unknown as CmuxClient;
    const view = render(<Harness client={client} />);
    stream.push({
      event: "render-state",
      surface: 7,
      size: { cols: 80, rows: 24 },
      cursor,
      default_fg: "#f8f8f2",
      default_bg: "#272822",
      scrollback_rows: 4,
      history_epoch: 1n,
      rows: [],
    });

    const stage = await waitFor(() => {
      const node = view.container.querySelector<HTMLElement>(".terminal-stage")!;
      expect(node).toHaveAttribute("data-model-epoch", "1");
      return node;
    });
    const host = view.container.querySelector<HTMLElement>("[data-terminal-host]")!;
    const scroller = view.container.querySelector<HTMLElement>("[data-render-scroll]")!;
    Object.defineProperty(scroller, "scrollHeight", { configurable: true, value: 800 });
    Object.defineProperty(scroller, "clientHeight", { configurable: true, value: 200 });
    fireEvent.wheel(host, { deltaY: -100 });
    await waitFor(() => {
      expect(stage).toHaveAttribute("data-history-active", "true");
      expect(stage).toHaveAttribute("data-history-epoch", "1");
    });
    expect(readScrollback).toHaveBeenCalledTimes(1);
    expect(readScrollback).toHaveBeenLastCalledWith(7n, 0, 4);
    await waitFor(() => expect(scroller.scrollTop).toBe(580));

    scroller.scrollTop = 240;
    stream.push({ event: "render-delta", surface: 7, cursor, full: false, history_epoch: 2n, rows: [] });
    await waitFor(() => expect(readScrollback).toHaveBeenCalledTimes(2));
    stream.push({ event: "render-delta", surface: 7, cursor, full: false, history_epoch: 3n, rows: [] });
    await Promise.resolve();
    expect(readScrollback).toHaveBeenCalledTimes(2);

    finishSecondRead(page(2n));
    await waitFor(() => {
      expect(readScrollback).toHaveBeenCalledTimes(3);
      expect(stage).toHaveAttribute("data-history-epoch", "3");
      expect(scroller.scrollTop).toBe(240);
    });
    expect(readScrollback.mock.calls).toEqual([
      [7n, 0, 4],
      [7n, 0, 4],
      [7n, 0, 4],
    ]);
  });
});
