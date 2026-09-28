import { afterEach, describe, expect, test } from "bun:test";
import { spawn, spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import { AGENT_PIN_ARGS, devboxAgentPins } from "../scripts/devbox-image-common";
import { parseAgentUpdatesBody, parseCreateAgentUpdates } from "../services/vms/agentUpdatesRoute";
import {
  GUEST_AGENT_PACKAGES,
  GUEST_AGENT_UPDATES_LOG,
  guestAgentUpdaterCommand,
  guestAgentUpdatesCommand,
  guestAgentUpdatesScript,
  type GuestAgentUpdaterOptions,
} from "../services/vms/guestAgentUpdates";

// A fake npm that keeps the "installed" and "registry" state in JSON files, so
// the real updater script runs end to end without a network or a global npm.
const FAKE_NPM = String.raw`#!/usr/bin/env python3
import json, os, sys
d = os.environ["FAKE_NPM_DIR"]
args = sys.argv[1:]
with open(os.path.join(d, "calls.log"), "a") as log:
    log.write(" ".join(args) + "\n")
installed_path = os.path.join(d, "installed.json")
installed = json.load(open(installed_path))
if args[0] == "ls":
    print(json.dumps({"dependencies": {name: {"version": version} for name, version in installed.items()}}))
elif args[0] == "view":
    if os.path.exists(os.path.join(d, "offline")):
        sys.stderr.write("npm error code ETIMEDOUT\nnpm error network request to https://registry.npmjs.org failed\n")
        sys.exit(1)
    print(json.load(open(os.path.join(d, "latest.json")))[args[1]])
elif args[0] == "install":
    for spec in args[1:]:
        if spec.startswith("-"):
            continue
        name, _, version = spec.rpartition("@")
        installed[name] = version
    json.dump(installed, open(installed_path, "w"))
`;

const PINNED = Object.fromEntries(GUEST_AGENT_PACKAGES.map(({ pkg }) => [pkg, "1.0.0"]));

type Guest = {
  readonly root: string;
  readonly configDir: string;
  readonly nvmBin: string;
  readonly options: GuestAgentUpdaterOptions;
  readonly env: NodeJS.ProcessEnv;
};

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

/** A guest tree shaped like the bake: nvm bin links into package dirs, /usr/local/bin links, the opencode wrapper chain. */
function guest(setting: "latest" | "image" | null = "latest"): Guest {
  const root = realpathSync(mkdtempSync(path.join(tmpdir(), "cmux-agent-updates-")));
  roots.push(root);
  const nvmBin = path.join(root, "nvm/bin");
  const modules = path.join(root, "nvm/lib/node_modules");
  const binDir = path.join(root, "usr/local/bin");
  const libexecDir = path.join(root, "usr/local/libexec");
  const configDir = path.join(root, "etc/cmux");
  const npmDir = path.join(root, "npm-state");
  for (const dir of [nvmBin, modules, binDir, libexecDir, configDir, npmDir]) mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(nvmBin, "node"), "#!/bin/sh\n");
  chmodSync(path.join(nvmBin, "node"), 0o755);
  symlinkSync(path.join(nvmBin, "node"), path.join(binDir, "node"));
  writeFileSync(path.join(nvmBin, "npm"), FAKE_NPM);
  chmodSync(path.join(nvmBin, "npm"), 0o755);
  for (const { pkg, binary } of GUEST_AGENT_PACKAGES) {
    const bin = path.join(modules, pkg, "bin", binary);
    mkdirSync(path.dirname(bin), { recursive: true });
    writeFileSync(bin, "#!/bin/sh\n");
    chmodSync(bin, 0o755);
    symlinkSync(bin, path.join(nvmBin, binary));
  }
  // opencode: /usr/local/bin/opencode is the wrapper; the real binary sits behind libexec.
  writeFileSync(path.join(configDir, "opencode"), "#!/bin/bash\n");
  chmodSync(path.join(configDir, "opencode"), 0o755);
  symlinkSync(path.join(configDir, "opencode"), path.join(binDir, "opencode"));
  symlinkSync(realpathSync(path.join(nvmBin, "opencode")), path.join(libexecDir, "cmux-opencode-real"));
  writeFileSync(path.join(npmDir, "installed.json"), JSON.stringify(PINNED));
  writeFileSync(path.join(npmDir, "latest.json"), JSON.stringify(PINNED));
  if (setting) writeFileSync(path.join(configDir, "agent-updates"), `${setting}\n`);
  return {
    root,
    configDir,
    nvmBin,
    options: {
      packages: GUEST_AGENT_PACKAGES,
      node: path.join(binDir, "node"),
      binDir,
      libexecDir,
      intervalSeconds: 24 * 60 * 60,
    },
    env: { ...process.env, FAKE_NPM_DIR: npmDir },
  };
}

