import { afterEach, describe, expect, test } from "bun:test";
import {
  atomicJsonInstallCommands,
  checkCmuxdHealthz,
  discoverCmuxdService,
  installCmuxdAttachLeases,
  installReusableCmuxdRpcLease,
  isCmuxdHealthy,
  readReusableCmuxdRpcLease,
  waitForCmuxdHealthy,
  type ProviderTransport,
} from "../services/vms/drivers/cmuxdAttach";
import {
  CMUXD_WS_LEGACY_PTY_LEASE_PATH,
  CMUXD_WS_PTY_LEASE_PATH,
  CMUXD_WS_RPC_CLIENT_PATH,
} from "../services/vms/drivers/cmuxdConstants";
import type { ExecResult } from "../services/vms/drivers/types";

type ExecHandler = (command: string) => ExecResult | Promise<ExecResult>;

function fakeTransport(handler: ExecHandler): ProviderTransport & { commands: string[] } {
  const commands: string[] = [];
  return {
    providerId: "blaxel",
    commands,
    exec: async (command: string) => {
      commands.push(command);
      return handler(command);
    },
  };
}

const ok = (stdout = ""): ExecResult => ({ exitCode: 0, stdout, stderr: "" });

function validClientLease(expiresInSeconds = 3600): string {
  return JSON.stringify({
    token: "rpc-token",
    sessionId: "rpc-session",
    expiresAtUnix: Math.floor(Date.now() / 1000) + expiresInSeconds,
  });
}

describe("discoverCmuxdService", () => {
  test("reads both lease paths from the daemon's flags", async () => {
    const transport = fakeTransport(() =>
      ok(
        "root 42 cmuxd-remote serve --ws --listen 0.0.0.0:7777 " +
          "--auth-lease-file /custom/pty.json --rpc-auth-lease-file /custom/rpc.json --shell /bin/bash",
      ),
    );
    expect(await discoverCmuxdService(transport)).toEqual({
      ptyLeasePath: "/custom/pty.json",
      rpcLeasePath: "/custom/rpc.json",
    });
  });

  test("falls back to the legacy PTY path when an old daemon still uses it", async () => {
    const transport = fakeTransport(() =>
      ok(`cmuxd-remote serve --ws ${CMUXD_WS_LEGACY_PTY_LEASE_PATH}`),
    );
    expect(await discoverCmuxdService(transport)).toEqual({
      ptyLeasePath: CMUXD_WS_LEGACY_PTY_LEASE_PATH,
      rpcLeasePath: null,
    });
  });

  test("defaults to the current PTY path on an empty process table", async () => {
    const transport = fakeTransport(() => ok(""));
    expect(await discoverCmuxdService(transport)).toEqual({
      ptyLeasePath: CMUXD_WS_PTY_LEASE_PATH,
      rpcLeasePath: null,
    });
  });
});

describe("readReusableCmuxdRpcLease", () => {
  test("returns a still-valid lease", async () => {
    const transport = fakeTransport(() => ok(validClientLease()));
    const lease = await readReusableCmuxdRpcLease(transport, "/tmp/cmux/rpc.json");
    expect(lease?.token).toBe("rpc-token");
    expect(lease?.sessionId).toBe("rpc-session");
  });

  test("rejects a lease inside the renew window", async () => {
    const transport = fakeTransport(() => ok(validClientLease(30)));
    expect(await readReusableCmuxdRpcLease(transport, "/tmp/cmux/rpc.json")).toBeNull();
  });

  const nullCases: Array<[string, ExecResult]> = [
    ["malformed JSON", ok("{not json")],
    ["wrong shape", ok(JSON.stringify({ token: "" }))],
    ["non-zero exit", { exitCode: 1, stdout: "", stderr: "missing" }],
  ];
  for (const [label, result] of nullCases) {
    test(`returns null on ${label}`, async () => {
      const transport = fakeTransport(() => result);
      expect(await readReusableCmuxdRpcLease(transport, "/tmp/cmux/rpc.json")).toBeNull();
    });
  }

  test("returns null when exec throws (SDKs that throw on non-zero exit)", async () => {
    const transport = fakeTransport(() => {
      throw new Error("command exited with code 1");
    });
    expect(await readReusableCmuxdRpcLease(transport, "/tmp/cmux/rpc.json")).toBeNull();
  });
});

