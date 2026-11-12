// The Mac's login installer (CloudCredentialInstaller.script), run for real against a scratch home and policy folder.
// Leo, V0 item 1: "A chat starts in a few seconds: ready spare, harness login attached in advance, ...". With the
// spare-ready copy and the claim's copy, a spare that already holds the login is the normal case: the same account's
// same login is a no-op success, another account's replaces it, and two installs at once leave one whole login.
import { describe, expect, test } from "bun:test";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { INSTALLER_SWIFT, swiftRawString } from "./cloud-journey";

const CODEROUTER = "https://coderouter.example.test";

/** The installer, pointed at `policy` and the current user's scratch `HOME` instead of /etc/cmux and the cmux user. */
function installer(policy: string): string {
  const script = swiftRawString(readFileSync(INSTALLER_SWIFT, "utf8"), "script");
  const patched = script
    .replace("pathlib.Path('/etc/cmux')", `pathlib.Path(${JSON.stringify(policy)})`)
    .replace("pwd.getpwnam('cmux')", "pwd.getpwuid(os.getuid())")
    .replace("home = pathlib.Path(user.pw_dir)", "home = pathlib.Path(os.environ['HOME'])");
  expect(patched).not.toContain("/etc/cmux");
  expect(patched).not.toContain("getpwnam('cmux')");
  return patched;
}

function scratch() {
  const root = mkdtempSync(join(tmpdir(), "cred-install-"));
  const policy = join(root, "policy"), home = join(root, "home");
  mkdirSync(policy); mkdirSync(home);
  writeFileSync(join(policy, "vm-kind"), "owner\n");
  writeFileSync(join(policy, "agent-auth.sh"), "");
  let n = 0;
  const payload = (value: string) => {
    const path = join(root, `payload-${n++}.json`);
    writeFileSync(path, value, { mode: 0o600 });
    return path;
  };
  const env = { PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, CMUX_CODEROUTER_URL: CODEROUTER };
  const args = (path: string, account: string) => ["-", "claude", path, "owner", account];
  return {
    root, home, policy, env, payload, script: installer(policy),
    install(value: string, account: string) {
      const path = payload(value);
      const r = spawnSync("python3", args(path, account), { input: this.script, env, encoding: "utf8" });
      return { code: r.status, payloadLeft: existsSync(path) };
    },
    installAsync(value: string, account: string) {
      const path = payload(value);
      return new Promise<number | null>((resolve) => {
        const child = spawn("python3", args(path, account), { env, stdio: ["pipe", "ignore", "ignore"] });
        child.on("close", resolve);
        child.stdin.end(this.script);
      });
    },
    settings: () => JSON.parse(readFileSync(join(home, ".claude/settings.json"), "utf8")),
    mark: () => JSON.parse(readFileSync(join(home, ".config/cmux/agent-auth/claude.login"), "utf8")),
    mode: () => readFileSync(join(home, ".config/cmux/agent-auth/claude"), "utf8").trim(),
    cleanup: () => rmSync(root, { recursive: true, force: true }),
  };
}

const sha = (text: string) => createHash("sha256").update(text).digest("hex");
const TOKEN_A = `sk-ant-oat01-${"a".repeat(40)}`;
const TOKEN_B = `sk-ant-oat01-${"b".repeat(40)}`;

