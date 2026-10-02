import { afterEach, describe, expect, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  readlinkSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import { AGENT_PIN_ARGS, devboxAgentPins } from "../scripts/devbox-image-common";
import { runChild } from "./helpers/run-child";
import { parseAgentUpdatesBody, parseCreateAgentUpdates } from "../services/vms/agentUpdatesRoute";
import {
  GUEST_AGENTS,
  GUEST_AGENT_UPDATES_LOG,
  GUEST_AGENT_UPDATER_DEFAULTS,
  guestAgentInstallCommand,
  guestAgentUpdaterCommand,
  guestAgentUpdatesCommand,
  guestAgentUpdatesScript,
  type GuestAgentUpdaterOptions,
} from "../services/vms/guestAgentUpdates";
import { GUEST_AGENT_UPDATE_DOMAINS, type GuestAgent } from "../services/vms/images/agents";
import { CMUX_REQUIRED_DOMAINS } from "../services/vms/networkPolicy";

// A fake GitHub: the releases API (latest + list) and the release-asset
// downloads, both read from files in `dir` on every request so a test can
// publish, pull or break releases between runs. Every request is logged.
const FAKE_GITHUB = String.raw`
import json, os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
d = sys.argv[1]
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def send(self, status, body, kind="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        with open(os.path.join(d, "calls.log"), "a") as log:
            log.write(self.path + "\n")
        if os.path.exists(os.path.join(d, "offline")):
            return self.send(403, b'{"message":"API rate limit exceeded"}')
        channel = json.load(open(os.path.join(d, "channel.json")))
        path = self.path.split("?")[0]
        parts = path.strip("/").split("/")
        if parts[0] == "repos" and parts[-1] == "latest":
            repo = channel.get("/".join(parts[1:3]))
            if not repo:
                return self.send(404, b"{}")
            return self.send(200, json.dumps({"tag_name": repo["latest"]}).encode())
        if parts[0] == "repos" and parts[-1] == "releases":
            repo = channel.get("/".join(parts[1:3]))
            return self.send(200, json.dumps((repo or {}).get("releases", [])).encode())
        file = os.path.join(d, "files", path.lstrip("/"))
        if os.path.isfile(file):
            return self.send(200, open(file, "rb").read(), "application/octet-stream")
        self.send(404, b"not found", "text/plain")
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
`;

type Release = {
  tag_name: string;
  published_at: string;
  prerelease: boolean;
  draft: boolean;
  assets: { name: string; digest: string | null; browser_download_url: string }[];
};
type Channel = Record<string, { latest: string; releases: Release[] }>;

type Guest = {
  readonly root: string;
  readonly configDir: string;
  readonly github: string;
  readonly base: string;
  readonly nvmBin: string;
  readonly options: GuestAgentUpdaterOptions;
  readonly env: NodeJS.ProcessEnv;
};

const roots: string[] = [];
const servers: ChildProcess[] = [];
afterEach(() => {
  for (const server of servers.splice(0)) server.kill();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

const agent = (binary: string): GuestAgent => GUEST_AGENTS.find((candidate) => candidate.binary === binary)!;
const hoursAgo = (hours: number) => new Date(Date.now() - hours * 3600_000).toISOString();
const OLD = 24 * 10;

/** A binary that answers `--version` the way the real tools do (with a leading name). */
function fakeBinary(file: string, binary: string, version: string): void {
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, `#!/bin/sh\necho "${binary} ${version}"\n`);
  chmodSync(file, 0o755);
}

/**
 * A gzipped ustar archive of every regular file under `dir`, built in-process
 * (web tests never run synchronous child processes; see run-child.ts).
 */
function tarGz(dir: string): Buffer {
  const blocks: Buffer[] = [];
  const walk = (relative: string) => {
    for (const name of readdirSync(path.join(dir, relative)).sort()) {
      const entry = relative ? `${relative}/${name}` : name;
      const full = path.join(dir, entry);
      const info = statSync(full);
      if (info.isDirectory()) { walk(entry); continue; }
      const data = readFileSync(full);
      const header = Buffer.alloc(512);
      header.write(entry, 0, 100, "utf8");
      header.write((info.mode & 0o7777).toString(8).padStart(7, "0") + "\0", 100, 8, "ascii");
      header.write("0000000\0", 108, 8, "ascii");
      header.write("0000000\0", 116, 8, "ascii");
      header.write(data.length.toString(8).padStart(11, "0") + "\0", 124, 12, "ascii");
      header.write(Math.floor(info.mtimeMs / 1000).toString(8).padStart(11, "0") + "\0", 136, 12, "ascii");
      header.write("        ", 148, 8, "ascii");
      header.write("0", 156, 1, "ascii");
      header.write("ustar\0" + "00", 257, 8, "ascii");
      let sum = 0;
      for (const byte of header) sum += byte;
      header.write(sum.toString(8).padStart(6, "0") + "\0 ", 148, 8, "ascii");
      blocks.push(header, data, Buffer.alloc((512 - (data.length % 512)) % 512));
    }
  };
  walk("");
  blocks.push(Buffer.alloc(1024));
  return gzipSync(Buffer.concat(blocks));
}

async function startGithub(dir: string): Promise<string> {
  const server = spawn("python3", ["-c", FAKE_GITHUB, dir]);
  servers.push(server);
  const port = await new Promise<string>((resolve, reject) => {
    server.stdout!.once("data", (data: Buffer) => resolve(data.toString().trim()));
    server.once("exit", (code) => reject(new Error(`fake github exited ${code}`)));
  });
  return `http://127.0.0.1:${port}`;
}

function channel(g: Guest): Channel {
  return JSON.parse(readFileSync(path.join(g.github, "channel.json"), "utf8"));
}

/** Publish a release of one agent: build its asset, record its digest (or a wrong one), optionally make it latest. */
function publish(g: Guest, binary: string, version: string, opts: { ageHours?: number; latest?: boolean; prerelease?: boolean; digest?: string | null } = {}): string {
  const a = agent(binary);
  const tag = `${a.tagPrefix}${version}`;
  const assetPath = path.join(g.github, "files", a.repo, "releases/download", tag, a.asset);
  mkdirSync(path.dirname(assetPath), { recursive: true });
  if (a.archive === "raw") {
    fakeBinary(assetPath, binary, version);
  } else {
    const stage = mkdtempSync(path.join(g.root, "stage-"));
    fakeBinary(path.join(stage, a.member), binary, version);
    writeFileSync(path.join(stage, "README"), "sidecar\n");
    writeFileSync(assetPath, tarGz(stage));
    rmSync(stage, { recursive: true });
  }
  const sha256 = createHash("sha256").update(readFileSync(assetPath)).digest("hex");
  const all = channel(g);
  const repo = all[a.repo] ?? { latest: tag, releases: [] };
  repo.releases = repo.releases.filter((release) => release.tag_name !== tag);
  repo.releases.unshift({
    tag_name: tag,
    published_at: hoursAgo(opts.ageHours ?? OLD),
    prerelease: opts.prerelease ?? false,
    draft: false,
    assets: [{ name: a.asset, digest: opts.digest === undefined ? `sha256:${sha256}` : opts.digest, browser_download_url: `${g.base}/${a.repo}/releases/download/${tag}/${a.asset}` }],
  });
  if (opts.latest ?? !opts.prerelease) repo.latest = tag;
  all[a.repo] = repo;
  writeFileSync(path.join(g.github, "channel.json"), JSON.stringify(all));
  return sha256;
}

/** A finished standalone install, exactly as the updater lays one out. */
function standalone(g: Guest, binary: string, version: string): void {
  const a = agent(binary);
  const dir = path.join(g.options.root, binary, version);
  fakeBinary(path.join(dir, a.member), binary, version);
  writeFileSync(path.join(dir, g.options.marker), JSON.stringify({ version }));
  relink(g, binary, path.join(dir, a.member));
}

/** An older image's npm install: nvm's bin shim into node_modules, /usr/local/bin into the shim. */
function npmInstalled(g: Guest, binary: string, version: string): void {
  const a = agent(binary);
  const bin = path.join(g.root, "nvm/lib/node_modules", a.npm, "bin", binary);
  // The updater reads the version from package.json and never runs an npm install's entry point.
  fakeBinary(bin, binary, "0.0.0-do-not-run");
  writeFileSync(path.join(g.root, "nvm/lib/node_modules", a.npm, "package.json"), JSON.stringify({ name: a.npm, version }));
  const shim = path.join(g.nvmBin, binary);
  rmSync(shim, { force: true });
  symlinkSync(path.relative(g.nvmBin, bin), shim);
  relink(g, binary, binary === "opencode" ? realpathSync(shim) : shim);
}

function relink(g: Guest, binary: string, target: string): void {
  const entry = path.join(g.options.binDir, binary);
  if (binary === "opencode") {
    const real = path.join(g.options.libexecDir, "cmux-opencode-real");
    rmSync(real, { force: true });
    symlinkSync(target, real);
    rmSync(entry, { force: true });
    symlinkSync(path.join(g.configDir, "opencode"), entry);
    return;
  }
  rmSync(entry, { force: true });
  symlinkSync(target, entry);
}

/** A guest with every agent standalone at 1.0.0, and a channel whose latest is that release, published long ago. */
async function guest(setting: "latest" | "image" | null = "latest"): Promise<Guest> {
  const root = realpathSync(mkdtempSync(path.join(tmpdir(), "cmux-agent-updates-")));
  roots.push(root);
  const github = path.join(root, "github");
  const configDir = path.join(root, "etc/cmux");
  const nvmBin = path.join(root, "nvm/bin");
  const binDir = path.join(root, "usr/local/bin");
  const libexecDir = path.join(root, "usr/local/libexec");
  for (const dir of [github, configDir, nvmBin, binDir, libexecDir, path.join(root, "proc")]) mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(github, "channel.json"), "{}");
  writeFileSync(path.join(nvmBin, "node"), "#!/bin/sh\n");
  chmodSync(path.join(nvmBin, "node"), 0o755);
  symlinkSync(path.join(nvmBin, "node"), path.join(binDir, "node"));
  writeFileSync(path.join(configDir, "opencode"), "#!/bin/bash\n");
  chmodSync(path.join(configDir, "opencode"), 0o755);
  if (setting) writeFileSync(path.join(configDir, "agent-updates"), `${setting}\n`);
  const base = await startGithub(github);
  const g: Guest = {
    root,
    configDir,
    github,
    base,
    nvmBin,
    options: {
      ...GUEST_AGENT_UPDATER_DEFAULTS,
      root: path.join(root, "opt/cmux-agents"),
      node: path.join(binDir, "node"),
      binDir,
      libexecDir,
      procRoot: path.join(root, "proc"),
      apiBase: base,
      downloadBase: base,
    },
    env: { ...process.env, HOME: root },
  };
  for (const { binary } of GUEST_AGENTS) {
    standalone(g, binary, "1.0.0");
    publish(g, binary, "1.0.0");
  }
  return g;
}

function runUpdater(g: Guest) {
  return runChild("sh", ["-c", guestAgentUpdaterCommand(g.configDir, g.options)], { env: g.env });
}

function calls(g: Guest): string[] {
  const log = path.join(g.github, "calls.log");
  return existsSync(log) ? readFileSync(log, "utf8").trim().split("\n").filter(Boolean) : [];
}

const downloads = (g: Guest) => calls(g).filter((call) => call.includes("/releases/download/"));

function state(g: Guest): { checkedAt: string; ok: boolean; versions: Record<string, string | null>; sources: Record<string, string>; error?: string } {
  return JSON.parse(readFileSync(path.join(g.configDir, "agent-updates.state"), "utf8"));
}

/** What `binary` on PATH runs now: its --version output, through the real links. */
async function runs(g: Guest, binary: string): Promise<string> {
  const entry = binary === "opencode" ? path.join(g.options.libexecDir, "cmux-opencode-real") : path.join(g.options.binDir, binary);
  return (await runChild(entry, ["--version"])).stdout.trim();
}

describe("guest agent updates", () => {
  test("the updated agents are exactly the ones the devbox bakes, from hosts every network mode allows", () => {
    expect(GUEST_AGENTS.map(({ npm, binary }) => ({ pkg: npm, binary })))
      .toEqual(AGENT_PIN_ARGS.map(({ pkg, binary }) => ({ pkg, binary })));
    expect(GUEST_AGENTS.map(({ npm }) => npm)).toEqual(devboxAgentPins().map((pin) => pin.pkg));
    for (const domain of GUEST_AGENT_UPDATE_DOMAINS) expect(CMUX_REQUIRED_DOMAINS).toContain(domain);
    // No npm anywhere in what the guest runs.
    for (const mode of ["update", "install"] as const) {
      const command = mode === "install"
        ? guestAgentInstallCommand(Object.fromEntries(GUEST_AGENTS.map((a) => [a.binary, { version: "1.0.0", sha256: "0".repeat(64) }])))
        : guestAgentUpdaterCommand();
      expect(command).not.toMatch(/\bnpm (install|view|ls)\b/);
      expect(command).not.toContain("registry.npmjs.org");
    }
  });

  test("image only records the setting; latest also starts a detached updater", async () => {
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
      expect((await runChild("sh", ["-n", "-c", command])).status).toBe(0);
    }
  });

  test("the script records the setting atomically and starts the updater detached", async () => {
    const g = await guest(null);
    publish(g, "codex", "2.0.0");
    const log = path.join(g.root, "updates.log");
    const paths = { configDir: g.configDir, log, updater: g.options };
    // setsid is util-linux; stand in for it where the test host has none (macOS).
    const shims = path.join(g.root, "shims");
    mkdirSync(shims);
    writeFileSync(path.join(shims, "setsid"), "#!/bin/sh\nexec \"$@\"\n");
    chmodSync(path.join(shims, "setsid"), 0o755);
    const env = { ...g.env, PATH: `${g.env.PATH}:${shims}` };
    const recorded = await runChild("sh", ["-c", guestAgentUpdatesScript("image", paths)], { env });
    expect(recorded.status).toBe(0);
    expect(readFileSync(path.join(g.configDir, "agent-updates"), "utf8")).toBe("image\n");
    expect(calls(g)).toEqual([]);

    const launched = await runChild("sh", ["-c", guestAgentUpdatesScript("latest", paths)], { env });
    expect(launched.status).toBe(0);
    expect(readFileSync(path.join(g.configDir, "agent-updates"), "utf8")).toBe("latest\n");
    const statePath = path.join(g.configDir, "agent-updates.state");
    for (let i = 0; i < 200 && !existsSync(statePath); i += 1) await new Promise((resolve) => setTimeout(resolve, 50));
    expect(state(g)).toMatchObject({ ok: true, versions: { codex: "2.0.0" } });
    expect(readFileSync(log, "utf8")).toContain("installing codex 2.0.0");
  });

  test("installs only the agents behind the channel, verified, and keeps the bake's links", async () => {
    return (async () => {
      const g = await guest();
      publish(g, "claude", "2.0.0");
      publish(g, "opencode", "1.2.0");
      publish(g, "pi", "1.1.0");
      const result = await runUpdater(g);
      expect(result.status).toBe(0);
      expect(downloads(g).map((call) => call.split("/").slice(-2).join("/")).sort()).toEqual([
        "v1.1.0/pi-linux-x64.tar.gz",
        "v1.2.0/opencode-linux-x64.tar.gz",
        "v2.0.0/claude-linux-x64.tar.gz",
      ]);
      expect(state(g)).toMatchObject({ ok: true, versions: { claude: "2.0.0", opencode: "1.2.0", pi: "1.1.0", codex: "1.0.0", "agent-browser": "1.0.0" } });
      expect(await runs(g, "claude")).toBe("claude 2.0.0");
      expect(await runs(g, "pi")).toBe("pi 1.1.0");
      // The whole asset unpacked beside the binary (pi reads its assets from there).
      expect(existsSync(path.join(g.options.root, "pi/1.1.0/pi/pi"))).toBe(true);
      expect(existsSync(path.join(g.options.root, "pi/1.1.0/README"))).toBe(true);
      for (const { binary, member } of GUEST_AGENTS) {
        const entry = readlinkSync(path.join(g.options.binDir, binary));
        const version = state(g).versions[binary];
        expect(entry).toBe(binary === "opencode" ? path.join(g.configDir, "opencode") : path.join(g.options.root, binary, version!, member));
      }
      expect(readlinkSync(path.join(g.options.libexecDir, "cmux-opencode-real"))).toBe(path.join(g.options.root, "opencode/1.2.0/opencode"));
      // The previous version stays for anything still running it.
      expect(existsSync(path.join(g.options.root, "claude/1.0.0/claude"))).toBe(true);
    })();
  });

  test("a release younger than the minimum age waits; the newest old-enough one installs", async () => {
    const g = await guest();
    publish(g, "codex", "1.1.0", { ageHours: 24 * 10 });
    publish(g, "codex", "1.2.0", { ageHours: 24 * 4 });
    publish(g, "codex", "1.2.1-beta.1", { ageHours: 24 * 4, prerelease: true });
    publish(g, "codex", "1.3.0", { ageHours: 1 });
    publish(g, "opencode", "1.1.0", { ageHours: 2 });
    expect((await runUpdater(g)).status).toBe(0);
    expect(state(g).versions.codex).toBe("1.2.0");
    expect(state(g).versions.opencode).toBe("1.0.0");
    expect(downloads(g)).toEqual([`/openai/codex/releases/download/rust-v1.2.0/${agent("codex").asset}`]);
  });

  test("nothing above the channel's latest release installs, and nothing without a digest", async () => {
    const g = await guest();
    publish(g, "agent-browser", "1.1.0");
    publish(g, "agent-browser", "1.5.0", { latest: false });
    publish(g, "claude", "1.4.0", { digest: null });
    expect((await runUpdater(g)).status).toBe(0);
    expect(state(g).versions["agent-browser"]).toBe("1.1.0");
    expect(state(g).versions.claude).toBe("1.0.0");
  });

  test("never downgrades a newer installed release", async () => {
    const g = await guest();
    standalone(g, "codex", "5.0.0");
    publish(g, "codex", "4.0.0");
    publish(g, "codex", "5.0.0", { ageHours: 1 });
    expect((await runUpdater(g)).status).toBe(0);
    expect(state(g).versions.codex).toBe("5.0.0");
    expect(downloads(g)).toEqual([]);
    expect(await runs(g, "codex")).toBe("codex 5.0.0");
  });

  test("a digest mismatch installs nothing, keeps the running version, and is retried", async () => {
    const g = await guest();
    publish(g, "claude", "2.0.0", { digest: `sha256:${"f".repeat(64)}` });
    publish(g, "codex", "2.0.0");
    const failed = await runUpdater(g);
    expect(failed.status).toBe(1);
    expect(state(g).ok).toBe(false);
    expect(state(g).error).toContain("claude 2.0.0: sha256");
    // The failure is per agent: codex still updated.
    expect(state(g).versions).toMatchObject({ claude: "1.0.0", codex: "2.0.0" });
    expect(await runs(g, "claude")).toBe("claude 1.0.0");
    expect(readdirSync(path.join(g.options.root, "claude"))).toEqual(["1.0.0"]);

    // The release is fixed upstream; the next run (no throttle after a failure) installs it.
    publish(g, "claude", "2.0.0");
    expect((await runUpdater(g)).status).toBe(0);
    expect(state(g)).toMatchObject({ ok: true, versions: { claude: "2.0.0" } });
  });

  test("a successful check suppresses the next one for a day", async () => {
    const g = await guest();
    expect((await runUpdater(g)).status).toBe(0);
    const before = calls(g).length;
    publish(g, "codex", "9.9.9");
    expect((await runUpdater(g)).status).toBe(0);
    expect(calls(g).length).toBe(before);

    // An old check no longer throttles.
    writeFileSync(path.join(g.configDir, "agent-updates.state"), JSON.stringify({ ...state(g), checkedAt: "2020-01-01T00:00:00Z" }));
    expect((await runUpdater(g)).status).toBe(0);
    expect(state(g).versions.codex).toBe("9.9.9");
  });

  test("a failed check is recorded and retried on the next run", async () => {
    const g = await guest();
    writeFileSync(path.join(g.github, "offline"), "");
    const failed = await runUpdater(g);
    expect(failed.status).toBe(1);
    expect(state(g).ok).toBe(false);
    expect(state(g).error).toContain("HTTP 403");
    // Nothing moved, and every link still runs.
    for (const { binary } of GUEST_AGENTS) expect(await runs(g, binary)).toBe(`${binary} 1.0.0`);

    rmSync(path.join(g.github, "offline"));
    publish(g, "pi", "1.5.0");
    expect((await runUpdater(g)).status).toBe(0);
    expect(state(g)).toMatchObject({ ok: true, versions: { pi: "1.5.0" } });
  });

  test("an npm install migrates to the standalone release once, and its package goes only when unused", async () => {
    const g = await guest();
    for (const binary of ["claude", "codex", "opencode"]) npmInstalled(g, binary, "1.0.0");
    // Something still runs codex from its npm package: node names nvm's bin
    // link on its command line (as seen live), a link the migration removes.
    const codexPackage = path.join(g.root, "nvm/lib/node_modules/@openai/codex");
    mkdirSync(path.join(g.options.procRoot, "4242"));
    writeFileSync(path.join(g.options.procRoot, "4242/cmdline"), `node\0${path.join(g.nvmBin, "codex")}\0-c\0x\0`);
    // pi rewrites its command line to "pi"; only the shell's "_" names its nvm link.
    mkdirSync(path.join(g.options.procRoot, "4343"));
    writeFileSync(path.join(g.options.procRoot, "4343/cmdline"), "pi\0");
    writeFileSync(path.join(g.options.procRoot, "4343/environ"), `HOME=/home/cmux\0_=${path.join(g.nvmBin, "pi")}\0`);
    npmInstalled(g, "pi", "1.0.0");
    // Our own finished installs of these do not exist yet.
    for (const binary of ["claude", "codex", "opencode", "pi"]) rmSync(path.join(g.options.root, binary), { recursive: true });
    publish(g, "claude", "1.1.0");

    expect((await runUpdater(g)).status).toBe(0);
    expect(state(g).sources).toMatchObject({ claude: "standalone", codex: "standalone", opencode: "standalone" });
    // Same-version migration for codex and opencode, an update for claude.
    expect(state(g).versions).toMatchObject({ claude: "1.1.0", codex: "1.0.0", opencode: "1.0.0" });
    expect(realpathSync(path.join(g.options.binDir, "codex"))).toBe(path.join(g.options.root, "codex/1.0.0/bin/codex"));
    expect(readlinkSync(path.join(g.options.binDir, "opencode"))).toBe(path.join(g.configDir, "opencode"));
    expect(readlinkSync(path.join(g.options.libexecDir, "cmux-opencode-real"))).toBe(path.join(g.options.root, "opencode/1.0.0/opencode"));
    // nvm's entry points are gone, so login shells (nvm first on PATH) reach the standalone copies.
    for (const binary of ["claude", "codex", "opencode"]) expect(existsSync(path.join(g.nvmBin, binary))).toBe(false);
    // Unused packages are deleted; the one a process runs from stays until it exits.
    expect(existsSync(path.join(g.root, "nvm/lib/node_modules/@anthropic-ai/claude-code"))).toBe(false);
    expect(existsSync(path.join(g.root, "nvm/lib/node_modules/opencode-ai"))).toBe(false);
    expect(existsSync(codexPackage)).toBe(true);
    expect(existsSync(path.join(g.root, "nvm/lib/node_modules/@earendil-works/pi-coding-agent"))).toBe(true);

    rmSync(path.join(g.options.procRoot, "4242"), { recursive: true });
    rmSync(path.join(g.options.procRoot, "4343"), { recursive: true });
    writeFileSync(path.join(g.configDir, "agent-updates.state"), JSON.stringify({ ...state(g), checkedAt: "2020-01-01T00:00:00Z" }));
    expect((await runUpdater(g)).status).toBe(0);
    expect(existsSync(codexPackage)).toBe(false);
    expect(existsSync(path.join(g.root, "nvm/lib/node_modules/@earendil-works/pi-coding-agent"))).toBe(false);
  });

  test("an npm install newer than every eligible release stays until one catches up", async () => {
    const g = await guest();
    rmSync(path.join(g.options.root, "pi"), { recursive: true });
    npmInstalled(g, "pi", "3.0.0");
    publish(g, "pi", "3.0.0", { ageHours: 1 });
    expect((await runUpdater(g)).status).toBe(0);
    expect(state(g)).toMatchObject({ ok: true, versions: { pi: "3.0.0" }, sources: { pi: "npm" } });
    expect(downloads(g)).toEqual([]);
    expect(existsSync(path.join(g.nvmBin, "pi"))).toBe(true);
  });

  test("a lost link is repaired from the installed version without a download", async () => {
    const g = await guest();
    rmSync(path.join(g.options.binDir, "agent-browser"));
    rmSync(path.join(g.options.binDir, "codex"));
    symlinkSync(path.join(g.root, "nowhere"), path.join(g.options.binDir, "codex"));
    expect((await runUpdater(g)).status).toBe(0);
    expect(await runs(g, "agent-browser")).toBe("agent-browser 1.0.0");
    expect(await runs(g, "codex")).toBe("codex 1.0.0");
    expect(downloads(g)).toEqual([]);
  });

  test("old versions are pruned down to the previous one, unless in use", async () => {
    const g = await guest();
    standalone(g, "claude", "1.1.0");
    standalone(g, "claude", "1.2.0");
    publish(g, "claude", "1.3.0");
    mkdirSync(path.join(g.options.procRoot, "77"));
    symlinkSync(path.join(g.options.root, "claude/1.1.0/claude"), path.join(g.options.procRoot, "77/exe"));
    expect((await runUpdater(g)).status).toBe(0);
    expect(readdirSync(path.join(g.options.root, "claude")).sort()).toEqual(["1.1.0", "1.2.0", "1.3.0"]);
    expect(lstatSync(path.join(g.options.root, "claude/1.0.0"), { throwIfNoEntry: false })).toBeUndefined();
  });

  test("does nothing when the machine is image-pinned or has no setting", async () => {
    for (const setting of ["image", null] as const) {
      const g = await guest(setting);
      publish(g, "codex", "2.0.0");
      expect((await runUpdater(g)).status).toBe(0);
      expect(calls(g)).toEqual([]);
      expect(existsSync(path.join(g.configDir, "agent-updates.state"))).toBe(false);
    }
  });

  test("a second updater exits while one holds the lock", async () => {
    const g = await guest();
    const holder = spawn("python3", ["-c", [
      "import fcntl, sys, time",
      `lock = open(${JSON.stringify(path.join(g.configDir, ".agent-updates.lock"))}, "a")`,
      "fcntl.flock(lock, fcntl.LOCK_EX)",
      "print('locked', flush=True)",
      "time.sleep(30)",
    ].join("\n")]);
    try {
      await new Promise<void>((resolve) => holder.stdout.once("data", () => resolve()));
      const result = await runUpdater(g);
      expect(result.status).toBe(0);
      expect(result.stdout).toContain("another update is running");
      expect(calls(g)).toEqual([]);
    } finally {
      holder.kill();
    }
  });

  test("install mode lays down exactly the pins, checks their digests, and reads no release metadata", async () => {
    const g = await guest();
    rmSync(g.options.root, { recursive: true });
    for (const binary of ["claude", "codex", "opencode", "pi", "agent-browser"]) npmInstalled(g, binary, "0.9.0");
    const pins = Object.fromEntries(GUEST_AGENTS.map(({ binary }) => [binary, { version: "1.1.0", sha256: publish(g, binary, "1.1.0", { ageHours: 0 }) }]));
    // The bake runs before the opencode wrapper exists: opencode links directly.
    rmSync(path.join(g.configDir, "opencode"));
    rmSync(path.join(g.options.binDir, "opencode"));
    const bad = await runChild("sh", ["-c", guestAgentInstallCommand({ ...pins, codex: { version: "1.1.0", sha256: "0".repeat(64) } }, g.configDir, g.options)], { env: g.env });
    expect(bad.status).toBe(1);
    expect(bad.stdout).toContain("codex 1.1.0: sha256");

    const good = await runChild("sh", ["-c", guestAgentInstallCommand(pins, g.configDir, g.options)], { env: g.env });
    expect(good.status).toBe(0);
    for (const { binary, member } of GUEST_AGENTS) {
      expect(readlinkSync(path.join(g.options.binDir, binary))).toBe(path.join(g.options.root, binary, "1.1.0", member));
      expect(existsSync(path.join(g.nvmBin, binary))).toBe(false);
    }
    expect(calls(g).filter((call) => call.startsWith("/repos/"))).toEqual([]);
    expect(existsSync(path.join(g.configDir, "agent-updates.state"))).toBe(false);
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
