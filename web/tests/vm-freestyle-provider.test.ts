import { describe, expect, test } from "bun:test";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import type {
  SSHEndpoint,
  WebSocketPtyEndpoint,
} from "../services/vms/drivers/types";

const sshEndpoint: SSHEndpoint = {
  transport: "ssh",
  host: "vm-ssh.freestyle.sh",
  port: 22,
  username: "vm-1+cmux",
  publicKeyFingerprint: null,
  credential: { kind: "password", value: "token" },
  identityHandle: "identity-1",
};

const websocketEndpoint: WebSocketPtyEndpoint = {
  transport: "websocket",
  url: "wss://vm-1.vm.freestyle.sh/terminal",
  headers: {},
  token: "pty-token",
  sessionId: "pty-session",
  expiresAtUnix: Math.floor(Date.now() / 1000) + 300,
};

class TestFreestyleProvider extends FreestyleProvider {
  websocketResult: WebSocketPtyEndpoint | Error = websocketEndpoint;
  sshCalls = 0;

  override async openWebSocketPty(_vmId: string): Promise<WebSocketPtyEndpoint> {
    if (this.websocketResult instanceof Error) {
      throw this.websocketResult;
    }
    return this.websocketResult;
  }

  override async openSSH(_vmId: string): Promise<SSHEndpoint> {
    this.sshCalls += 1;
    return sshEndpoint;
  }
}

describe("FreestyleProvider attach fallback", () => {
  test("falls back to SSH when a required daemon attach is unavailable", async () => {
    const provider = new TestFreestyleProvider();
    provider.websocketResult = new Error("Freestyle cmuxd websocket health check returned 502");

    const endpoint = await provider.openAttach("vm-1", { requireDaemon: true });

    expect(endpoint).toEqual(sshEndpoint);
    expect(provider.sshCalls).toBe(1);
  });

  test("falls back to SSH when the WebSocket health check times out", async () => {
    const provider = new TestFreestyleProvider();
    provider.websocketResult = new Error(
      "Freestyle cmuxd websocket health check failed: The operation was aborted",
    );

    const endpoint = await provider.openAttach("vm-1", { requireDaemon: true });

    expect(endpoint).toEqual(sshEndpoint);
    expect(provider.sshCalls).toBe(1);
  });

  test("does not mint SSH credentials for unexpected attach errors", async () => {
    const provider = new TestFreestyleProvider();
    provider.websocketResult = new Error("Freestyle API returned 401");

    await expect(provider.openAttach("vm-1", { requireDaemon: true })).rejects.toThrow(
      "Freestyle API returned 401",
    );
    expect(provider.sshCalls).toBe(0);
  });

  test("falls back to SSH when required daemon metadata is missing", async () => {
    const provider = new TestFreestyleProvider();
    provider.websocketResult = websocketEndpoint;

    const endpoint = await provider.openAttach("vm-1", { requireDaemon: true });

    expect(endpoint).toEqual(sshEndpoint);
    expect(provider.sshCalls).toBe(1);
  });

  test("keeps WebSocket attach when daemon metadata is present", async () => {
    const provider = new TestFreestyleProvider();
    const endpointWithDaemon: WebSocketPtyEndpoint = {
      ...websocketEndpoint,
      daemon: {
        url: "wss://vm-1.vm.freestyle.sh/rpc",
        headers: {},
        token: "rpc-token",
        sessionId: "rpc-session",
        expiresAtUnix: Math.floor(Date.now() / 1000) + 600,
      },
    };
    provider.websocketResult = endpointWithDaemon;

    const endpoint = await provider.openAttach("vm-1", { requireDaemon: true });

    expect(endpoint).toEqual(endpointWithDaemon);
    expect(provider.sshCalls).toBe(0);
  });
});
