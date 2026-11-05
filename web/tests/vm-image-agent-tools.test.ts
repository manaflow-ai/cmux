import { describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { agentStepPlan, parseRecordedLaunch, probeOptionsFromArgv, rdActivateCommand, rdConnectCommand, rdOtherUserCommand, rdReadCommand, rdStaticCheckCommand, recorderScript, staticCheckCommand, toolListProblems } from "../scripts/cmux-vm-image/agent-tools-probe";
import { readFileSync as readSource } from "node:fs";
import {
  A11Y_SCRIPT,
  A11Y_TEMPLATE_UNIT,
  a11yRuntimeDir,
  a11yScript,
  a11yTemplateUnit,
  AGENT_TOOLS_BIN,
  AGENT_XAUTHORITY,
  agentXauthority,
  DISPLAY_TEMPLATE_UNIT,
  displayTemplateUnit,
  ROOT_PROPERTY_SCRIPT,
  rootPropertyScript,
  agentToolsDaemonEnv,
  CUA_REFUSE_DIR,
  cuaRefuseScript,
  agentToolsFiles,
  agentToolsLinkCommand,
  agentToolsProfileScript,
  browserRoleBakePhases,
  CUA_UNIT,
  cuaUnit,
  cuaWrapperScript,
  daemonEnvLines,
  DISPLAY_UNIT,
  A11Y_UNIT,
  RD_HOST_DIR,
  RD_OPENH264_UNIT,
  RD_PEER_UID,
  RD_RUN_DIR,
  RD_SOCKET,
  RD_SOCKET_UNIT,
  RD_TMPFILES,
  RD_UNIT,
  RD_USER,
  RD_XAUTHORITY,
  rdCookieCopy,
  rdHostPath,
  rdOpenh264Unit,
  rdSetupCommand,
  rdSocketUnit,
  rdTmpfiles,
  rdUnit,
} from "../scripts/cmux-vm-image/agent-tools";
import { bakeOptionsFromArgv, daemonUnit, desktopRecord } from "../scripts/cmux-vm-image/bake";
import { CURRENT_BIN, type InputsLock, type LockedProgram, readInputsLock, rolesManifest, storeEntry } from "../scripts/cmux-vm-image/lock";
import { DEVBOX_WORK_UID } from "../services/vms/images/workUser";
import { runChild } from "./helpers/run-child";

const lock = readInputsLock();
/**
 * The lock with a cmux-rd entry: the pinned one once it exists, until then a stand-in written out
 * from the release archive's real layout (scripts/release.py: bin/cmux-rd, LICENSE and
 * THIRD_PARTY_LICENSES.md at the root), not from lock.ts's own shape.
 */
const RD_STAND_IN: LockedProgram = {
  name: "cmux-rd",
  version: "0.1.0",
  url: "https://github.com/manaflow-ai/cmux/releases/download/cmux-rd-v0.1.0/cmux-rd-0.1.0-x86_64-unknown-linux-gnu.tar.gz",
  sha256: "ab".repeat(32),
  size: 1,
  format: "tar.gz",
  bin: { "cmux-rd": "bin/cmux-rd" },
  versionArgs: [],
  roles: ["desktop"],
};
const rdLock: InputsLock = lock.programs.some((p) => p.name === "cmux-rd") ? lock : { ...lock, programs: [...lock.programs, RD_STAND_IN] };
const withoutRd: InputsLock = { ...lock, programs: lock.programs.filter((p) => p.name !== "cmux-rd") };

async function bashSyntax(script: string): Promise<void> {
  const result = await runChild("bash", ["-n"], { input: script, timeout: 20_000 });
  expect(result.stderr).toBe("");
  expect(result.status).toBe(0);
}

/** Runs the cmux-cua wrapper with a recording `sudo` first on PATH and a recording real binary. */
async function runWrapper(args: string[], sudoStatus = 0): Promise<{ status: number | null; calls: string[]; stderr: string }> {
  const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-agent-tools-"));
  try {
    const log = path.join(dir, "calls.log");
    writeFileSync(path.join(dir, "sudo"), `#!/bin/sh\necho "sudo $*" >> ${log}\nexit ${sudoStatus}\n`);
    writeFileSync(path.join(dir, "real-cua"), `#!/bin/sh\necho "cua $*" >> ${log}\n`);
    chmodSync(path.join(dir, "sudo"), 0o755);
    chmodSync(path.join(dir, "real-cua"), 0o755);
    writeFileSync(path.join(dir, "wrapper"), cuaWrapperScript(path.join(dir, "real-cua")));
    chmodSync(path.join(dir, "wrapper"), 0o755);
    const result = await runChild(path.join(dir, "wrapper"), args, { timeout: 20_000, env: { ...process.env, PATH: `${dir}:${process.env.PATH ?? ""}` } });
    let calls: string[] = [];
    try {
      calls = readFileSync(log, "utf8").trim().split("\n");
    } catch {
      calls = [];
    }
    return { status: result.status, calls, stderr: result.stderr };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe("cmux VM agent tools (bead cx-h8n)", () => {
  test("the cmux-cua wrapper starts the machine's computer-use driver before `mcp`, then execs the real binary with every argument", async () => {
    const mcp = await runWrapper(["mcp", "--claude-code-computer-use-compat"]);
    expect(mcp.status).toBe(0);
    expect(mcp.calls).toEqual([`sudo -n systemctl start ${CUA_UNIT}`, "cua mcp --claude-code-computer-use-compat"]);
  });

  test("other cmux-cua verbs never start the driver", async () => {
    const version = await runWrapper(["--version"]);
    expect(version.calls).toEqual(["cua --version"]);
  });

  test("a driver that does not start still runs the proxy, which then reports the missing daemon itself", async () => {
    const failed = await runWrapper(["mcp"], 1);
    expect(failed.calls).toEqual([`sudo -n systemctl start ${CUA_UNIT}`, "cua mcp"]);
    expect(failed.stderr).toContain(CUA_UNIT);
  });

  test("the default bake's daemon unit is unchanged; --agent-tools adds the tool dir and the browser host the daemon supervises", () => {
    const plain = daemonUnit();
    expect(plain).not.toContain("CMUX_AGENT_TOOLS_BIN_DIR");
    expect(plain).not.toContain("CMUX_BROWSER_HOST_BIN");
    expect(plain).not.toContain("CMUX_BROWSER_HOST_CHROMIUM");
    const env = agentToolsDaemonEnv(lock);
    const browser = rolesManifest(lock).roles.browser;
    const host = browser.programs.find((p) => p.name === "cmux-browser-host")!;
    expect(env).toEqual({
      CMUX_AGENT_TOOLS_BIN_DIR: AGENT_TOOLS_BIN,
      CMUX_BROWSER_HOST_BIN: `${host.storeEntry}/${host.bin["cmux-browser-host"]}`,
      CMUX_BROWSER_HOST_BACKGROUND_FULL_RATE: "0",
      CMUX_BROWSER_HOST_CHROMIUM: browser.env.CMUX_BROWSER_HOST_CHROMIUM,
    });
    const unit = daemonUnit(env);
    for (const line of daemonEnvLines(env)) expect(unit).toContain(`${line}\n`);
    expect(unit.indexOf("CMUX_AGENT_TOOLS_BIN_DIR")).toBeLessThan(unit.indexOf("ExecStart="));
    expect(() => daemonEnvLines({ A: "has space" })).toThrow();
  });

  test("--agent-tools is a dev-only bake option", () => {
    expect(bakeOptionsFromArgv(["bun", "bake.ts", "--tag", "t"]).agentTools).toBe(false);
    expect(bakeOptionsFromArgv(["bun", "bake.ts", "--tag", "t", "--agent-tools"]).agentTools).toBe(true);
    expect(() => bakeOptionsFromArgv(["bun", "bake.ts", "--tag", "t", "--agent-tools", "--promotion"])).toThrow(/dev snapshots only/);
  });

  test("the tool dir names cmux as the store's cmux-tui and every install command parses", async () => {
    const link = agentToolsLinkCommand();
    expect(link).toContain(`ln -sfn ${CURRENT_BIN}/cmux-tui ${AGENT_TOOLS_BIN}/cmux`);
    expect(link).toContain(`systemctl is-active --quiet ${DISPLAY_UNIT}`);
    await bashSyntax(link);
    await bashSyntax(agentToolsProfileScript());
    for (const file of agentToolsFiles(rdLock).filter((f) => f.path.endsWith("cmux-cua"))) await bashSyntax(file.text);
    const phases = browserRoleBakePhases(lock);
    expect(phases.map((p) => p.name)).toEqual(["agent-tools-browser-apt-update", "agent-tools-browser-apt-install", "agent-tools-browser-program-chrome-for-testing", "agent-tools-browser-program-cmux-browser-host", "agent-tools-browser-lists"]);
    for (const phase of phases) await bashSyntax(phase.command);
    await bashSyntax(staticCheckCommand());
  });

  test("the shared agent display is display :99 of the per-display template, and the driver runs on it with its AT-SPI bus as the work user", () => {
    // One Xvfb unit for :99: the template instance, so the AT-SPI bus unit (BindsTo) can follow it.
    expect(DISPLAY_UNIT).toBe("cmux-agent-display@99.service");
    expect(A11Y_UNIT).toBe("cmux-agent-a11y@99.service");
    expect(AGENT_XAUTHORITY).toBe(agentXauthority("99"));
    const paths = agentToolsFiles(rdLock).map((f) => f.path);
    expect(paths).not.toContain("/etc/systemd/system/cmux-agent-display.service");
    const cua = cuaUnit();
    expect(cua).toContain(`Requires=${DISPLAY_UNIT}`);
    // The tree needs the bus, input and screenshots do not: a failed bus never stops the driver.
    expect(cua).toContain(`Wants=${A11Y_UNIT}`);
    expect(cua).not.toContain(`Requires=${A11Y_UNIT}`);
    expect(cua).toContain(`After=${DISPLAY_UNIT} ${A11Y_UNIT}`);
    expect(cua).toContain("Environment=DISPLAY=:99");
    expect(cua).toContain(`Environment=XAUTHORITY=${agentXauthority("99")}`);
    // Without a session bus cmux-cua reports "AT-SPI trees will be empty" and apps it launches expose no tree.
    expect(cua).toContain(`Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=${a11yRuntimeDir("99")}/bus`);
    expect(cua).toContain(`Environment=XDG_RUNTIME_DIR=${a11yRuntimeDir("99")}`);
    expect(cua).toContain(`ExecStart=${CURRENT_BIN}/cmux-cua serve`);
    expect(cua).toContain("User=cmux");
    expect(cua).not.toContain("[Install]");
  });

  test("probe: the tool list must name the cua tools, the browser REPL tools and the browser skill", () => {
    const full = "mcp__cmux-cua__get_desktop_state\nmcp__cmux-cua__click\nmcp__cmux__browser_repl_eval\nmcp__cmux__browser_repl_open\n- cmux:cmux-browser";
    expect(toolListProblems(full)).toEqual([]);
    expect(toolListProblems("I have no MCP servers connected.")).toHaveLength(5);
    expect(toolListProblems(full.replace("mcp__cmux__browser_repl_eval", ""))).toEqual(["the agent does not list mcp__cmux__browser_repl_eval"]);
  });

  test("probe: no personal credential can reach a VM; the flag is gone and any token-file flag is refused", () => {
    const source = readSource(new URL("../scripts/cmux-vm-image/agent-tools-probe.ts", import.meta.url), "utf8");
    for (const word of ["claude-token-file", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_OAUTH_TOKEN", "anthropic-oauth"]) expect(source).not.toContain(word);
    const base = ["bun", "probe.ts", "--snapshot", "sh-1", "--tag", "t"];
    const parsed = probeOptionsFromArgv(base);
    expect({ ...parsed, outDir: typeof parsed.outDir }).toEqual({ snapshotId: "sh-1", tag: "t", vmId: undefined, modelRoute: "none", outDir: "string" });
    for (const flag of ["--claude-token-file", "--token-file", "--credentials", "--anthropic-key-file"]) expect(() => probeOptionsFromArgv([...base, flag, "/x"])).toThrow();
  });

  test("probe: without a model route the agent step is UNVERIFIED, never a credential copy; the edge route runs only on a backend machine", () => {
    expect(agentStepPlan({ modelRoute: "none", vmId: undefined })).toEqual({ run: false, status: "UNVERIFIED", reason: expect.stringContaining("no model route") });
    expect(() => probeOptionsFromArgv(["bun", "probe.ts", "--snapshot", "sh-1", "--tag", "t", "--model-route", "edge"])).toThrow(/--vm/);
    const edge = probeOptionsFromArgv(["bun", "probe.ts", "--vm", "vm-1", "--tag", "t", "--model-route", "edge"]);
    expect(agentStepPlan(edge)).toEqual({ run: true, status: "RUN", reason: expect.stringContaining("edge") });
  });

  test("probe: the recorder stands in for claude and captures exactly the launch acpmux makes", async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-agent-tools-rec-"));
    try {
      const out = path.join(dir, "launches.txt");
      writeFileSync(path.join(dir, "claude"), recorderScript(out));
      chmodSync(path.join(dir, "claude"), 0o755);
      const config = JSON.stringify({ mcpServers: { "cmux-cua": { type: "stdio", command: `${AGENT_TOOLS_BIN}/cmux-cua`, args: ["mcp"], env: { CMUX_CUA_MCP_FORCE_PROXY: "1" } }, cmux: { type: "stdio", command: `${AGENT_TOOLS_BIN}/cmux`, args: ["mcp", "serve"], env: {} } } });
      await runChild(path.join(dir, "claude"), ["--version"], { timeout: 20_000 });
      const r = await runChild(path.join(dir, "claude"), ["--print", "--mcp-config", config, "--plugin-dir", "/p/x"], { timeout: 20_000 });
      expect(r.status).not.toBe(0);
      const launch = parseRecordedLaunch(readFileSync(out, "utf8"));
      expect(launch.servers.map((s) => [s.name, s.command, s.args])).toEqual([
        ["cmux-cua", `${AGENT_TOOLS_BIN}/cmux-cua`, ["mcp"]],
        ["cmux", `${AGENT_TOOLS_BIN}/cmux`, ["mcp", "serve"]],
      ]);
      expect(launch.servers[0].env).toEqual({ CMUX_CUA_MCP_FORCE_PROXY: "1" });
      expect(launch.pluginDir).toBe("/p/x");
      expect(parseRecordedLaunch("--version\n").servers).toEqual([]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("cua-video stays off: the computer-use driver cannot install ffmpeg (install_ffmpeg runs `sudo -n apt-get install -y ffmpeg`)", async () => {
    const cua = cuaUnit();
    expect(cua).toContain("NoNewPrivileges=yes");
    expect(cua).toMatch(new RegExp(`Environment=PATH=${CUA_REFUSE_DIR}:`));
    const files = agentToolsFiles(rdLock).filter((f) => f.path.startsWith(`${CUA_REFUSE_DIR}/`));
    expect(files.map((f) => path.basename(f.path)).sort()).toEqual(["apt", "apt-get", "sudo"]);
    const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-cua-refuse-"));
    try {
      for (const name of ["sudo", "apt-get"]) {
        writeFileSync(path.join(dir, name), cuaRefuseScript(name));
        chmodSync(path.join(dir, name), 0o755);
      }
      const env = { ...process.env, PATH: `${dir}:${process.env.PATH ?? ""}` };
      const found = await runChild("sh", ["-c", "command -v apt-get"], { env, timeout: 20_000 });
      expect(found.stdout.trim()).toBe(path.join(dir, "apt-get"));
      for (const argv of [["sudo", "-n", "apt-get", "install", "-y", "ffmpeg"], ["apt-get", "install", "-y", "ffmpeg"]]) {
        const r = await runChild(argv[0], argv.slice(1), { env, timeout: 20_000 });
        expect(r.status).not.toBe(0);
        expect(r.stderr).toContain("cua-video");
        expect(r.stderr).toContain("ffmpeg");
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("per-display units (cx-ncc.5): Xvfb on :%i with its own cookie and -noreset, the a11y bus needs its display, both ship off", () => {
    const display = displayTemplateUnit();
    expect(display).toContain(`ExecStart=/usr/bin/Xvfb :%i -screen 0 1280x800x24 -nolisten tcp -auth ${agentXauthority("%i")} -s 0 -dpms -noreset\n`);
    expect(display).toContain(`xauth -q -f ${agentXauthority("%i")} add :%i . "$(mcookie)"`);
    expect(display).toContain("[ -S /tmp/.X11-unix/X%i ]");
    expect(display).toContain("User=cmux");
    expect(display).not.toContain(":99");
    expect(display).toContain("-nolisten tcp");
    const a11y = a11yTemplateUnit();
    expect(a11y).toContain("BindsTo=cmux-agent-display@%i.service");
    expect(a11y).not.toContain("Requires=");
    expect(a11y).toContain("After=cmux-agent-display@%i.service");
    expect(a11y).toContain("Environment=DISPLAY=:%i");
    expect(a11y).toContain(`Environment=XAUTHORITY=${agentXauthority("%i")}`);
    expect(a11y).toContain(`Environment=XDG_RUNTIME_DIR=${a11yRuntimeDir("%i")}`);
    expect(a11y).toContain("RuntimeDirectoryMode=0700");
    expect(a11y).toContain("NoNewPrivileges=yes");
    expect(a11y).toContain(`ExecStart=${A11Y_SCRIPT}\n`);
    expect(a11y).toContain(`${a11yRuntimeDir("%i")}/at-spi-bus`);
    expect(a11y).toContain("User=cmux");
    for (const unit of [display, a11y]) expect(unit).not.toContain("[Install]");
    const files = new Map(agentToolsFiles(rdLock).map((f) => [f.path, f]));
    expect(files.get(`/etc/systemd/system/${DISPLAY_TEMPLATE_UNIT}`)?.text).toBe(display);
    expect(files.get(`/etc/systemd/system/${A11Y_TEMPLATE_UNIT}`)?.text).toBe(a11y);
    expect(files.get(A11Y_SCRIPT)?.mode).toBe(0o755);
    expect(staticCheckCommand()).toContain(A11Y_TEMPLATE_UNIT);
  });

  test("the a11y script starts a session bus and the launcher, waits for org.a11y.Bus, publishes AT_SPI_BUS and exits 1 when a child exits", async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-agent-a11y-"));
    try {
      const bin = path.join(dir, "bin");
      const run = path.join(dir, "run");
      const log = path.join(dir, "calls.log");
      for (const d of [bin, run]) mkdirSync(d);
      const stub = (name: string, body: string) => {
        writeFileSync(path.join(bin, name), `#!/bin/sh\n${body}\n`);
        chmodSync(path.join(bin, name), 0o755);
      };
      // The session bus listens on the socket it is given and stays up.
      stub("dbus-daemon", `echo "dbus-daemon $*" >> ${log}\nsock=$(echo "$*" | sed -n 's/.*--address=unix:path=\\([^ ]*\\).*/\\1/p')\nexec python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(); time.sleep(60)' "$sock" >/dev/null 2>&1`);
      // The launcher owns org.a11y.Bus once it runs, then exits after a while.
      stub("launcher", `echo "launcher $* bus=$DBUS_SESSION_BUS_ADDRESS" >> ${log}\ntouch ${dir}/owned\nsleep 2`);
      stub("dbus-send", `case "$*" in\n*NameHasOwner*) if [ -e ${dir}/owned ]; then echo "   boolean true"; else echo "   boolean false"; fi ;;\n*GetAddress*) echo "   unix:path=/run/x/at-spi/bus_0,guid=abc   " ;;\n*) exit 1 ;;\nesac`);
      stub("set-root-property", `echo "set-root-property $*" >> ${log}`);
      writeFileSync(path.join(dir, "a11y"), a11yScript(path.join(bin, "launcher"), path.join(bin, "set-root-property")));
      chmodSync(path.join(dir, "a11y"), 0o755);
      await bashSyntax(a11yScript());
      const result = await runChild(path.join(dir, "a11y"), [], { timeout: 20_000, env: { ...process.env, PATH: `${bin}:${process.env.PATH ?? ""}`, XDG_RUNTIME_DIR: run, DISPLAY: ":7" } });
      expect(result.status).toBe(1);
      expect(result.stderr).toContain("exited on :7");
      expect(readFileSync(log, "utf8").trim().split("\n")).toEqual([
        `dbus-daemon --session --nofork --nopidfile --address=unix:path=${run}/bus`,
        `launcher --launch-immediately bus=unix:path=${run}/bus`,
        "set-root-property AT_SPI_BUS unix:path=/run/x/at-spi/bus_0,guid=abc",
      ]);
      expect(readFileSync(path.join(run, "at-spi-bus"), "utf8")).toBe("unix:path=/run/x/at-spi/bus_0,guid=abc\n");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("the root property writer sets AT_SPI_BUS as xprop would, with the display's cookie", async () => {
    const files = new Map(agentToolsFiles(rdLock).map((f) => [f.path, f]));
    expect(files.get(ROOT_PROPERTY_SCRIPT)?.text).toBe(rootPropertyScript());
    expect(files.get(ROOT_PROPERTY_SCRIPT)?.mode).toBe(0o755);
    const parsed = await runChild("python3", ["-I", "-c", "import ast, sys; ast.parse(sys.stdin.read())"], { input: rootPropertyScript(), timeout: 20_000 });
    expect(parsed.stderr).toBe("");
    expect(parsed.status).toBe(0);
  });

  const haveXvfb = ["/usr/bin/Xvfb", "/usr/bin/xprop", "/usr/bin/xauth", "/usr/bin/mcookie"].every((f) => existsSync(f));
  (haveXvfb ? test : test.skip)("the root property writer against a real Xvfb with a cookie (runs where Xvfb and xprop are installed)", async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-root-prop-"));
    const display = `:${200 + Math.floor(Math.random() * 500)}`;
    const auth = path.join(dir, "Xauthority");
    // The cookie first: Xvfb reads its -auth file once, at start.
    const cookie = (await runChild("/usr/bin/mcookie", [])).stdout.trim();
    expect((await runChild("/usr/bin/xauth", ["-q", "-f", auth, "add", display, ".", cookie])).status).toBe(0);
    const xvfb = spawn("/usr/bin/Xvfb", [display, "-nolisten", "tcp", "-auth", auth, "-noreset"], { stdio: "ignore" });
    try {
      const sock = `/tmp/.X11-unix/X${display.slice(1)}`;
      for (let i = 0; i < 100 && !existsSync(sock); i++) await new Promise((resolve) => setTimeout(resolve, 100));
      writeFileSync(path.join(dir, "set"), rootPropertyScript());
      const env = { ...process.env, DISPLAY: display, XAUTHORITY: auth };
      const set = await runChild("python3", ["-I", path.join(dir, "set"), "AT_SPI_BUS", "unix:path=/run/x/at-spi/bus_0,guid=abc"], { env, timeout: 20_000 });
      expect(set.stderr).toBe("");
      expect(set.status).toBe(0);
      const read = await runChild("/usr/bin/xprop", ["-root", "AT_SPI_BUS"], { env, timeout: 20_000 });
      expect(read.stdout.trim()).toBe('AT_SPI_BUS(STRING) = "unix:path=/run/x/at-spi/bus_0,guid=abc"');
      const refused = await runChild("python3", ["-I", path.join(dir, "set"), "AT_SPI_BUS", "x"], { env: { ...env, XAUTHORITY: path.join(dir, "none") }, timeout: 20_000 });
      expect(refused.status).not.toBe(0);
    } finally {
      xvfb.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  describe("desktop (cmux.rd/1 on the agent display over the owner's Native link, service desktop)", () => {
    const rd = rdLock.programs.find((p) => p.name === "cmux-rd")!;
    const hostBin = `${storeEntry(rd.sha256)}/bin/cmux-rd`;

    test("without a cmux-rd lock entry in role desktop the agent tools bake fails, naming the release to pin", () => {
      expect(() => agentToolsFiles(withoutRd)).toThrow(/cmux-rd-v<version>.*cmux-rd-<version>-x86_64-unknown-linux-gnu\.tar\.gz and checksums\.txt/);
      const noRole: InputsLock = { ...withoutRd, programs: [...withoutRd.programs, { ...rd, roles: ["cua"] }] };
      expect(() => rdHostPath(noRole)).toThrow(/role desktop/);
      expect(rdHostPath(rdLock)).toBe(hostBin);
    });

    test("the bake records role desktop from the lock (so a layered bake with a cached agents layer records it too)", () => {
      expect(desktopRecord(rdLock)).toEqual({ role: "desktop", program: "cmux-rd", version: rd.version, socketUnit: RD_SOCKET_UNIT, socket: RD_SOCKET });
      expect(() => desktopRecord(withoutRd)).toThrow(/cmux-rd-v<version>/);
    });

    test("the socket is root:cmux 0660 (the link receiver runs as cmux) in a 0711 root dir, enabled at boot, and starts the host service", () => {
      const socket = rdSocketUnit();
      expect(RD_SOCKET).toBe("/run/cmux-rd/desktop.sock");
      expect(socket).toContain(`ListenStream=${RD_SOCKET}\n`);
      expect(socket).toContain("SocketUser=root\n");
      expect(socket).toContain("SocketGroup=cmux\n");
      expect(socket).toContain("SocketMode=0660\n");
      expect(socket).toContain("DirectoryMode=0711\n");
      expect(socket).toContain("Accept=no\n");
      expect(socket).toContain(`Service=${RD_UNIT}\n`);
      expect(socket).toContain("[Install]\nWantedBy=sockets.target\n");
      expect(socket).not.toMatch(/ListenStream=.*:\d+|ListenStream=\d/);
      // The socket dir: anyone may traverse to the socket by name, nobody but root lists or writes it.
      expect(rdTmpfiles()).toContain(`d ${RD_RUN_DIR} 0711 root root -\n`);
    });

    test("the host runs as cmux-rd on :99, socket-activated, accepting only the work user's uid, with no TCP or token", () => {
      const unit = rdUnit(hostBin);
      expect(RD_UNIT).toBe("cmux-agent-rd.service");
      expect(RD_PEER_UID).toBe(DEVBOX_WORK_UID);
      expect(unit).toContain(`ExecStart=${hostBin} host --listen-systemd --peer-uid ${DEVBOX_WORK_UID} --display :99 --xauthority ${RD_XAUTHORITY} --codec openh264\n`);
      // The cookie copy lives in the host's own runtime dir, not in the socket dir the work user can traverse.
      expect(RD_HOST_DIR).toBe("/run/cmux-rd-host");
      expect(RD_XAUTHORITY).toBe("/run/cmux-rd-host/Xauthority-99");
      expect(unit).toContain("RuntimeDirectory=cmux-rd-host\nRuntimeDirectoryMode=0700\n");
      expect(unit).toContain("User=cmux-rd\n");
      expect(unit).toContain("Group=cmux-rd\n");
      expect(unit).not.toContain("User=cmux\n");
      expect(unit).toContain(`BindsTo=${DISPLAY_UNIT}\n`);
      expect(unit).toContain(`After=${DISPLAY_UNIT} ${RD_SOCKET_UNIT}\n`);
      expect(unit).toContain("StateDirectory=cmux-rd\n");
      expect(unit).toContain("Environment=XDG_DATA_HOME=/var/lib/cmux-rd\n");
      for (const line of ["NoNewPrivileges=yes", "CapabilityBoundingSet=", "AmbientCapabilities=", "ProtectHome=yes", "ProtectSystem=strict", "PrivateTmp=yes", "BindReadOnlyPaths=/tmp/.X11-unix", "PrivateDevices=yes", "RestrictSUIDSGID=yes"]) expect(unit).toContain(`\n${line}\n`);
      // The activated socket and the X display are Unix sockets: no network family at all.
      expect(unit).toContain("\nRestrictAddressFamilies=AF_UNIX\n");
      expect(unit).toContain(`Requires=${RD_OPENH264_UNIT}\n`);
      expect(unit).toContain(`After=${RD_OPENH264_UNIT}\n`);
      // A run of failed starts never leaves the socket failed.
      expect(unit).toContain("\nStartLimitIntervalSec=0\n");
      expect(unit).not.toContain("StartLimitBurst");
      expect(unit).not.toContain("openh264-install");
      // Only the socket starts it; nothing listens on TCP and no token reaches it.
      expect(unit).not.toContain("[Install]");
      for (const word of ["--port", "--bind", "--token-fd", "--owner", "start-rd.sh", "token"]) expect(unit).not.toContain(word);
    });

    test("OpenH264 is its own oneshot unit as cmux-rd, first start only, the only cmux-rd unit with network families", () => {
      const unit = rdOpenh264Unit(hostBin);
      expect(unit).toContain(`ExecStart=${hostBin} openh264-install\n`);
      expect(unit).toContain("ConditionPathExists=!/var/lib/cmux-rd/openh264-installed\n");
      expect(unit).toContain("ExecStartPost=/usr/bin/touch /var/lib/cmux-rd/openh264-installed\n");
      expect(unit).toContain("Type=oneshot\n");
      expect(unit).toContain("User=cmux-rd\n");
      expect(unit).toContain("StateDirectory=cmux-rd\n");
      expect(unit).toContain("\nCapabilityBoundingSet=\n");
      expect(unit).toContain("\nRestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK\n");
      expect(unit).not.toContain("[Install]");
    });

    test("ExecStartPre: root never opens the agent's cookie; it is read as cmux (no groups, no caps), regular files only, size-capped", async () => {
      const unit = rdUnit(hostBin);
      const pre = unit.split("\n").filter((l) => l.startsWith("ExecStartPre="));
      expect(pre).toEqual([`ExecStartPre=+/bin/sh -c '${rdCookieCopy()}'`]);
      const copy = rdCookieCopy();
      expect(copy).toContain(`timeout 5 setpriv --reuid=cmux --regid=cmux --clear-groups --inh-caps=-all --bounding-set=-all --no-new-privs /bin/sh -c "test -f ${AGENT_XAUTHORITY} && test ! -L ${AGENT_XAUTHORITY} && head -c 4097 ${AGENT_XAUTHORITY}" > ${RD_XAUTHORITY}.new`);
      expect(copy).toContain(`test "$(wc -c < ${RD_XAUTHORITY}.new)" -le 4096`);
      expect(copy).toContain(`chown -h cmux-rd:cmux-rd ${RD_XAUTHORITY}.new && mv -f ${RD_XAUTHORITY}.new ${RD_XAUTHORITY}`);
      // The host dir belongs to cmux-rd: root creates the temp file exclusively and never chmods through a link.
      expect(copy.startsWith("umask 077; set -C; ")).toBe(true);
      expect(copy).not.toContain("chmod");
      // systemd expands % specifiers in Exec lines: the script has none.
      expect(copy).not.toContain("%");
      // Root never names the source outside the work user's reader.
      expect(copy.replace(/setpriv [^"]*"[^"]*"/, "")).not.toContain(AGENT_XAUTHORITY);
      expect(copy).not.toMatch(/(^|; )(install|cp|cat) [^;]*\/home\//);
      // systemd expands $NAME in Exec lines: the script uses none, and no single quote ends it early.
      expect(copy).not.toMatch(/\$\{?[A-Za-z_]/);
      expect(copy).not.toContain("'");
      await bashSyntax(copy);
      const r = await runChild("sh", ["-n"], { input: copy, timeout: 20_000 });
      expect(r.status).toBe(0);
    });

    test("the cookie copy, run with the work user's reader stubbed: a regular file is copied; a symlink, a FIFO, an empty or an oversized file are refused", async () => {
      const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-rd-cookie-"));
      try {
        const src = path.join(dir, "home", "Xauthority-99");
        const run = path.join(dir, "run");
        const x11 = path.join(dir, "X99");
        mkdirSync(path.dirname(src));
        writeFileSync(x11, "");
        // As the probe would on the machine, minus what needs root: the reader runs as this user, no chown.
        const local = rdCookieCopy()
          .replace(/setpriv [^/]*\/bin\/sh/, "/bin/sh")
          .replace(/test -d \/run\/cmux-rd-host [^|]*\|\| \{[^}]*\}/, `mkdir -p ${run}`)
          .replace(/chown -h [^;\s]+ [^;\s]+ && /, "")
          .replace("[ -S /tmp/.X11-unix/X99 ]", `[ -e ${x11} ]`)
          .replace("[ -S /tmp/.X11-unix/X99 ]", `[ -e ${x11} ]`)
          .replaceAll(AGENT_XAUTHORITY, src)
          .replaceAll(RD_HOST_DIR, run);
        expect(local).not.toContain("setpriv");
        expect(local).not.toContain("chown");
        expect(local).toContain(`mkdir -p ${run}; for i in`);
        const copy = () => runChild("sh", ["-c", local], { timeout: 20_000 });
        const dest = path.join(run, "Xauthority-99");
        writeFileSync(src, "cookie-bytes");
        expect((await copy()).status).toBe(0);
        expect(readFileSync(dest, "utf8")).toBe("cookie-bytes");
        rmSync(dest);
        for (const [what, make] of [
          ["symlink", () => { writeFileSync(path.join(dir, "secret"), "root-only"); symlinkSync(path.join(dir, "secret"), src); }],
          ["fifo", async () => { await runChild("mkfifo", [src]); }],
          ["empty", () => writeFileSync(src, "")],
          ["oversized", () => writeFileSync(src, "x".repeat(4097))],
        ] as const) {
          rmSync(src, { force: true });
          await make();
          const r = await copy();
          expect({ what, status: r.status }).toEqual({ what, status: 1 });
          expect(existsSync(dest)).toBe(false);
          expect(existsSync(`${dest}.new`)).toBe(false);
        }
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    });

    test("the bake makes cmux-rd a system user in no other group, with no shell, home or sudo, and leaves the socket listening and the host off", async () => {
      const setup = rdSetupCommand();
      expect(setup).toContain("useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin cmux-rd");
      expect(setup).toContain(`test "$(id -nG ${RD_USER})" = ${RD_USER}`);
      expect(setup).toContain(`sudo -l -U ${RD_USER}`);
      expect(setup).toContain(`systemctl enable --now --quiet ${RD_SOCKET_UNIT}`);
      expect(setup).toContain(`! systemctl is-active --quiet ${RD_UNIT}`);
      expect(setup).toContain(`test "$(stat -c '%a %U %G' ${RD_RUN_DIR})" = '711 root root'`);
      expect(setup).toContain(`test "$(stat -c '%a %U %G' ${RD_SOCKET})" = '660 root cmux'`);
      expect(setup).toContain(`test "$(id -u cmux)" = ${DEVBOX_WORK_UID}`);
      expect(setup).not.toMatch(/usermod|-G cmux|sudoers/);
      await bashSyntax(setup);
      const files = new Map(agentToolsFiles(rdLock).map((f) => [f.path, f]));
      expect(files.get(`/etc/systemd/system/${RD_SOCKET_UNIT}`)).toEqual({ path: `/etc/systemd/system/${RD_SOCKET_UNIT}`, text: rdSocketUnit(), mode: 0o644 });
      expect(files.get(`/etc/systemd/system/${RD_UNIT}`)).toEqual({ path: `/etc/systemd/system/${RD_UNIT}`, text: rdUnit(hostBin), mode: 0o644 });
      expect(files.get(RD_TMPFILES)?.text).toBe(rdTmpfiles());
      expect(files.get(`/etc/systemd/system/${RD_OPENH264_UNIT}`)?.text).toBe(rdOpenh264Unit(hostBin));
      expect(setup).toContain(`/etc/systemd/system/${RD_OPENH264_UNIT}`);
      // No token file and no start script anywhere in the image's agent tools.
      for (const f of files.values()) expect(f.path).not.toMatch(/start-rd|token/);
    });

    test("probe: every desktop command parses, and the connect helper reports connected or the errno name", async () => {
      for (const command of [rdStaticCheckCommand(), rdActivateCommand(), rdOtherUserCommand(), rdReadCommand(RD_XAUTHORITY), rdConnectCommand(0)]) await bashSyntax(command);
      // The cookie read runs while the connection is held: before the kill, after the host's dir exists.
      const activate = rdActivateCommand();
      const read = activate.indexOf(`setpriv --reuid=cmux --regid=cmux --init-groups ${rdReadCommand(RD_XAUTHORITY)}`);
      expect(read).toBeGreaterThan(activate.indexOf("rd-host-dir="));
      expect(read).toBeLessThan(activate.indexOf('kill "$held"'));
      // The host is started by a connection as the work user, the link receiver's uid; another user is refused.
      expect(rdActivateCommand()).toContain(`setpriv --reuid=cmux --regid=cmux --init-groups python3`);
      expect(rdOtherUserCommand()).toContain("setpriv --reuid=nobody --regid=nogroup --clear-groups python3");
      const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-rd-connect-"));
      try {
        const sock = path.join(dir, "s.sock");
        const missing = await runChild("sh", ["-c", rdConnectCommand(0).replace(RD_SOCKET, sock)], { timeout: 20_000 });
        expect(missing.stdout.trim()).toBe("connect=ENOENT");
        const server = spawn("python3", ["-c", "import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(); time.sleep(20)", sock], { stdio: "ignore" });
        try {
          for (let i = 0; i < 100 && !existsSync(sock); i++) await new Promise((resolve) => setTimeout(resolve, 50));
          const ok = await runChild("sh", ["-c", rdConnectCommand(0).replace(RD_SOCKET, sock)], { timeout: 20_000 });
          expect(ok.stdout.trim()).toBe("connect=connected");
        } finally {
          server.kill();
        }
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    });

    test("probe: the read helper names the errno, so a missing cookie copy (ENOENT) never passes as unreadable (EACCES)", async () => {
      const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-rd-read-"));
      try {
        const file = path.join(dir, "Xauthority-99");
        const read = (f: string) => runChild("sh", ["-c", rdReadCommand(f)], { timeout: 20_000 });
        expect((await read(file)).stdout.trim()).toBe("read=ENOENT");
        writeFileSync(file, "c");
        expect((await read(file)).stdout.trim()).toBe("read=readable");
        if (process.getuid?.() !== 0) {
          chmodSync(file, 0o000);
          expect((await read(file)).stdout.trim()).toBe("read=EACCES");
        }
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    });
  });

  test("the agent tools bake installs only the browser role, never cua-video", () => {
    const phases = browserRoleBakePhases(lock).map((p) => p.command).join("\n");
    expect(phases).not.toContain("ffmpeg");
    expect(phases).not.toContain("x264");
  });
});