function runUpdater(g: Guest) {
  return spawnSync("sh", ["-c", guestAgentUpdaterCommand(g.configDir, g.options)], { env: g.env, encoding: "utf8" });
}

function npmCalls(g: Guest): string[] {
  const log = path.join(g.root, "npm-state/calls.log");
  return existsSync(log) ? readFileSync(log, "utf8").trim().split("\n").filter(Boolean) : [];
}

function state(g: Guest): { checkedAt: string; ok: boolean; versions: Record<string, string>; error?: string } {
  return JSON.parse(readFileSync(path.join(g.configDir, "agent-updates.state"), "utf8"));
}

function setLatest(g: Guest, versions: Record<string, string>) {
  writeFileSync(path.join(g.root, "npm-state/latest.json"), JSON.stringify({ ...PINNED, ...versions }));
}

describe("guest agent updates", () => {
  test("the updated packages are exactly the ones the devbox bakes", () => {
    expect(GUEST_AGENT_PACKAGES.map(({ pkg, binary }) => ({ pkg, binary })))
      .toEqual(AGENT_PIN_ARGS.map(({ pkg, binary }) => ({ pkg, binary })));
    expect(GUEST_AGENT_PACKAGES.map(({ pkg }) => pkg)).toEqual(devboxAgentPins().map((pin) => pin.pkg));
  });

  test("image only records the setting; latest also starts a detached updater", () => {
    const image = guestAgentUpdatesCommand("image");
    expect(image).toContain("image > \"$tmp\"");
    expect(image).toContain("/etc/cmux/agent-updates");
    expect(image).not.toContain("setsid");
    const latest = guestAgentUpdatesCommand("latest");
    expect(latest).toContain("latest > \"$tmp\"");
    expect(latest).toContain("setsid nohup python3 -c");
    expect(latest).toContain(GUEST_AGENT_UPDATES_LOG);
    // Root runs it directly; the work user goes through passwordless sudo.
    expect(latest.startsWith(`if [ "$(id -u)" = 0 ]; then sh -c `)).toBe(true);
    expect(latest).toContain("else sudo -n sh -c ");
    for (const command of [image, latest]) {
      expect(spawnSync("sh", ["-n", "-c", command]).status).toBe(0);
    }
  });

  test("the script records the setting atomically and starts the updater detached", async () => {
    const g = guest(null);
    setLatest(g, { "@openai/codex": "2.0.0" });
    const log = path.join(g.root, "updates.log");
    const paths = { configDir: g.configDir, log, updater: g.options };
    // setsid is util-linux; stand in for it where the test host has none (macOS).
    const shims = path.join(g.root, "shims");
    mkdirSync(shims);
    writeFileSync(path.join(shims, "setsid"), "#!/bin/sh\nexec \"$@\"\n");
    chmodSync(path.join(shims, "setsid"), 0o755);
    const env = { ...g.env, PATH: `${g.env.PATH}:${shims}` };
    const recorded = spawnSync("sh", ["-c", guestAgentUpdatesScript("image", paths)], { env, encoding: "utf8" });
    expect(recorded.status).toBe(0);
    expect(readFileSync(path.join(g.configDir, "agent-updates"), "utf8")).toBe("image\n");
    expect(npmCalls(g)).toEqual([]);

    const launched = spawnSync("sh", ["-c", guestAgentUpdatesScript("latest", paths)], { env, encoding: "utf8" });
    expect(launched.status).toBe(0);
    expect(readFileSync(path.join(g.configDir, "agent-updates"), "utf8")).toBe("latest\n");
    const statePath = path.join(g.configDir, "agent-updates.state");
    for (let i = 0; i < 80 && !existsSync(statePath); i += 1) await new Promise((resolve) => setTimeout(resolve, 50));
    expect(state(g)).toMatchObject({ ok: true, versions: { "@openai/codex": "2.0.0" } });
    expect(readFileSync(log, "utf8")).toContain("installing @openai/codex@2.0.0");
  });

  test("installs only the packages behind latest and re-asserts the bake's links", () => {
    const g = guest();
    setLatest(g, { "@anthropic-ai/claude-code": "2.0.0", "opencode-ai": "1.2.0" });
    // A stale link the relink must repair.
    rmSync(path.join(g.options.binDir, "codex"), { force: true });
    const result = runUpdater(g);
    expect(result.status).toBe(0);
    const install = npmCalls(g).filter((call) => call.startsWith("install"));
    expect(install).toEqual(["install -g --foreground-scripts @anthropic-ai/claude-code@2.0.0 opencode-ai@1.2.0"]);
    expect(state(g)).toMatchObject({ ok: true, versions: { "@anthropic-ai/claude-code": "2.0.0", "opencode-ai": "1.2.0", "@openai/codex": "1.0.0" } });
    for (const { binary } of GUEST_AGENT_PACKAGES) {
      const entry = readlinkSync(path.join(g.options.binDir, binary));
      expect(entry).toBe(binary === "opencode" ? path.join(g.configDir, "opencode") : path.join(g.nvmBin, binary));
    }
    expect(readlinkSync(path.join(g.options.libexecDir, "cmux-opencode-real"))).toBe(realpathSync(path.join(g.nvmBin, "opencode")));
  });

  test("a successful check suppresses the next one for a day", () => {
    const g = guest();
    expect(runUpdater(g).status).toBe(0);
    const calls = npmCalls(g).length;
    setLatest(g, { "@openai/codex": "9.9.9" });
    expect(runUpdater(g).status).toBe(0);
    expect(npmCalls(g).length).toBe(calls);

    // An old check no longer throttles.
    const stale = { ...state(g), checkedAt: "2020-01-01T00:00:00Z" };
    writeFileSync(path.join(g.configDir, "agent-updates.state"), JSON.stringify(stale));
    expect(runUpdater(g).status).toBe(0);
    expect(npmCalls(g)).toContain("install -g --foreground-scripts @openai/codex@9.9.9");
  });

  test("a failed check is recorded and retried on the next run", () => {
    const g = guest();
    writeFileSync(path.join(g.root, "npm-state/offline"), "");
    const failed = runUpdater(g);
    expect(failed.status).toBe(1);
    expect(state(g).ok).toBe(false);
    expect(state(g).error).toContain("ETIMEDOUT");
    expect(npmCalls(g).some((call) => call.startsWith("install"))).toBe(false);

    rmSync(path.join(g.root, "npm-state/offline"));
    setLatest(g, { "@earendil-works/pi-coding-agent": "0.99.0" });
    expect(runUpdater(g).status).toBe(0);
    expect(state(g)).toMatchObject({ ok: true, versions: { "@earendil-works/pi-coding-agent": "0.99.0" } });
  });

  test("does nothing when the machine is image-pinned or has no setting", () => {
    for (const setting of ["image", null] as const) {
      const g = guest(setting);
      setLatest(g, { "@openai/codex": "2.0.0" });
      expect(runUpdater(g).status).toBe(0);
      expect(npmCalls(g)).toEqual([]);
      expect(existsSync(path.join(g.configDir, "agent-updates.state"))).toBe(false);
    }
  });

  test("a second updater exits while one holds the lock", async () => {
    const g = guest();
    const holder = spawn("python3", ["-c", [
      "import fcntl, sys, time",
      `lock = open(${JSON.stringify(path.join(g.configDir, ".agent-updates.lock"))}, "a")`,
      "fcntl.flock(lock, fcntl.LOCK_EX)",
      "print('locked', flush=True)",
      "time.sleep(30)",
    ].join("\n")]);
    try {
      await new Promise<void>((resolve) => holder.stdout.once("data", () => resolve()));
      const result = runUpdater(g);
      expect(result.status).toBe(0);
      expect(result.stdout).toContain("another update is running");
      expect(npmCalls(g)).toEqual([]);
    } finally {
      holder.kill();
    }
  });

  test("create and PUT accept only latest or image", async () => {
    expect(parseCreateAgentUpdates(undefined)).toEqual({ ok: true, setting: undefined });
    expect(parseCreateAgentUpdates("latest")).toEqual({ ok: true, setting: "latest" });
    expect(parseCreateAgentUpdates("image")).toEqual({ ok: true, setting: "image" });
    const bad = parseCreateAgentUpdates("nightly");
    expect(bad.ok).toBe(false);
    if (!bad.ok) {
      expect(bad.response.status).toBe(400);
      expect(await bad.response.json()).toMatchObject({ error: "invalid_agent_updates" });
    }
    expect(parseAgentUpdatesBody({ agentUpdates: "latest" })).toEqual({ ok: true, setting: "latest" });
    expect(parseAgentUpdatesBody({}).ok).toBe(false);
    expect(parseAgentUpdatesBody(["latest"]).ok).toBe(false);
  });
});