describe("the login installer is idempotent", () => {
  test("installs twice for one account (the second a no-op), then swaps accounts", () => {
    const s = scratch();
    try {
      expect(s.install(TOKEN_A, "user_a")).toEqual({ code: 0, payloadLeft: false });
      expect(s.settings().env.CLAUDE_CODE_OAUTH_TOKEN).toBe(TOKEN_A);
      expect(s.mark()).toEqual({ account: "user_a", digest: sha(TOKEN_A) });
      expect(s.mode()).toBe("own");
      const settingsPath = join(s.home, ".claude/settings.json");
      const before = statSync(settingsPath).mtimeMs;
      // The mark holds the account and a digest, never the login.
      expect(readFileSync(join(s.home, ".config/cmux/agent-auth/claude.login"), "utf8")).not.toContain(TOKEN_A);

      // Same account, same login: success, nothing written, the payload still removed.
      expect(s.install(TOKEN_A, "user_a")).toEqual({ code: 0, payloadLeft: false });
      expect(statSync(settingsPath).mtimeMs).toBe(before);

      // Another account: its login replaces the first.
      expect(s.install(TOKEN_B, "user_b")).toEqual({ code: 0, payloadLeft: false });
      expect(s.settings().env.CLAUDE_CODE_OAUTH_TOKEN).toBe(TOKEN_B);
      expect(s.mark()).toEqual({ account: "user_b", digest: sha(TOKEN_B) });
      const credentials = JSON.parse(readFileSync(join(s.home, ".claude/.credentials.json"), "utf8"));
      expect(credentials.claudeAiOauth.accessToken).toBe(TOKEN_B);

      // The same account with a new login (a refresh) replaces it too.
      expect(s.install(TOKEN_A, "user_b")).toEqual({ code: 0, payloadLeft: false });
      expect(s.mark()).toEqual({ account: "user_b", digest: sha(TOKEN_A) });
    } finally {
      s.cleanup();
    }
  });

  test("a settings env with the image's stub endpoint and key installs and drops them; a custom endpoint still refuses", () => {
    const s = scratch();
    try {
      mkdirSync(join(s.home, ".claude"), { recursive: true });
      const settingsPath = join(s.home, ".claude/settings.json");
      writeFileSync(settingsPath, JSON.stringify({ env: { ANTHROPIC_BASE_URL: `${CODEROUTER}/`, ANTHROPIC_API_KEY: "cmux-vm-edge-placeholder", CLAUDE_CODE_OAUTH_TOKEN: "old" }, theme: "dark" }));
      expect(s.install(TOKEN_A, "user_a").code).toBe(0);
      expect(s.settings()).toEqual({ env: { CLAUDE_CODE_OAUTH_TOKEN: TOKEN_A }, theme: "dark" });
      // Installed again on top of its own install: success.
      expect(s.install(TOKEN_A, "user_a").code).toBe(0);

      // The probe's case (hq run 43141069827): after the install, something points Claude at a loopback endpoint. The
      // same account's same login is still a no-op success; it sends nothing new there. Another account's still refuses.
      const installed = s.settings();
      writeFileSync(settingsPath, JSON.stringify({ ...installed, env: { ...installed.env, ANTHROPIC_BASE_URL: "http://127.0.0.1:1" } }));
      expect(s.install(TOKEN_A, "user_a")).toEqual({ code: 0, payloadLeft: false });
      expect(s.settings().env.ANTHROPIC_BASE_URL).toBe("http://127.0.0.1:1");
      expect(s.install(TOKEN_B, "user_b")).toEqual({ code: 72, payloadLeft: false });

      writeFileSync(settingsPath, JSON.stringify({ env: { ANTHROPIC_BASE_URL: "https://my-proxy.example.test" } }));
      expect(s.install(TOKEN_B, "user_b")).toEqual({ code: 72, payloadLeft: false });
      expect(s.settings().env.CLAUDE_CODE_OAUTH_TOKEN).toBeUndefined();
      writeFileSync(settingsPath, JSON.stringify({ env: { ANTHROPIC_API_KEY: "sk-ant-api03-mine" } }));
      expect(s.install(TOKEN_B, "user_b").code).toBe(72);
      writeFileSync(settingsPath, JSON.stringify({ apiKeyHelper: "x" }));
      expect(s.install(TOKEN_B, "user_b").code).toBe(72);
    } finally {
      s.cleanup();
    }
  });

  test("installs at once from two accounts leave one whole login that matches its mark", async () => {
    for (let round = 0; round < 5; round++) {
      const s = scratch();
      try {
        const codes = await Promise.all(Array.from({ length: 8 }, (_, i) => s.installAsync(i % 2 ? TOKEN_B : TOKEN_A, i % 2 ? "user_b" : "user_a")));
        expect(codes).toEqual(Array(8).fill(0));
        const token = s.settings().env.CLAUDE_CODE_OAUTH_TOKEN;
        expect([TOKEN_A, TOKEN_B]).toContain(token);
        expect(s.mark()).toEqual({ account: token === TOKEN_A ? "user_a" : "user_b", digest: sha(token) });
        expect(s.mode()).toBe("own");
      } finally {
        s.cleanup();
      }
    }
  });
});
