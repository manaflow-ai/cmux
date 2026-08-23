import { createHash } from "node:crypto";
import { describe, expect, test } from "bun:test";
import {
  BlaxelProvider,
  resolveDaemonSource,
  usablePrivatePreviewUrl,
  verifyDaemonDigest,
} from "../services/vms/drivers/blaxel";
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

function withDaemonEnv(
  values: { path?: string; url?: string; sha256?: string },
  run: () => void,
): void {
  const keys = [
    "CMUX_VM_BLAXEL_DAEMON_PATH",
    "CMUX_VM_BLAXEL_DAEMON_URL",
    "CMUX_VM_BLAXEL_DAEMON_SHA256",
  ] as const;
  const previous = keys.map((key) => [key, process.env[key]] as const);
  delete process.env.CMUX_VM_BLAXEL_DAEMON_PATH;
  delete process.env.CMUX_VM_BLAXEL_DAEMON_URL;
  delete process.env.CMUX_VM_BLAXEL_DAEMON_SHA256;
  if (values.path !== undefined) process.env.CMUX_VM_BLAXEL_DAEMON_PATH = values.path;
  if (values.url !== undefined) process.env.CMUX_VM_BLAXEL_DAEMON_URL = values.url;
  if (values.sha256 !== undefined) process.env.CMUX_VM_BLAXEL_DAEMON_SHA256 = values.sha256;
  try {
    run();
  } finally {
    for (const [key, value] of previous) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

describe("BlaxelProvider daemon binary integrity", () => {
  const sha = createHash("sha256").update("cmuxd-remote-bytes").digest("hex");

  test("a URL source without a sha256 pin fails closed before any download", () => {
    withDaemonEnv({ url: "https://r2.example.com/cmuxd-remote" }, () => {
      expect(() => resolveDaemonSource()).toThrow("requires CMUX_VM_BLAXEL_DAEMON_SHA256");
    });
  });

  test("a URL source with a pin resolves and lowercases the digest", () => {
    withDaemonEnv({ url: "https://r2.example.com/cmuxd-remote", sha256: sha.toUpperCase() }, () => {
      expect(resolveDaemonSource()).toEqual({
        kind: "url",
        url: "https://r2.example.com/cmuxd-remote",
        sha256: sha,
      });
    });
  });

  test("a local path may run unpinned but honors a pin when set", () => {
    withDaemonEnv({ path: "/tmp/cmuxd-remote" }, () => {
      expect(resolveDaemonSource()).toEqual({ kind: "path", path: "/tmp/cmuxd-remote", sha256: undefined });
    });
    withDaemonEnv({ path: "/tmp/cmuxd-remote", sha256: sha }, () => {
      expect(resolveDaemonSource()).toEqual({ kind: "path", path: "/tmp/cmuxd-remote", sha256: sha });
    });
  });

  test("a malformed pin is rejected", () => {
    withDaemonEnv({ url: "https://r2.example.com/cmuxd-remote", sha256: "not-a-digest" }, () => {
      expect(() => resolveDaemonSource()).toThrow("64 hex characters");
    });
  });

  test("no source configured is a clear error", () => {
    withDaemonEnv({}, () => {
      expect(() => resolveDaemonSource()).toThrow("set CMUX_VM_BLAXEL_DAEMON_PATH");
    });
  });

  test("verifyDaemonDigest accepts the pinned binary and rejects any other bytes", () => {
    const binary = Buffer.from("cmuxd-remote-bytes");
    expect(() => verifyDaemonDigest(binary, sha)).not.toThrow();
    expect(() => verifyDaemonDigest(Buffer.from("tampered-bytes"), sha)).toThrow(ProviderError);
    expect(() => verifyDaemonDigest(Buffer.from("tampered-bytes"), sha)).toThrow("sha256 mismatch");
  });
});

describe("BlaxelProvider preview privacy", () => {
  test("only a private preview URL is usable", () => {
    const url = "https://abc123.us-pdx-1.preview.bl.run";
    expect(usablePrivatePreviewUrl({ spec: { url } })).toBe(url);
    expect(usablePrivatePreviewUrl({ spec: { url, public: false } })).toBe(url);
  });

  test("a public preview is treated as absent so callers replace or reject it", () => {
    const url = "https://abc123.us-pdx-1.preview.bl.run";
    expect(usablePrivatePreviewUrl({ spec: { url, public: true } })).toBeNull();
  });

  test("a missing preview or URL is not usable", () => {
    expect(usablePrivatePreviewUrl(null)).toBeNull();
    expect(usablePrivatePreviewUrl(undefined)).toBeNull();
    expect(usablePrivatePreviewUrl({})).toBeNull();
    expect(usablePrivatePreviewUrl({ spec: {} })).toBeNull();
  });
});

describe("BlaxelProvider preview branding under races", () => {
  type FetchCall = { method: string; url: string; body: unknown };

  function installFetch(handler: (call: FetchCall) => { status: number; body?: unknown }) {
    const calls: FetchCall[] = [];
    const original = globalThis.fetch;
    globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
      const call: FetchCall = {
        method: init?.method ?? "GET",
        url,
        body: typeof init?.body === "string" ? JSON.parse(init.body) : undefined,
      };
      calls.push(call);
      const result = handler(call);
      return new Response(result.body === undefined ? "" : JSON.stringify(result.body), {
        status: result.status,
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch;
    return { calls, restore: () => { globalThis.fetch = original; } };
  }

  const savedEnv = { key: process.env.BL_API_KEY, workspace: process.env.BL_WORKSPACE, domain: process.env.CMUX_VM_BLAXEL_CUSTOM_DOMAIN };
  function withEnv() {
    process.env.BL_API_KEY = "test-key";
    process.env.BL_WORKSPACE = "cmux";
    process.env.CMUX_VM_BLAXEL_CUSTOM_DOMAIN = "vm.cmux.sh";
  }
  function restoreEnv() {
    process.env.BL_API_KEY = savedEnv.key;
    process.env.BL_WORKSPACE = savedEnv.workspace;
    process.env.CMUX_VM_BLAXEL_CUSTOM_DOMAIN = savedEnv.domain;
  }

  test("adopts a preview minted concurrently instead of clobbering it with a hash URL", async () => {
    withEnv();
    let raced = false;
    const branded = { spec: { url: "https://noble-wren-3000.vm.cmux.sh", public: false, prefixUrl: "noble-wren-3000" } };
    const fetchMock = installFetch(({ method, url }) => {
      if (url.endsWith("/sandboxes/noble-wren")) return { status: 200, body: { status: "DEPLOYED", metadata: { name: "noble-wren" } } };
      if (url.endsWith("/customdomains/vm.cmux.sh")) return { status: 200, body: { spec: { status: "verified" } } };
      if (method === "GET" && url.endsWith("/previews/port-3000")) {
        return raced ? { status: 200, body: branded } : { status: 404, body: { error: "not found" } };
      }
      if (method === "POST" && url.endsWith("/previews")) {
        // Another caller won the race between our GET and POST.
        raced = true;
        return { status: 409, body: { error: "preview already exists" } };
      }
      if (method === "POST" && url.endsWith("/tokens")) return { status: 200, body: { spec: { token: "preview-token" } } };
      return { status: 500, body: { error: `unexpected ${method} ${url}` } };
    });
    try {
      const provider = new BlaxelProvider();
      const opened = await provider.openPort("noble-wren", 3000);
      expect(opened.url).toBe("https://noble-wren-3000.vm.cmux.sh");
      const creates = fetchMock.calls.filter((c) => c.method === "POST" && c.url.endsWith("/previews"));
      expect(creates).toHaveLength(1);
      expect((creates[0]!.body as { spec: { prefixUrl?: string } }).spec.prefixUrl).toBe("noble-wren-3000");
    } finally {
      fetchMock.restore();
      restoreEnv();
    }
  });

  test("coalesces concurrent ensures for the same preview into one create", async () => {
    withEnv();
    let created: unknown = null;
    const fetchMock = installFetch(({ method, url, body }) => {
      if (url.endsWith("/sandboxes/noble-wren")) return { status: 200, body: { status: "DEPLOYED", metadata: { name: "noble-wren" } } };
      if (url.endsWith("/customdomains/vm.cmux.sh")) return { status: 200, body: { spec: { status: "verified" } } };
      if (method === "GET" && url.endsWith("/previews/port-3000")) {
        return created ? { status: 200, body: created } : { status: 404, body: { error: "not found" } };
      }
      if (method === "POST" && url.endsWith("/previews")) {
        const spec = (body as { spec: { prefixUrl?: string } }).spec;
        created = { spec: { url: `https://${spec.prefixUrl}.vm.cmux.sh`, public: false, prefixUrl: spec.prefixUrl } };
        return { status: 200, body: created };
      }
      if (method === "POST" && url.endsWith("/tokens")) return { status: 200, body: { spec: { token: "preview-token" } } };
      return { status: 500, body: { error: `unexpected ${method} ${url}` } };
    });
    try {
      const provider = new BlaxelProvider();
      const [a, b] = await Promise.all([provider.openPort("noble-wren", 3000), provider.openPort("noble-wren", 3000)]);
      expect(a.url).toBe("https://noble-wren-3000.vm.cmux.sh");
      expect(b.url).toBe(a.url);
      const creates = fetchMock.calls.filter((c) => c.method === "POST" && c.url.endsWith("/previews"));
      expect(creates).toHaveLength(1);
    } finally {
      fetchMock.restore();
      restoreEnv();
    }
  });
});
