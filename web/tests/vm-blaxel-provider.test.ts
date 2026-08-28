import { describe, expect, test } from "bun:test";
import {
  BlaxelProvider,
  DESKTOP_VNC_HEAL_COMMAND,
  SMART_SLEEP_SCRIPT,
  brandedPreviewPrefix,
  hostnameSetupCommand,
  parseMachineStats,
  BLAXEL_MAX_HOME_VOLUME_MB,
  CMUX_CLOUD_USER_SETUP_COMMAND,
  CMUX_HOME_BINDFS_COMMAND,
  CMUX_PROVISION_AGENT_PACKAGES,
  CMUX_PROVISION_COMMAND,
  CMUX_PROVISION_SCRIPT,
  CMUX_PROVISION_SCRIPT_PATH,
  CMUX_SUDO_INSTALL_COMMAND,
  userExecCommand,
  defaultHomeVolumeMbForMemory,
  resolveBlaxelMemoryMb,
  resolveHomeVolumeMb,
  sandboxEnvs,
  sandboxPorts,
  usablePrivatePreviewUrl,
} from "../services/vms/drivers/blaxel";
import { ProviderError } from "../services/vms/drivers/types";
import { providerEnabledEnvKey } from "../services/vms/config";
import { providerImageEnvKey, resolveVmImage } from "../services/vms/images/resolver";
import { defaultProviderId, getProvider } from "../services/vms/drivers";

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
    expect(selection.image).toBe("sandbox/cmux-devbox:latest");
    expect(selection.manifestEntry?.provider).toBe("blaxel");
  });
});

describe("BlaxelProvider session transport", () => {
  // Blaxel machines run the cmux-tui remote daemon and nothing else: no cmuxd-remote is
  // installed, so the legacy websocket PTY attach cannot exist. The driver declares the
  // one transport it serves and refuses openAttach outright instead of fabricating an
  // endpoint nothing listens on.
  test("declares cmux-remote as the only attach transport", () => {
    expect(new BlaxelProvider().attachTransports).toEqual(["cmux-remote"]);
  });

  test("openAttach is refused and points at the cmux-tui transport", async () => {
    const provider = new BlaxelProvider();
    await expect(provider.openAttach("cmux-vm-test", { requireDaemon: true })).rejects.toThrow(ProviderError);
    await expect(provider.openAttach("cmux-vm-test")).rejects.toThrow("transport cmux-remote");
  });

  test("the sandbox exposes only the cmux-tui daemon port", () => {
    expect(sandboxPorts()).toEqual([{ name: "cmuxtui", protocol: "HTTP", target: 1337 }]);
  });

  test("machine env always carries LANG and appends caller env after it", () => {
    expect(sandboxEnvs()).toEqual([{ name: "LANG", value: "C.UTF-8" }]);
    expect(
      sandboxEnvs({ OPENAI_BASE_URL: "https://cmux.example/v1", OPENAI_API_KEY: "crt_x" }),
    ).toEqual([
      { name: "LANG", value: "C.UTF-8" },
      { name: "OPENAI_BASE_URL", value: "https://cmux.example/v1" },
      { name: "OPENAI_API_KEY", value: "crt_x" },
    ]);
    // LANG is the image contract; a caller-supplied LANG never overrides it.
    expect(sandboxEnvs({ LANG: "en_US.UTF-8" })).toEqual([{ name: "LANG", value: "C.UTF-8" }]);
  });

  test("the smart-sleep watcher only knows the cmux-tui daemon", () => {
    expect(SMART_SLEEP_SCRIPT).toContain("pidof cmux-tui");
    expect(SMART_SLEEP_SCRIPT).toContain("0539");
    expect(SMART_SLEEP_SCRIPT).not.toContain("cmuxd");
    expect(SMART_SLEEP_SCRIPT).not.toContain("7777");
    expect(SMART_SLEEP_SCRIPT).not.toContain("1E61");
  });

  test("the machine's bare branded hostname belongs to the cmux-tui daemon preview", () => {
    expect(brandedPreviewPrefix("noble-wren", "cmuxtui", 1337)).toBe("noble-wren");
    expect(brandedPreviewPrefix("noble-wren", "port-3000", 3000)).toBe("noble-wren-3000");
    expect(brandedPreviewPrefix("Not Valid!", "cmuxtui", 1337)).toBeNull();
  });
});