describe("atomicJsonInstallCommands", () => {
  test("writes through a temp file and renames over the target", () => {
    const commands = atomicJsonInstallCommands("/tmp/cmux/lease.json", { a: 1 });
    const joined = commands.join(" && ");
    expect(commands[0]).toBe("mkdir -p '/tmp/cmux' && chmod 700 '/tmp/cmux'");
    expect(joined).toMatch(/base64 -d > '\/tmp\/cmux\/lease\.json\.tmp-[0-9a-f]{12}'/);
    expect(joined).toMatch(/chmod 600 '\/tmp\/cmux\/lease\.json\.tmp-[0-9a-f]{12}'/);
    expect(joined).toMatch(/mv -f '\/tmp\/cmux\/lease\.json\.tmp-[0-9a-f]{12}' '\/tmp\/cmux\/lease\.json'/);
    const encoded = /printf '%s' '([A-Za-z0-9+/=]+)'/.exec(joined)?.[1];
    expect(encoded).toBeTruthy();
    expect(JSON.parse(Buffer.from(encoded!, "base64").toString("utf8"))).toEqual({ a: 1 });
  });
});

describe("installCmuxdAttachLeases", () => {
  test("mints PTY and RPC leases and installs everything in one exec round-trip", async () => {
    const transport = fakeTransport((command) =>
      // The RPC-lease read probe fails (no existing lease); the install write succeeds.
      command.startsWith("test -s") ? { exitCode: 1, stdout: "", stderr: "" } : ok(),
    );
    const leases = await installCmuxdAttachLeases(transport, {
      ptyLeasePath: "/tmp/cmux/pty.json",
      rpcLeasePath: "/tmp/cmux/rpc.json",
    });
    expect(leases.daemon).not.toBeNull();
    expect(leases.daemonReused).toBe(false);
    expect(leases.pty.token).toStartWith("cmux-blaxel-pty-");
    expect(leases.daemon?.token).toStartWith("cmux-blaxel-rpc-");
    expect(leases.attachmentId).toStartWith("cmux-blaxel-");
    // Exactly two execs: the reuse probe and ONE combined install.
    expect(transport.commands).toHaveLength(2);
    const install = transport.commands[1]!;
    expect(install).toContain("mv -f '/tmp/cmux/pty.json");
    expect(install).toContain("mv -f '/tmp/cmux/rpc.json");
    expect(install).toContain(`mv -f '${CMUXD_WS_RPC_CLIENT_PATH}`);
  });

  test("reuses a valid RPC lease and only rewrites the PTY lease", async () => {
    const transport = fakeTransport((command) =>
      command.startsWith("test -s") ? ok(validClientLease()) : ok(),
    );
    const leases = await installCmuxdAttachLeases(transport, {
      ptyLeasePath: "/tmp/cmux/pty.json",
      rpcLeasePath: "/tmp/cmux/rpc.json",
    });
    expect(leases.daemonReused).toBe(true);
    expect(leases.daemon?.token).toBe("rpc-token");
    const install = transport.commands[1]!;
    expect(install).toContain("mv -f '/tmp/cmux/pty.json");
    expect(install).not.toContain("/tmp/cmux/rpc.json.tmp-");
  });

  test("honors a pinned session id and attachment id", async () => {
    const transport = fakeTransport(() => ok());
    const leases = await installCmuxdAttachLeases(
      transport,
      { ptyLeasePath: "/tmp/cmux/pty.json", rpcLeasePath: null },
      { sessionId: "stable-session", attachmentId: "attachment-9" },
    );
    expect(leases.pty.sessionId).toBe("stable-session");
    expect(leases.attachmentId).toBe("attachment-9");
    expect(leases.daemon).toBeNull();
    // No RPC path means no reuse probe: a single install exec.
    expect(transport.commands).toHaveLength(1);
  });

  test("throws when the install write fails", async () => {
    const transport = fakeTransport((command) =>
      command.startsWith("test -s")
        ? { exitCode: 1, stdout: "", stderr: "" }
        : { exitCode: 13, stdout: "", stderr: "read-only filesystem" },
    );
    await expect(
      installCmuxdAttachLeases(transport, { ptyLeasePath: "/tmp/cmux/pty.json", rpcLeasePath: null }),
    ).rejects.toThrow("cmuxd lease install failed with status 13: read-only filesystem");
  });
});

