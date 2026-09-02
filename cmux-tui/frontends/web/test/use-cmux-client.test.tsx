import { act, renderHook, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

const rawMocks = vi.hoisted(() => ({
  transportOptions: [] as Array<Record<string, unknown>>,
}));

const macMocks = vi.hoisted(() => ({
  instances: 0,
  failAfterFirst: false,
  closeHandler: null as (() => void) | null,
}));

vi.mock("cmux/raw", () => ({
  CmuxTimeoutError: class extends Error {},
  RENDER_ATTACH_MAX_ENCODED_CHARS: 32 * 1024 * 1024,
  WebSocketTransport: class {
    constructor(_url: string, options: Record<string, unknown>) {
      rawMocks.transportOptions.push(options);
    }

    onClose() {}
  },
  CmuxClient: class {
    identify() {
      return new Promise(() => {});
    }

    close() {}
  },
}));

vi.mock("../src/lib/macRuntimeClient", () => ({
  MacRuntimeClient: class {
    private readonly shouldFail: boolean;

    constructor(url: string) {
      if (url === "https://not-a-websocket.example") {
        throw new Error("WebSocket constructor failed");
      }
      macMocks.instances += 1;
      this.shouldFail = macMocks.failAfterFirst && macMocks.instances > 1;
    }

    onClose(handler: () => void): () => void {
      macMocks.closeHandler = handler;
      return () => {
        if (macMocks.closeHandler === handler) macMocks.closeHandler = null;
      };
    }

    identify(): Promise<Record<string, unknown>> {
      return this.shouldFail
        ? Promise.reject(new Error("bridge unavailable"))
        : Promise.resolve({ protocol: 6 });
    }

    subscribe(): Promise<{ next(): Promise<never>; close(): void }> {
      return Promise.resolve({
        next: () => new Promise<never>(() => {}),
        close: () => undefined,
      });
    }

    listWorkspaces(): Promise<{ workspaces: never[] }> {
      return Promise.resolve({ workspaces: [] });
    }

    listClients(): Promise<never[]> {
      return Promise.resolve([]);
    }

    close(): void {}
  },
}));

import { useCmuxClient } from "../src/hooks/useCmuxClient";

describe("useCmuxClient", () => {
  beforeEach(() => {
    rawMocks.transportOptions.length = 0;
    macMocks.instances = 0;
    macMocks.failAfterFirst = false;
    macMocks.closeHandler = null;
  });

  it("admits the complete render attach envelope on its WebSocket", async () => {
    const { result, unmount } = renderHook(() => useCmuxClient());

    act(() => result.current.connect({ url: "ws://localhost/cmux" }));

    await waitFor(() => expect(rawMocks.transportOptions).toHaveLength(1));
    expect(rawMocks.transportOptions[0]?.maxInboundMessageBytes).toBe(32 * 1024 * 1024);
    unmount();
  });

  it("surfaces a synchronous Mac WebSocket constructor failure", async () => {
    const { result, unmount } = renderHook(() => useCmuxClient());

    act(() => result.current.connect({
      url: "https://not-a-websocket.example",
      runtime: "mac",
      token: "cmux_web_test",
    }));

    await waitFor(() => expect(result.current.status).toBe("error"));
    expect(result.current.error).toBeTruthy();
    unmount();
  });

  it("gives up after the Mac bridge reconnect budget is exhausted", async () => {
    const { result, unmount } = renderHook(() => useCmuxClient());

    act(() => result.current.connect({
      url: "ws://127.0.0.1:7683/cmux",
      runtime: "mac",
      token: "cmux_web_test",
    }));
    await waitFor(() => expect(result.current.status).toBe("connected"));

    macMocks.failAfterFirst = true;
    vi.useFakeTimers();
    try {
      const close = macMocks.closeHandler;
      expect(close).not.toBeNull();
      act(() => close?.());

      for (const delay of [500, 1_000, 2_000, 4_000, 8_000]) {
        await act(async () => {
          await vi.advanceTimersByTimeAsync(delay);
        });
      }

      expect(result.current.status).toBe("error");
      expect(result.current.error).toBe(
        "The Mac app could not reauthenticate. Paste a current grant token to reconnect.",
      );
      const instancesAfterGiveUp = macMocks.instances;
      await act(async () => {
        await vi.advanceTimersByTimeAsync(30_000);
      });
      expect(macMocks.instances).toBe(instancesAfterGiveUp);
    } finally {
      vi.useRealTimers();
      unmount();
    }
  });
});
