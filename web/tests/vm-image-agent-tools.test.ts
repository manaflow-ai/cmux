import { describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { agentStepPlan, parseRecordedLaunch, probeOptionsFromArgv, recorderScript, staticCheckCommand, toolListProblems } from "../scripts/cmux-vm-image/agent-tools-probe";
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
} from "../scripts/cmux-vm-image/agent-tools";
import { bakeOptionsFromArgv, daemonUnit } from "../scripts/cmux-vm-image/bake";
import { CURRENT_BIN, readInputsLock, rolesManifest } from "../scripts/cmux-vm-image/lock";
import { runChild } from "./helpers/run-child";

const lock = readInputsLock();

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
    for (const file of agentToolsFiles().filter((f) => f.path.endsWith("cmux-cua"))) await bashSyntax(file.text);
    const phases = browserRoleBakePhases(lock);
    expect(phases.map((p) => p.name)).toEqual(["agent-tools-browser-apt-install", "agent-tools-browser-program-chrome-for-testing", "agent-tools-browser-program-cmux-browser-host", "agent-tools-browser-lists"]);
    for (const phase of phases) await bashSyntax(phase.command);
    await bashSyntax(staticCheckCommand());
  });

  test("the shared agent display is display :99 of the per-display template, and the driver runs on it with its AT-SPI bus as the work user", () => {
    // One Xvfb unit for :99: the template instance, so the AT-SPI bus unit (BindsTo) can follow it.
    expect(DISPLAY_UNIT).toBe("cmux-agent-display@99.service");
    expect(A11Y_UNIT).toBe("cmux-agent-a11y@99.service");
    expect(AGENT_XAUTHORITY).toBe(agentXauthority("99"));
    const paths = agentToolsFiles().map((f) => f.path);
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
    const files = agentToolsFiles().filter((f) => f.path.startsWith(`${CUA_REFUSE_DIR}/`));
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
    const files = new Map(agentToolsFiles().map((f) => [f.path, f]));
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
    const files = new Map(agentToolsFiles().map((f) => [f.path, f]));
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

  test("the agent tools bake installs only the browser role, never cua-video", () => {
    const phases = browserRoleBakePhases(lock).map((p) => p.command).join("\n");
    expect(phases).not.toContain("ffmpeg");
    expect(phases).not.toContain("x264");
  });
});
