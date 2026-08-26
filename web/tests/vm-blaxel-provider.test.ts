import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { describe, expect, test } from "bun:test";
import {
  BlaxelProvider,
  DESKTOP_VNC_HEAL_COMMAND,
  hostnameSetupCommand,
  parseMachineStats,
  provisionScriptContent,
  resolveBlaxelMemoryMb,
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

  test("Blaxel is the default when no provider override is configured", () => {
    const previous = process.env.CMUX_VM_DEFAULT_PROVIDER;
    delete process.env.CMUX_VM_DEFAULT_PROVIDER;
    try {
      expect(defaultProviderId()).toBe("blaxel");
    } finally {
      if (previous === undefined) delete process.env.CMUX_VM_DEFAULT_PROVIDER;
      else process.env.CMUX_VM_DEFAULT_PROVIDER = previous;
    }
  });

  test("manifest resolves a local-dev default image", () => {
    const selection = resolveVmImage("blaxel", undefined, {});
    expect(selection.image).toBe("blaxel/xfce-vnc:latest");
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

  test("revokes daemon and preview ingress credentials", async () => {
    const previousKey = process.env.BL_API_KEY;
    const previousWorkspace = process.env.BL_WORKSPACE;
    process.env.BL_API_KEY = "test-key";
    process.env.BL_WORKSPACE = "cmux";
    const originalFetch = globalThis.fetch;
    const calls: Array<{ method: string; url: string; body?: string }> = [];
    globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
      calls.push({ method: init?.method ?? "GET", url, body: typeof init?.body === "string" ? init.body : undefined });
      if (url.endsWith("/sandboxes/machine-a")) {
        return new Response(JSON.stringify({ metadata: { url: "https://sandbox-api.test" } }), { status: 200 });
      }
      if (url === "https://sandbox-api.test/process") {
        return new Response(JSON.stringify({ exitCode: 0, status: "completed" }), { status: 200 });
      }
      if (url.endsWith("/sandboxes/machine-a/previews")) {
        return new Response(JSON.stringify([
          { metadata: { name: "cmuxd" } },
          { metadata: { name: "port-3000" } },
        ]), { status: 200 });
      }
      if (url.includes("/previews/")) return new Response("", { status: 200 });
      return new Response("unexpected", { status: 500 });
    }) as typeof fetch;
    try {
      await new BlaxelProvider().revokeEndpointLeases("machine-a");
      const processCall = calls.find((call) => call.url === "https://sandbox-api.test/process");
      expect(processCall?.method).toBe("POST");
      expect(processCall?.body).toContain("attach-pty-lease.json");
      expect(processCall?.body).toContain("pkill");
      expect(calls.filter((call) => call.method === "DELETE")).toHaveLength(2);
    } finally {
      globalThis.fetch = originalFetch;
      if (previousKey === undefined) delete process.env.BL_API_KEY;
      else process.env.BL_API_KEY = previousKey;
      if (previousWorkspace === undefined) delete process.env.BL_WORKSPACE;
      else process.env.BL_WORKSPACE = previousWorkspace;
    }
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

  test("uses the request memory and preserves the env fallback", () => {
    expect(resolveBlaxelMemoryMb(8192, { CMUX_VM_BLAXEL_MEMORY_MB: "4096" })).toBe(8192);
    expect(resolveBlaxelMemoryMb(undefined, { CMUX_VM_BLAXEL_MEMORY_MB: "16384" })).toBe(16384);
    expect(resolveBlaxelMemoryMb(undefined, {})).toBe(4096);
    expect(() => resolveBlaxelMemoryMb(0, {})).toThrow("memoryMb must be a positive integer");
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

  test("rotates an old private bl.run preview after the custom domain is verified", async () => {
    withEnv();
    const old = {
      spec: {
        url: "https://noble-wren-3000-cmux.preview.bl.run",
        public: false,
        prefixUrl: "noble-wren-3000",
      },
    };
    const replacement = {
      spec: {
        url: "https://noble-wren-3000.vm.cmux.sh",
        public: false,
        prefixUrl: "noble-wren-3000",
        customDomain: "vm.cmux.sh",
      },
    };
    const fetchMock = installFetch(({ method, url, body }) => {
      if (url.endsWith("/customdomains/vm.cmux.sh")) return { status: 200, body: { spec: { status: "verified" } } };
      if (url.endsWith("/sandboxes/noble-wren")) return { status: 200, body: { status: "DEPLOYED", metadata: { name: "noble-wren" } } };
      if (method === "GET" && url.endsWith("/previews/port-3000")) return { status: 200, body: old };
      if (method === "DELETE" && url.endsWith("/previews/port-3000")) return { status: 200, body: old };
      if (method === "POST" && url.endsWith("/previews")) return { status: 200, body: replacement };
      if (method === "POST" && url.endsWith("/tokens")) return { status: 200, body: { spec: { token: "preview-token" } } };
      throw new Error(`unexpected ${method} ${url} ${JSON.stringify(body)}`);
    });
    try {
      const opened = await new BlaxelProvider().openPort("noble-wren", 3000);
      expect(opened.url).toBe("https://noble-wren-3000.vm.cmux.sh");
      expect(fetchMock.calls.filter((call) => call.method === "DELETE")).toHaveLength(1);
      const create = fetchMock.calls.find((call) => call.method === "POST" && call.url.endsWith("/previews"));
      expect(create?.body).toMatchObject({
        spec: { prefixUrl: "noble-wren-3000", customDomain: "vm.cmux.sh", public: false },
      });
    } finally {
      fetchMock.restore();
      restoreEnv();
    }
  });
});

describe("BlaxelProvider machine stats parsing", () => {
  test("turns the sampled /proc output into CPU, memory, and disk readings", () => {
    const stdout = [
      "cpu  1000 0 500 8000 100 0 0 0 0 0",
      "cpu  1300 0 600 8100 100 0 0 0 0 0",
      "0.42 0.30 0.20 1/123 4567",
      "2",
      "MemTotal:       4194304 kB",
      "MemAvailable:   3145728 kB",
      "/dev/vdb       5242880 1310720 3932160  26% /root",
    ].join("\n");
    const stats = parseMachineStats(stdout, 4096);
    expect(stats.cpus).toBe(2);
    // 500 busy ticks out of 600 total between the two samples.
    expect(Math.round(stats.cpuPercent ?? -1)).toBe(80);
    expect(stats.loadAverage1m).toBeCloseTo(0.42);
    expect(stats.memoryTotalMb).toBe(4096);
    expect(stats.memoryUsedMb).toBe(1024);
    expect(stats.diskTotalMb).toBe(5120);
    expect(stats.diskUsedMb).toBe(1280);
  });

  test("falls back to provisioned memory and leaves unknown fields undefined", () => {
    const stats = parseMachineStats("", 2048);
    expect(stats.memoryTotalMb).toBe(2048);
    expect(stats.cpuPercent).toBeUndefined();
    expect(stats.diskTotalMb).toBeUndefined();
  });
});

describe("BlaxelProvider desktop VNC bootstrap", () => {
  // Regression: renaming the host without an /etc/hosts entry made `hostname -f` fail, which
  // aborts TigerVNC's `vncserver` wrapper — so 5901 never bound and noVNC showed "Failed to
  // connect to server" on every desktop machine. The bootstrap must make the name resolvable.
  test("hostnameSetupCommand maps the machine name to loopback in /etc/hosts", () => {
    const cmd = hostnameSetupCommand("warm-jay");
    expect(cmd).toContain("hostname 'warm-jay'");
    expect(cmd).toContain("/etc/hosts");
    expect(cmd).toContain("127.0.0.1");
    // The whole point: a fresh boot must not append a duplicate on resurrection.
    expect(cmd).toContain("grep -qF 'warm-jay' /etc/hosts ||");
  });

  test("hostnameSetupCommand single-quotes the name so it cannot inject shell", () => {
    const cmd = hostnameSetupCommand("a; rm -rf /");
    expect(cmd).toContain("'a; rm -rf /'");
    expect(cmd).not.toMatch(/;\s*rm -rf \/\s*(;|$)/);
  });

  // The VNC heal starts TigerVNC as the desktop user only when it is really down, and never
  // touches a base machine (no start-vnc.sh) or a snapshot-resumed one (5901 already up).
  test("desktop VNC heal is guarded on start-vnc.sh, port 5901, and the cua user", () => {
    expect(DESKTOP_VNC_HEAL_COMMAND).toContain("[ -x /usr/local/bin/start-vnc.sh ] || exit 0");
    expect(DESKTOP_VNC_HEAL_COMMAND).toContain(":5901 ");
    expect(DESKTOP_VNC_HEAL_COMMAND).toContain("runuser -u cua");
    expect(DESKTOP_VNC_HEAL_COMMAND).toContain("start-vnc.sh");
  });
});

describe("BlaxelProvider devbox provisioning", () => {
  // The provision recipe is data (one shell script), not driver string concatenation. These
  // tests pin the contract: the script exists, parses, and carries the chatmux-devbox parity
  // pieces (four coding agents, seeded history, half-life prompt) without Docker Engine,
  // which cannot run in Blaxel microVMs (no cgroup mounts; dockerd panics, verified
  // 2026-08-26).
  test("provision script loads from services/vms/images and is a bash script", async () => {
    const script = await provisionScriptContent();
    expect(script.startsWith("#!/bin/bash")).toBe(true);
  });

  test("provision script passes bash -n", async () => {
    const script = await provisionScriptContent();
    const result = spawnSync("bash", ["-n"], { input: script, encoding: "utf8" });
    expect(result.status).toBe(0);
  });

  test("provision script installs the four coding agents and the devbox shell", async () => {
    const script = await provisionScriptContent();
    for (const pkg of [
      "@anthropic-ai/claude-code",
      "@openai/codex",
      "opencode-ai",
      "@earendil-works/pi-coding-agent",
    ]) {
      expect(script).toContain(pkg);
    }
    // Seeded ghost-text history and the half-life prompt.
    expect(script).toContain("claude --dangerously-skip-permissions");
    expect(script).toContain("codex --yolo");
    expect(script).toContain("38;5;135m"); // half-life purple user
    expect(script).toContain("ble.sh");
    // Idempotence + persistent-home safety: stamp guard, write-when-absent history.
    expect(script).toContain("/var/lib/cmux/.provisioned");
    expect(script).toContain('[ -f "$HOME/.bash_history" ] ||');
    // Docker Engine must stay out until Blaxel sandboxes can run dockerd.
    expect(script).not.toMatch(/apt-get install[^\n]*docker/);
    expect(script).not.toMatch(/apk add[^\n]*docker/);
  });

  test("provision script handles both stock image families", async () => {
    const script = await provisionScriptContent();
    expect(script).toContain("apt-get");
    expect(script).toContain("apk add");
    // Ubuntu xfce-vnc has no node; the agents need one.
    expect(script).toContain("deb.nodesource.com");
  });
});
