// @vitest-environment jsdom
import { act, cleanup, renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

const transport = vi.hoisted(() => ({ closed: () => {}, unavailable: false }));
vi.mock("cmux/raw", () => ({
  CmuxTimeoutError: class extends Error {},
  RENDER_ATTACH_MAX_ENCODED_CHARS: 1_000_000,
  WebSocketTransport: class {
    onClose(callback: () => void) {
      transport.closed = callback;
    }
  },
  CmuxClient: class {
    protocol = 12;
    async identify() {
      if (transport.unavailable) throw new Error("unavailable");
      return { app: "cmux-tui", protocol: 12, session: "test" };
    }
    async setClientInfo() {}
    async subscribe() {
      return { next: () => new Promise(() => {}) };
    }
    async listWorkspaces() {
      return { workspaces: [] };
    }
    async listClients() {
      return [];
    }
    async close() {}
  },
}));

import { useCmuxClient } from "./useCmuxClient";

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  transport.unavailable = false;
});

describe("cached session during reconnect", () => {
  it("discards cached session identity when the person switches servers", async () => {
    const { result } = renderHook(() => useCmuxClient());
    await act(async () => result.current.connect({ url: "ws://first" }));
    expect(result.current.client).not.toBeNull();
    transport.unavailable = true;
    await act(async () => result.current.connect({ url: "ws://other" }));
    expect(result.current.client).toBeNull();
    expect(result.current.tree).toBeNull();
    expect(result.current.info).toBeNull();
  });

  it("retains the renderer client and tree while automatic and manual retries fail", async () => {
    vi.useFakeTimers();
    const { result } = renderHook(() => useCmuxClient());
    await act(async () => result.current.connect({ url: "ws://test" }));
    expect(result.current.status).toBe("connected");
    const client = result.current.client;
    const tree = result.current.tree;
    const info = result.current.info;
    transport.unavailable = true;
    act(() => transport.closed());
    expect(result.current.status).toBe("reconnecting");
    expect(result.current.client).toBe(client);
    expect(result.current.tree).toBe(tree);
    expect(result.current.info).toBe(info);
    expect(await result.current.mutations.closeWorkspace(1n)).toBe(false);
    await act(async () => result.current.retryConnection());
    expect(result.current.status).toBe("reconnecting");
    expect(result.current.client).toBe(client);
    expect(result.current.tree).toBe(tree);
    await act(async () => vi.advanceTimersByTimeAsync(500));
    expect(result.current.client).toBe(client);
    expect(result.current.tree).toBe(tree);
  });
});
