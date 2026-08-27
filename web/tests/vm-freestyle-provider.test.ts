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
  attachmentId: "attachment-1",
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
  test("does not fall back to SSH when a required daemon attach is unavailable", async () => {
    const provider = new TestFreestyleProvider();
    provider.websocketResult = new Error("Freestyle cmuxd websocket health check returned 502");

    await expect(provider.openAttach("vm-1", { requireDaemon: true })).rejects.toThrow(
      "Freestyle cmuxd websocket health check returned 502",
    );

    expect(provider.sshCalls).toBe(0);
  });

  test("does not fall back to SSH when required daemon health check times out", async () => {
    const provider = new TestFreestyleProvider();
    provider.websocketResult = new Error(
      "Freestyle cmuxd websocket health check failed: The operation was aborted",
    );

    await expect(provider.openAttach("vm-1", { requireDaemon: true })).rejects.toThrow(
      "Freestyle cmuxd websocket health check failed",
    );

    expect(provider.sshCalls).toBe(0);
  });

  test("keeps SSH fallback for non-daemon attach when WebSocket is unavailable", async () => {
    const provider = new TestFreestyleProvider();
    provider.websocketResult = new Error("Freestyle cmuxd websocket health check returned 502");

    const endpoint = await provider.openAttach("vm-1");

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

  test("does not fall back to SSH when required daemon metadata is missing", async () => {
    const provider = new TestFreestyleProvider();
    provider.websocketResult = websocketEndpoint;

    await expect(provider.openAttach("vm-1", { requireDaemon: true })).rejects.toThrow(
      "requires a cmuxd RPC endpoint",
    );

    expect(provider.sshCalls).toBe(0);
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

  test("keeps daemon attach when Freestyle exec probe fails but websocket admin is healthy", async () => {
    const originalFetch = globalThis.fetch;
    const originalApiKey = process.env.FREESTYLE_API_KEY;
    process.env.FREESTYLE_API_KEY = "test-freestyle-api-key";
    const urls: string[] = [];
    globalThis.fetch = (async (input, init) => {
      const url = input instanceof Request ? input.url : String(input);
      urls.push(url);
      if (url === "https://vm-1.vm.freestyle.sh/healthz") {
        return new Response("ok", { status: 200 });
      }
      if (url === "https://vm-1.vm.freestyle.sh/admin/leases") {
        expect(init?.method).toBe("POST");
        return new Response("ok", { status: 200 });
      }
      return new Response(JSON.stringify({ error: "INTERNAL_ERROR", message: "Internal server error" }), {
        status: 500,
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch;

    try {
      const provider = new FreestyleProvider();
      const endpoint = await provider.openAttach("vm-1", {
        requireDaemon: true,
        providerMetadata: { freestyleDaemonAdminToken: "admin-token" },
      });

      expect(endpoint.transport).toBe("websocket");
      if (endpoint.transport !== "websocket") {
        throw new Error("expected websocket attach endpoint");
      }
      expect(endpoint.url).toBe("wss://vm-1.vm.freestyle.sh/terminal");
      expect(endpoint.daemon?.url).toBe("wss://vm-1.vm.freestyle.sh/rpc");
      expect(urls).toContain("https://vm-1.vm.freestyle.sh/healthz");
      expect(urls).toContain("https://vm-1.vm.freestyle.sh/admin/leases");
    } finally {
      globalThis.fetch = originalFetch;
      if (originalApiKey === undefined) {
        delete process.env.FREESTYLE_API_KEY;
      } else {
        process.env.FREESTYLE_API_KEY = originalApiKey;
      }
    }
  });
});