describe("installReusableCmuxdRpcLease", () => {
  test("mints and installs when no lease exists", async () => {
    const transport = fakeTransport((command) =>
      command.startsWith("test -s") ? { exitCode: 1, stdout: "", stderr: "" } : ok(),
    );
    const { daemon, daemonReused } = await installReusableCmuxdRpcLease(transport, "/tmp/cmux/rpc.json");
    expect(daemonReused).toBe(false);
    expect(daemon.token).toStartWith("cmux-blaxel-rpc-");
    expect(transport.commands[1]).toContain("mv -f '/tmp/cmux/rpc.json");
  });

  test("returns the existing lease without writing", async () => {
    const transport = fakeTransport(() => ok(validClientLease()));
    const { daemon, daemonReused } = await installReusableCmuxdRpcLease(transport, "/tmp/cmux/rpc.json");
    expect(daemonReused).toBe(true);
    expect(daemon.token).toBe("rpc-token");
    expect(transport.commands).toHaveLength(1);
  });
});

describe("cmuxd health checks", () => {
  const originalFetch = globalThis.fetch;

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  test("checkCmuxdHealthz hits /healthz with the provider headers", async () => {
    const seen: Array<{ url: string; headers: unknown }> = [];
    globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
      seen.push({ url: String(input), headers: init?.headers });
      return new Response("ok", { status: 200 });
    }) as typeof fetch;
    await checkCmuxdHealthz("https://vm.example.dev/", {
      label: "Blaxel",
      headers: { "X-Blaxel-Preview-Token": "t" },
    });
    expect(seen).toEqual([
      { url: "https://vm.example.dev/healthz", headers: { "X-Blaxel-Preview-Token": "t" } },
    ]);
  });

  test("non-200 raises the provider-labeled message the SSH-fallback classifier matches", async () => {
    globalThis.fetch = (async () => new Response("nope", { status: 502 })) as typeof fetch;
    await expect(checkCmuxdHealthz("https://vm.example.dev", { label: "Freestyle" })).rejects.toThrow(
      "Freestyle cmuxd websocket health check returned 502",
    );
    expect(await isCmuxdHealthy("https://vm.example.dev", { label: "Freestyle" })).toBe(false);
  });

  test("waitForCmuxdHealthy retries on the schedule until the daemon answers", async () => {
    let calls = 0;
    globalThis.fetch = (async () => {
      calls += 1;
      return new Response(calls < 3 ? "starting" : "ok", { status: calls < 3 ? 503 : 200 });
    }) as typeof fetch;
    await waitForCmuxdHealthy("https://vm.example.dev", { label: "Daytona", attempts: 5, intervalMs: 1 });
    expect(calls).toBe(3);
  });

  test("waitForCmuxdHealthy exhausts its attempts and rethrows the final probe error unchanged", async () => {
    let calls = 0;
    globalThis.fetch = (async () => {
      calls += 1;
      return new Response("nope", { status: 500 });
    }) as typeof fetch;
    const failure = waitForCmuxdHealthy("https://vm.example.dev", {
      label: "Freestyle",
      attempts: 4,
      intervalMs: 1,
    });
    await expect(failure).rejects.toThrow("Freestyle cmuxd websocket health check returned 500");
    await expect(failure).rejects.toBeInstanceOf(Error);
    expect(calls).toBe(4);
  });

  test("a network failure is labeled too", async () => {
    globalThis.fetch = (async () => {
      throw new Error("connect ECONNREFUSED");
    }) as typeof fetch;
    await expect(
      waitForCmuxdHealthy("https://vm.example.dev", { label: "Blaxel", attempts: 2, intervalMs: 1 }),
    ).rejects.toThrow("Blaxel cmuxd websocket health check failed: connect ECONNREFUSED");
  });
});
