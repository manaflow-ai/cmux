import { describe, expect, test } from "bun:test";
import { DaytonaProvider } from "../services/vms/drivers/daytona";
import { ProviderError, type WebSocketPtyEndpoint } from "../services/vms/drivers/types";

const websocketEndpoint: WebSocketPtyEndpoint = {
  transport: "websocket",
  url: "wss://7777-sandbox-1.proxy.daytona.works/terminal",
  headers: { "x-daytona-preview-token": "preview-token" },
  token: "pty-token",
  sessionId: "pty-session",
  attachmentId: "attachment-1",
  expiresAtUnix: Math.floor(Date.now() / 1000) + 300,
};

class TestDaytonaProvider extends DaytonaProvider {
  websocketResult: WebSocketPtyEndpoint | Error = websocketEndpoint;

  override async openWebSocketPty(_vmId: string): Promise<WebSocketPtyEndpoint> {
    if (this.websocketResult instanceof Error) {
      throw this.websocketResult;
    }
    return this.websocketResult;
  }
}

describe("DaytonaProvider attach", () => {
  test("requires the cmuxd RPC daemon when the caller asks for one", async () => {
    const provider = new TestDaytonaProvider();
    provider.websocketResult = websocketEndpoint;

    await expect(provider.openAttach("sandbox-1", { requireDaemon: true })).rejects.toThrow(
      "requires a cmuxd RPC endpoint",
    );
  });

  test("returns the WebSocket endpoint when daemon metadata is present", async () => {
    const provider = new TestDaytonaProvider();
    const endpointWithDaemon: WebSocketPtyEndpoint = {
      ...websocketEndpoint,
      daemon: {
        url: "wss://7777-sandbox-1.proxy.daytona.works/rpc",
        headers: { "x-daytona-preview-token": "preview-token" },
        token: "rpc-token",
        sessionId: "rpc-session",
        expiresAtUnix: Math.floor(Date.now() / 1000) + 600,
      },
    };
    provider.websocketResult = endpointWithDaemon;

    const endpoint = await provider.openAttach("sandbox-1", { requireDaemon: true });

    expect(endpoint).toEqual(endpointWithDaemon);
  });

  test("does not fall back to SSH when the WebSocket attach fails", async () => {
    const provider = new TestDaytonaProvider();
    provider.websocketResult = new Error("Daytona cmuxd websocket health check returned 502");

    await expect(provider.openAttach("sandbox-1")).rejects.toThrow(
      "Daytona cmuxd websocket health check returned 502",
    );
  });
});

describe("DaytonaProvider SSH surface", () => {
  test("openSSH is unsupported and points at the WebSocket attach path", async () => {
    const provider = new DaytonaProvider();

    await expect(provider.openSSH("sandbox-1")).rejects.toThrow(ProviderError);
    await expect(provider.openSSH("sandbox-1")).rejects.toThrow("WebSocket-only");
  });

  test("revokeSSHIdentity is a safe no-op", async () => {
    const provider = new DaytonaProvider();

    await expect(provider.revokeSSHIdentity("anything")).resolves.toBeUndefined();
    await expect(provider.revokeSSHIdentity("")).resolves.toBeUndefined();
  });
});