describe("BlaxelProvider SSH surface", () => {
  test("openSSH is unsupported and points at the cmux-tui transport", async () => {
    const provider = new BlaxelProvider();

    await expect(provider.openSSH("cmux-vm-test")).rejects.toThrow(ProviderError);
    await expect(provider.openSSH("cmux-vm-test")).rejects.toThrow("cmux-tui remote daemon");
  });

  test("revokeSSHIdentity is a safe no-op", async () => {
    const provider = new BlaxelProvider();

    await expect(provider.revokeSSHIdentity("anything")).resolves.toBeUndefined();
    await expect(provider.revokeSSHIdentity("")).resolves.toBeUndefined();
  });

  test("revokes the cmux-tui daemon and every preview ingress on sign-out", async () => {
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
          { metadata: { name: "cmuxtui" } },
          { metadata: { name: "cmuxtui-raw" } },
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
      // cmux-tui only: stop the keepalive watcher and the daemon, nothing cmuxd-shaped.
      expect(processCall?.body).toContain("pkill -TERM -x 'cmux-keepalive'");
      expect(processCall?.body).toContain("server start");
      expect(processCall?.body).not.toContain("cmuxd");
      expect(processCall?.body).not.toContain("attach-pty-lease.json");
      expect(calls.filter((call) => call.method === "DELETE")).toHaveLength(3);
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

  test("home volume follows memory in dev-box tiers unless the env pins a size", () => {
    expect(defaultHomeVolumeMbForMemory(2048)).toBe(8 * 1024);
    expect(defaultHomeVolumeMbForMemory(8 * 1024)).toBe(16 * 1024);
    expect(defaultHomeVolumeMbForMemory(16 * 1024)).toBe(16 * 1024);
    // The plan default (24 GB) lands in the 64 GB tier, not a flat 5 GB.
    // Blaxel refuses anything above 16 GB, so every larger machine sits at the ceiling.
    expect(defaultHomeVolumeMbForMemory(24 * 1024)).toBe(BLAXEL_MAX_HOME_VOLUME_MB);
    expect(defaultHomeVolumeMbForMemory(32 * 1024)).toBe(BLAXEL_MAX_HOME_VOLUME_MB);
    expect(defaultHomeVolumeMbForMemory(48 * 1024)).toBe(BLAXEL_MAX_HOME_VOLUME_MB);
    expect(() => defaultHomeVolumeMbForMemory(0)).toThrow("positive");

    expect(resolveHomeVolumeMb(24 * 1024, {})).toBe(16 * 1024);
    expect(resolveHomeVolumeMb(24 * 1024, { CMUX_VM_BLAXEL_HOME_VOLUME_MB: "5120" })).toBe(5120);
    expect(resolveHomeVolumeMb(24 * 1024, { CMUX_VM_BLAXEL_HOME_VOLUME_MB: "nope" })).toBe(16 * 1024);
  });

  test("uses the request memory and preserves the env fallback", () => {
    expect(resolveBlaxelMemoryMb(8192, { CMUX_VM_BLAXEL_MEMORY_MB: "4096" })).toBe(8192);
    expect(resolveBlaxelMemoryMb(undefined, { CMUX_VM_BLAXEL_MEMORY_MB: "16384" })).toBe(16384);
    expect(resolveBlaxelMemoryMb(undefined, {})).toBe(4096);
    expect(() => resolveBlaxelMemoryMb(0, {})).toThrow("memoryMb must be a positive integer");
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

describe("background provisioning", () => {
  test("installs the standard toolset, the agents, and the CUA driver on both distro families", () => {
    expect(CMUX_PROVISION_COMMAND).toBe(`bash ${CMUX_PROVISION_SCRIPT_PATH}`);
    expect(CMUX_PROVISION_SCRIPT.startsWith("#!/bin/bash")).toBe(true);
    // Ubuntu (xfce-vnc) and Alpine (base-image) both provision.
    expect(CMUX_PROVISION_SCRIPT).toContain("apt-get install");
    expect(CMUX_PROVISION_SCRIPT).toContain("apk add");
    for (const tool of ["ripgrep", "jq", "tmux", "git", "curl", "xdotool", "nodesource", "cli.github.com", "bun.sh/install", "astral.sh/uv"]) {
      expect(CMUX_PROVISION_SCRIPT).toContain(tool);
    }
    for (const pkg of CMUX_PROVISION_AGENT_PACKAGES) {
      expect(CMUX_PROVISION_SCRIPT).toContain(pkg);
    }
    expect(CMUX_PROVISION_SCRIPT).toContain("cua-computer-server");
    // Persistent-home placement: npm globals and bun survive sandbox resurrection,
    // in the cmux user's home (the volume mount), never /root.
    expect(CMUX_PROVISION_SCRIPT).toContain("npm config set prefix /home/cmux/.npm-global");
    expect(CMUX_PROVISION_SCRIPT).toContain("/home/cmux/.bun/bin/bun");
    expect(CMUX_PROVISION_SCRIPT).not.toContain("/root/.npm-global");
    expect(CMUX_PROVISION_SCRIPT).not.toContain("/root/.bun");
    // The stock-image path installs sudo too (baked images already ship it).
    expect(CMUX_PROVISION_SCRIPT).toMatch(/apt-get install[^\n]*\n[^\n]*\bsudo\b/);
    expect(CMUX_PROVISION_SCRIPT).toMatch(/apk add[^\n]*\bsudo\b/);
    // Root-run provisioning hands what it wrote in the home to the work user.
    expect(CMUX_PROVISION_SCRIPT).toContain("chown -R cmux:cmux /home/cmux/.bun /home/cmux/.npm-global /home/cmux/.local");
    expect(CMUX_PROVISION_SCRIPT).toContain("/tmp/cmux/provision.log");
  });
});

describe("cloud work user setup", () => {
  test("creates the cmux user idempotently with passwordless sudo policy", () => {
    // uid 1001 keeps volume ownership stable across image generations; busybox
    // adduser is the Alpine fallback; reruns are no-ops thanks to the id guard.
    expect(CMUX_CLOUD_USER_SETUP_COMMAND).toContain("id -u cmux >/dev/null 2>&1 || useradd -m -u 1001 -s /bin/bash cmux");
    expect(CMUX_CLOUD_USER_SETUP_COMMAND).toContain("adduser -D -s /bin/bash cmux");
    expect(CMUX_CLOUD_USER_SETUP_COMMAND).toContain("printf 'cmux ALL=(ALL) NOPASSWD:ALL\\n' > /etc/sudoers.d/90-cmux-nopasswd");
    expect(CMUX_CLOUD_USER_SETUP_COMMAND).toContain("chmod 0440 /etc/sudoers.d/90-cmux-nopasswd");
  });

  test("presents the root-squashing volume as cmux-owned through the bindfs view", () => {
    // The Blaxel volume is virtiofs that squashes every guest identity to root
    // (chown no-ops; a cmux-created file comes back root-owned and unwritable), so
    // the home the user sees is a bindfs map over the backing mount: everything
    // shown as cmux, real I/O done as root.
    expect(CMUX_HOME_BINDFS_COMMAND).toContain("bindfs -o allow_other");
    expect(CMUX_HOME_BINDFS_COMMAND).toContain("--force-user=cmux --force-group=cmux");
    expect(CMUX_HOME_BINDFS_COMMAND).toContain("--create-for-user=root --create-for-group=root");
    expect(CMUX_HOME_BINDFS_COMMAND).toContain("/cmux/home /home/cmux");
    // The view mounts only when this machine has a volume, once, and bindfs is
    // installed on demand for images that predate it being baked in.
    expect(CMUX_CLOUD_USER_SETUP_COMMAND).toContain(CMUX_HOME_BINDFS_COMMAND);
    expect(CMUX_CLOUD_USER_SETUP_COMMAND).toContain("if mountpoint -q /cmux/home 2>/dev/null && ! mountpoint -q /home/cmux 2>/dev/null");
    expect(CMUX_CLOUD_USER_SETUP_COMMAND).toContain("apt-get install -y -qq --no-install-recommends bindfs");
  });

  test("sudo heal covers images baked before the sudo package (and stock Alpine)", () => {
    expect(CMUX_SUDO_INSTALL_COMMAND).toContain("command -v sudo >/dev/null 2>&1");
    expect(CMUX_SUDO_INSTALL_COMMAND).toContain("apt-get install -y -qq --no-install-recommends sudo");
    expect(CMUX_SUDO_INSTALL_COMMAND).toContain("apk add --no-cache sudo");
  });

  test("user-facing exec runs as the work user, root only via legacy volume or sudo", () => {
    const wrapped = userExecCommand("echo 'hi there'");
    expect(wrapped).toContain("runuser -u cmux -- env HOME=/home/cmux USER=cmux LOGNAME=cmux sh -c 'echo '\\''hi there'\\'''");
    // Legacy sandboxes (volume at /root) keep the historical root exec.
    expect(wrapped).toContain("if mountpoint -q /root 2>/dev/null; then exec env HOME=/root sh -c");
    // No user/runuser: fall back to root rather than failing the exec.
    expect(wrapped).toContain("else exec env HOME=/home/cmux sh -c");
  });
});
