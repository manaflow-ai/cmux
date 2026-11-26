import { act, renderHook, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

const rawMocks = vi.hoisted(() => ({
  transportOptions: [] as Array<Record<string, unknown>>,
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

import { useCmuxClient } from "../src/hooks/useCmuxClient";

describe("useCmuxClient", () => {
  beforeEach(() => {
    rawMocks.transportOptions.length = 0;
  });

  it("admits the complete render attach envelope on its WebSocket", async () => {
    const { result, unmount } = renderHook(() => useCmuxClient());

    act(() => result.current.connect({ url: "ws://localhost/cmux" }));

    await waitFor(() => expect(rawMocks.transportOptions).toHaveLength(1));
    expect(rawMocks.transportOptions[0]?.maxInboundMessageBytes).toBe(32 * 1024 * 1024);
    unmount();
  });
});
