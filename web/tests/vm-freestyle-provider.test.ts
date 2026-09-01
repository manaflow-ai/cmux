import { describe, expect, test } from "bun:test";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import {
  FREESTYLE_PLATFORM_METADATA_KEY,
  freestyleBetaCmuxRemoteRoute,
  freestyleBetaDaemonHealthyCommand,
  freestyleBetaFirewallRules,
  freestyleBetaStartDaemonCommand,
  isFreestyleBetaSnapshotId,
  isFreestyleBetaVmId,
  mapFreestyleBetaState,
  normalizeFreestyleBetaExecTimeout,
  renderFreestyleModelPlaneEnvFile,
} from "../services/vms/drivers/freestyleBeta";
import { ProviderError } from "../services/vms/drivers/types";
import type {
  SSHEndpoint,
  WebSocketPtyEndpoint,
} from "../services/vms/drivers/types";

// A real beta id/snapshot shape (vm-/sh- + 32 hex) vs the legacy platform's
// bare 20-char base36 ids; the driver dispatches per machine on this shape.
const BETA_VM_ID = "vm-d05087e5773e4a978036fc806b0cd759";
const BETA_SNAPSHOT_ID = "sh-9581282fc6c644b399fd49fdcdbcf130";
const LEGACY_VM_ID = "t9mstkvydmb4x0tjmnqu";

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

describe("Freestyle platform dispatch", () => {
  test("beta ids are vm-<32 hex>; legacy ids and near-misses stay legacy", () => {
    expect(isFreestyleBetaVmId(BETA_VM_ID)).toBe(true);
    expect(isFreestyleBetaVmId(LEGACY_VM_ID)).toBe(false);
    expect(isFreestyleBetaVmId("vm-1")).toBe(false); // legacy test fixtures
    expect(isFreestyleBetaVmId("vm-D05087E5773E4A978036FC806B0CD759")).toBe(false);
  });

  test("beta snapshots are sh-<32 hex>; legacy sh-/sc- + 20 base36 stay legacy", () => {
    expect(isFreestyleBetaSnapshotId(BETA_SNAPSHOT_ID)).toBe(true);
    expect(isFreestyleBetaSnapshotId("sh-6ch5p9k23xrcx24056n8")).toBe(false);
    expect(isFreestyleBetaSnapshotId("sc-mt237w1nd7c7673bd03m")).toBe(false);
  });

  test("attachTransports is the union across both platforms", () => {
    // cmux-remote-only would make the workflow gate refuse openAttach for the
    // whole legacy fleet; the per-machine refusal lives inside the methods.
    const provider = new FreestyleProvider();
    expect(provider.attachTransports).toEqual(["cmux-remote", "websocket", "ssh"]);
    expect(typeof provider.openCmuxRemote).toBe("function");
    expect(typeof provider.approveCmuxRemoteEnrollment).toBe("function");
  });

  test("openAttach on a beta machine refuses and names cmux-remote", async () => {
    const provider = new TestFreestyleProvider();
    await expect(provider.openAttach(BETA_VM_ID)).rejects.toThrow("cmux-remote");
    await expect(
      provider.openAttach("vm-1", { providerMetadata: { [FREESTYLE_PLATFORM_METADATA_KEY]: "beta" } }),
    ).rejects.toThrow("cmux-remote");
    expect(provider.sshCalls).toBe(0);
  });

  test("openCmuxRemote on a legacy machine refuses and names recreation", async () => {
    const provider = new FreestyleProvider();
    await expect(provider.openCmuxRemote(LEGACY_VM_ID)).rejects.toThrow(ProviderError);
    await expect(provider.openCmuxRemote(LEGACY_VM_ID)).rejects.toThrow("beta devbox image");
    await expect(provider.approveCmuxRemoteEnrollment(LEGACY_VM_ID, "inv-1")).rejects.toThrow(ProviderError);
  });

  test("openSSH and fork refuse on beta machines", async () => {
    const provider = new FreestyleProvider();
    await expect(provider.openSSH(BETA_VM_ID)).rejects.toThrow("cmux-remote");
    await expect(provider.fork(BETA_VM_ID)).rejects.toThrow("snapshot");
  });
});

describe("Freestyle beta platform contract", () => {
  test("firewall: outbound open, inbound only the daemon port", () => {
    expect(freestyleBetaFirewallRules()).toEqual([
      { action: "allow", source: {}, destination: { public: true } },
      { action: "allow", source: { public: true }, destination: { port: 1337, protocol: "tcp" } },
    ]);
  });

  test("cmux-remote route is the public IPv6 straight to the daemon", () => {
    expect(freestyleBetaCmuxRemoteRoute("2602:f75c:0:1::2a", BETA_VM_ID)).toBe(
      "ws://[2602:f75c:0:1::2a]:1337/v1/link",
    );
    expect(() => freestyleBetaCmuxRemoteRoute(null, BETA_VM_ID)).toThrow("public IPv6");
    expect(() => freestyleBetaCmuxRemoteRoute("  ", BETA_VM_ID)).toThrow("public IPv6");
  });

  test("daemon health requires a v6-table listener; start installs the dual-stack override", () => {
    // 0x0539 = 1337; a 0.0.0.0-bound daemon appears only in /proc/net/tcp and
    // is unreachable at the public IPv6, so it must be restarted.
    expect(freestyleBetaDaemonHealthyCommand()).toContain("/proc/net/tcp6");
    expect(freestyleBetaDaemonHealthyCommand()).toContain(":0539 ");
    const start = freestyleBetaStartDaemonCommand();
    expect(start).toContain("Environment=CMUX_TUI_REMOTE_WS_BIND=[::]:1337");
    expect(start).toContain("systemctl restart cmux-tui-daemon");
    expect(start).toContain("--remote-ws [::]:1337"); // non-systemd fallback
  });

  test("model-plane env renders the exact file agent-config.sh persists", () => {
    expect(
      renderFreestyleModelPlaneEnvFile({
        OPENAI_BASE_URL: "https://cmux.example/v1",
        OPENAI_API_KEY: "crt_secret'quote",
        CMUX_CODEROUTER_URL: "https://cmux.example",
      }),
    ).toBe(
      [
        "# generated by cmux from machine boot env; managed, do not edit",
        "export OPENAI_BASE_URL='https://cmux.example/v1'",
        `export OPENAI_API_KEY='crt_secret'\\''quote'`,
        "export CMUX_CODEROUTER_URL='https://cmux.example'",
        "",
      ].join("\n"),
    );
    expect(renderFreestyleModelPlaneEnvFile({})).toBeNull();
    expect(renderFreestyleModelPlaneEnvFile({ OPENAI_API_KEY: "crt_x" })).toBeNull();
  });

  test("exec timeouts clamp to the beta per-exec cap; killed execs read as 124", () => {
    expect(normalizeFreestyleBetaExecTimeout(undefined)).toBe(30_000);
    expect(normalizeFreestyleBetaExecTimeout(-5)).toBe(30_000);
    expect(normalizeFreestyleBetaExecTimeout(10 * 60 * 1000)).toBe(300_000);
    expect(normalizeFreestyleBetaExecTimeout(12_345)).toBe(12_345);
  });

  test("stopped beta VMs read as paused (start() recovers them), not destroyed", () => {
    expect(mapFreestyleBetaState("starting")).toBe("creating");
    expect(mapFreestyleBetaState("running")).toBe("running");
    expect(mapFreestyleBetaState("pausing")).toBe("paused");
    expect(mapFreestyleBetaState("paused")).toBe("paused");
    expect(mapFreestyleBetaState("stopped")).toBe("paused");
  });
});
