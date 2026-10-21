import { describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { runChild } from "./helpers/run-child";

// The cloud browser role of the devbox image (plans/cmux-next/cloud-browser-DESIGN.md
// CB-2, section 4a): the launcher runs `cmux-rd host --browser` on the desktop display
// with CDP on loopback for an agent on the VM. Off by default. These tests run the
// shipped launcher against a fake `cmux-rd` and check what it actually starts.

const LAUNCHER = join(dirname(fileURLToPath(import.meta.url)), "../services/vms/images/devbox/desktop/cmux-cloud-browser");

type Run = { code: number; stderr: string; argv: string[] | null; token: string | null; tokenFileMode: number | null };

async function run(env: Record<string, string>): Promise<Run> {
  const dir = mkdtempSync(join(tmpdir(), "cmux-cloud-browser-"));
  try {
    const fake = join(dir, "cmux-rd");
    // Records its argv and the token it reads from --token-fd, then exits.
    writeFileSync(
      fake,
      `#!/bin/bash
printf '%s\\n' "$@" > "${dir}/argv"
fd=""; prev=""
for a in "$@"; do [ "$prev" = "--token-fd" ] && fd="$a"; prev="$a"; done
[ -n "$fd" ] && cat <&"$fd" > "${dir}/token"
exit 0
`,
    );
    chmodSync(fake, 0o755);
    const r = await runChild("bash", [LAUNCHER], {
      env: { NODE_ENV: "test", PATH: `${dir}:/usr/bin:/bin`, HOME: dir, CMUX_CLOUD_BROWSER_STATE_DIR: dir, ...env },
      timeout: 5_000,
    });
    const read = (f: string) => {
      try {
        return readFileSync(join(dir, f), "utf8");
      } catch {
        return null;
      }
    };
    let mode: number | null = null;
    try {
      mode = statSync(join(dir, "rd.token")).mode & 0o777;
    } catch {
      mode = null;
    }
    const argv = read("argv");
    return { code: r.status ?? -1, stderr: r.stderr, argv: argv ? argv.trimEnd().split("\n") : null, token: read("token"), tokenFileMode: mode };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const after = (argv: string[], flag: string) => argv[argv.indexOf(flag) + 1];

describe("devbox cloud browser launcher", () => {
  test("is off by default: without CMUX_CLOUD_BROWSER=1 it starts nothing", async () => {
    const r = await run({});
    expect(r.code).toBe(0);
    expect(r.argv).toBeNull();
  });

  test("when on, runs the cmux-rd host with the browser on the desktop display and CDP on loopback", async () => {
    const r = await run({ CMUX_CLOUD_BROWSER: "1", CMUX_CLOUD_BROWSER_URL: "https://example.com/" });
    expect(r.code).toBe(0);
    const argv = r.argv!;
    expect(argv[0]).toBe("host");
    expect(after(argv, "--browser")).toBe("https://example.com/");
    expect(after(argv, "--browser-cdp-port")).toBe("9222");
    expect(after(argv, "--display")).toBe(":1");
    expect(after(argv, "--port")).toBe("4103");
    // Loopback only: no single-tenant overlay opt-in, no non-loopback bind.
    expect(argv).not.toContain("--single-tenant-overlay");
    expect(argv.includes("--bind") ? after(argv, "--bind") : "127.0.0.1").toBe("127.0.0.1");
    // The session token reaches the host through a pipe, 64 hex characters.
    expect(r.token).toMatch(/^[0-9a-f]{64}$/);
    expect(r.tokenFileMode).toBe(0o600);
  });

  test("refuses a CDP port that is not a number, instead of starting Chrome with it", async () => {
    const r = await run({ CMUX_CLOUD_BROWSER: "1", CMUX_CLOUD_BROWSER_CDP_PORT: "9222; rm -rf /" });
    expect(r.code).not.toBe(0);
    expect(r.argv).toBeNull();
  });

  test("names the missing binary when cmux-rd is not installed", async () => {
    const dir = mkdtempSync(join(tmpdir(), "cmux-cloud-browser-none-"));
    try {
      const r = await runChild("bash", [LAUNCHER], {
        env: { NODE_ENV: "test", PATH: "/usr/bin:/bin", HOME: dir, CMUX_CLOUD_BROWSER_STATE_DIR: dir, CMUX_CLOUD_BROWSER: "1" },
        timeout: 5_000,
      });
      expect(r.status).not.toBe(0);
      expect(r.stderr).toContain("cmux-rd");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
