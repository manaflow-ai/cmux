// @vitest-environment jsdom
import { act, cleanup, renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

const transport = vi.hoisted(() => ({ closed: () => {}, unavailable: false, rejectAuth: false, identifies: 0 }));
vi.mock("cmux/raw", () => ({
  CmuxTimeoutError: class extends Error {},
  RENDER_ATTACH_MAX_ENCODED_CHARS: 1_000_000,
  WebSocketTransport: class {
    constructor(
      _url: string,
      readonly options: { onAuthenticationRejected?: () => void },
    ) {}
    onClose(callback: () => void) {
      transport.closed = callback;
    }
  },
  CmuxClient: class {
    protocol = 12;
    constructor(readonly init: { transport: { options: { onAuthenticationRejected?: () => void } } }) {}
    async identify() {
      transport.identifies += 1;
      if (transport.rejectAuth) {
        // The real transport runs onAuthenticationRejected synchronously as it
        // fails the pending request with CmuxAuthenticationRejectedError.
        this.init.transport.options.onAuthenticationRejected?.();
        throw new Error("authentication rejected");
      }
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
  transport.rejectAuth = false;
  transport.identifies = 0;
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

  it("stops automatic reconnect when the server rejects a configured token", async () => {
    vi.useFakeTimers();
    const { result } = renderHook(() => useCmuxClient());
    await act(async () => result.current.connect({ url: "ws://test", token: "revoked" }));
    expect(result.current.status).toBe("connected");
    transport.rejectAuth = true;
    act(() => transport.closed());
    await act(async () => vi.advanceTimersByTimeAsync(60_000));
    expect(result.current.status).toBe("reconnect-failed");
    const attempts = transport.identifies;
    await act(async () => vi.advanceTimersByTimeAsync(600_000));
    expect(transport.identifies).toBe(attempts);
  });

  it("keeps retrying after a rejected pairing credential so the next attempt can pair again", async () => {
    vi.useFakeTimers();
    const { result } = renderHook(() => useCmuxClient());
    await act(async () => result.current.connect({ url: "ws://test" }));
    transport.rejectAuth = true;
    act(() => transport.closed());
    await act(async () => vi.advanceTimersByTimeAsync(60_000));
    expect(result.current.status).toBe("reconnecting");
  });
});
