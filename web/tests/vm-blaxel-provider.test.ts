import { describe, expect, test } from "bun:test";
import { BlaxelProvider } from "../services/vms/drivers/blaxel";
import { ProviderError, type WebSocketPtyEndpoint } from "../services/vms/drivers/types";
import { providerEnabledEnvKey } from "../services/vms/config";
import { providerImageEnvKey, resolveVmImage } from "../services/vms/images/resolver";
import { defaultProviderId, getProvider } from "../services/vms/drivers";

const websocketEndpoint: WebSocketPtyEndpoint = {
  transport: "websocket",
  url: "wss://abc123.us-pdx-1.preview.bl.run/terminal",
  headers: { "X-Blaxel-Preview-Token": "preview-token" },
  token: "pty-token",
  sessionId: "pty-session",
  attachmentId: "attachment-1",
  expiresAtUnix: Math.floor(Date.now() / 1000) + 300,
};

class TestBlaxelProvider extends BlaxelProvider {
  websocketResult: WebSocketPtyEndpoint | Error = websocketEndpoint;

  override async openWebSocketPty(_vmId: string): Promise<WebSocketPtyEndpoint> {
    if (this.websocketResult instanceof Error) {
      throw this.websocketResult;
    }
    return this.websocketResult;
  }
}

describe("BlaxelProvider registry wiring", () => {
  test("is registered and resolvable", () => {
    const provider = getProvider("blaxel");
    expect(provider.id).toBe("blaxel");
  });

  test("has kill-switch and image env keys", () => {
    expect(providerEnabledEnvKey("blaxel")).toBe("CMUX_VM_BLAXEL_ENABLED");
    expect(providerImageEnvKey("blaxel")).toBe("BLAXEL_SANDBOX_IMAGE");
  });

  test("CMUX_VM_DEFAULT_PROVIDER=blaxel is honored", () => {
    const prev = process.env.CMUX_VM_DEFAULT_PROVIDER;
    process.env.CMUX_VM_DEFAULT_PROVIDER = "blaxel";
    try {
      expect(defaultProviderId()).toBe("blaxel");
    } finally {
      if (prev === undefined) delete process.env.CMUX_VM_DEFAULT_PROVIDER;
      else process.env.CMUX_VM_DEFAULT_PROVIDER = prev;
    }
  });

  test("manifest resolves a local-dev default image", () => {
    const selection = resolveVmImage("blaxel", undefined, {});
    expect(selection.image).toBe("blaxel/base-image:latest");
    expect(selection.manifestEntry?.provider).toBe("blaxel");
  });
});

describe("BlaxelProvider attach", () => {
  test("returns the WebSocket endpoint when daemon metadata is present", async () => {
    const provider = new TestBlaxelProvider();
    const endpointWithDaemon: WebSocketPtyEndpoint = {
      ...websocketEndpoint,
      daemon: {
        url: "wss://abc123.us-pdx-1.preview.bl.run/rpc",
        headers: { "X-Blaxel-Preview-Token": "preview-token" },
        token: "rpc-token",
        sessionId: "rpc-session",
        expiresAtUnix: Math.floor(Date.now() / 1000) + 600,
      },
    };
    provider.websocketResult = endpointWithDaemon;

    const endpoint = await provider.openAttach("cmux-vm-test", { requireDaemon: true });

    expect(endpoint).toEqual(endpointWithDaemon);
  });

  test("requires the cmuxd RPC daemon when the caller asks for one", async () => {
    const provider = new TestBlaxelProvider();
    provider.websocketResult = websocketEndpoint;

    await expect(provider.openAttach("cmux-vm-test", { requireDaemon: true })).rejects.toThrow(
      "requires a cmuxd RPC endpoint",
    );
  });

  test("does not fall back to SSH when the WebSocket attach fails", async () => {
    const provider = new TestBlaxelProvider();
    provider.websocketResult = new Error("blaxel cmuxd websocket health check failed");

    await expect(provider.openAttach("cmux-vm-test")).rejects.toThrow(
      "websocket health check failed",
    );
  });
});

describe("BlaxelProvider SSH surface", () => {
  test("openSSH is unsupported and points at the WebSocket attach path", async () => {
    const provider = new BlaxelProvider();

    await expect(provider.openSSH("cmux-vm-test")).rejects.toThrow(ProviderError);
    await expect(provider.openSSH("cmux-vm-test")).rejects.toThrow("WebSocket-only");
  });

  test("revokeSSHIdentity is a safe no-op", async () => {
    const provider = new BlaxelProvider();

    await expect(provider.revokeSSHIdentity("anything")).resolves.toBeUndefined();
    await expect(provider.revokeSSHIdentity("")).resolves.toBeUndefined();
  });
});

describe("BlaxelProvider configuration errors", () => {
  test("create fails with a clear error when BL_API_KEY is missing", async () => {
    const prevKey = process.env.BL_API_KEY;
    const prevWs = process.env.BL_WORKSPACE;
    delete process.env.BL_API_KEY;
    process.env.BL_WORKSPACE = "cmux";
    try {
      const provider = new BlaxelProvider();
      await expect(provider.create({ image: "blaxel/base-image:latest" })).rejects.toThrow(
        "BL_API_KEY is not configured",
      );
    } finally {
      if (prevKey === undefined) delete process.env.BL_API_KEY;
      else process.env.BL_API_KEY = prevKey;
      if (prevWs === undefined) delete process.env.BL_WORKSPACE;
      else process.env.BL_WORKSPACE = prevWs;
    }
  });

  test("create requires a resolved image", async () => {
    const provider = new BlaxelProvider();
    await expect(provider.create({ image: "  " })).rejects.toThrow("create requires a resolved image");
  });
});
