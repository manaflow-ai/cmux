import { describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { agentStepPlan, attachedComputerUse, computerUseWorkerCommand, CU_SERVER, gatewayProblems, LEGACY_CU_SERVER, parseRecordedLaunch, probeOptionsFromArgv, rdActivateCommand, rdConnectCommand, rdOtherUserCommand, rdReadCommand, rdStaticCheckCommand, RECORD_TRIES, recorderScript, recordSteps, requiredTools, screenshotShowsDisplay, staticCheckCommand, toolListProblems, videoToolProblems } from "../scripts/cmux-vm-image/agent-tools-probe";
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
  RD_START_SCRIPT,
  RD_TMPFILES,
  RD_UNIT,
  RD_USER,
  RD_LINK_STUN,
  RD_XAUTHORITY,
  rdCookieCopy,
  rdHostPath,
  rdOpenh264Unit,
  rdSetupCommand,
  rdSocketUnit,
  rdStartScript,
  rdTmpfiles,
  rdUnit,
  AGENT_DISPLAY_SIZE,
  DESKTOP_CHECK_SCRIPT,
  DESKTOP_CHECK_SECONDS,
  DESKTOP_SESSION_SCRIPT,
  DESKTOP_SESSION_UNIT,
  desktopCheckScript,
  desktopSessionScript,
  desktopSessionUnit,
  DESKTOP_STARTER,
  desktopStarterScript,
  NO_NEW_PRIVS_ENV,
  WORK_USER_CMUX_JSON_TEXT,
} from "../scripts/cmux-vm-image/agent-tools";
import { bakeOptionsFromArgv, daemonUnit, desktopRecord, refusedFirstUsePackages } from "../scripts/cmux-vm-image/bake";
import { CURRENT_BIN, type InputsLock, type LockedProgram, readInputsLock, rolesManifest, storeEntry } from "../scripts/cmux-vm-image/lock";
import { DEVBOX_WORK_UID } from "../services/vms/images/workUser";
import { runChild } from "./helpers/run-child";
import net from "node:net";

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

  test("Cloud Native bakes include the desktop closure by default", () => {
    expect(bakeOptionsFromArgv(["bun", "bake.ts", "--tag", "t"]).agentTools).toBe(true);
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
    expect(phases.map((p) => p.name)).toEqual([
      "agent-tools-browser-apt-fetch",
      "agent-tools-browser-apt-install",
      "agent-tools-browser-program-chrome-for-testing",
      "agent-tools-browser-program-cmux-browser-host",
      "agent-tools-display-wm-apt-fetch",
      "agent-tools-display-wm-apt-install",
      "agent-tools-browser-path",
      "agent-tools-browser-lists",
    ]);
    // An agent's `chromium --headless` finds the baked Chrome on PATH.
    const browserPath = phases.find((p) => p.name === "agent-tools-browser-path")!.command;
    for (const name of ["chromium", "chromium-browser", "google-chrome"]) expect(browserPath).toContain(`/usr/local/bin/${name}`);
    expect(browserPath).toContain(rolesManifest(lock).roles.browser!.env.CMUX_BROWSER_HOST_CHROMIUM!);
    // The desktop session's closure, pinned from the lock like the browser's: each .deb by its locked sha256.
    const wm = phases.find((p) => p.name === "agent-tools-display-wm-apt-fetch")!.command;
    for (const [name, version] of Object.entries(lock.apt.ubuntu.firstUse["display-wm"])) expect(wm).toContain(lock.apt.ubuntu.debs[`${name}=${version}`]!.sha256);
    expect(lock.roles["display-wm"].apt).toEqual(["openbox", "xterm"]);
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

  test("probe: the tool list must name the Computer Use tools, the browser REPL tools and the browser skill", () => {
    const full = "mcp__cmux-computer-use__screenshot\nmcp__cmux-computer-use__click\nmcp__cmux__browser_repl_eval\nmcp__cmux__browser_repl_open\n- cmux:cmux-browser";
    expect(toolListProblems(full)).toEqual([]);
    expect(toolListProblems("I have no MCP servers connected.")).toHaveLength(5);
    expect(toolListProblems(full.replace("mcp__cmux__browser_repl_eval", ""))).toEqual(["the agent does not list mcp__cmux__browser_repl_eval"]);
  });

  test("probe: no personal credential can reach a VM; the flag is gone and any token-file flag is refused", () => {
    const source = readSource(new URL("../scripts/cmux-vm-image/agent-tools-probe.ts", import.meta.url), "utf8");
    for (const word of ["claude-token-file", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_OAUTH_TOKEN", "anthropic-oauth"]) expect(source).not.toContain(word);
    const base = ["bun", "probe.ts", "--snapshot", "sh-1", "--tag", "t"];
    const parsed = probeOptionsFromArgv(base);
    expect({ ...parsed, outDir: typeof parsed.outDir }).toEqual({ snapshotId: "sh-1", tag: "t", vmId: undefined, modelRoute: "none", outDir: "string", baseline: "none" });
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

  test("probe: launches acpmux makes at once (the session and live_models' -p model list) never interleave their records (roll 45906244147)", async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-agent-tools-rec-"));
    try {
      const out = path.join(dir, "launches.txt");
      writeFileSync(path.join(dir, "claude"), recorderScript(out));
      chmodSync(path.join(dir, "claude"), 0o755);
      const configFile = path.join(dir, "session.json");
      writeFileSync(configFile, JSON.stringify({ mcpServers: { cmux: { type: "stdio", command: `${AGENT_TOOLS_BIN}/cmux`, args: ["mcp", "serve"], env: { PAD: "x".repeat(4000) } } } }), { mode: 0o600 });
      // A session launch of ~50 arguments, like acpmux's, beside model-list launches, many times over.
      const session = [...Array.from({ length: 24 }, (_, i) => [`--flag-${i}`, `value-${i}`]).flat(), "--mcp-config", configFile, "--plugin-dir", "/p/x", "--name", "recorder"];
      const modelList = ["-p", "--input-format", "stream-json", "--no-session-persistence", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}', "--settings", '{"disableAllHooks":true}'];
      const rounds = 12;
      for (let round = 0; round < rounds; round++) {
        await Promise.all([runChild(path.join(dir, "claude"), session, { timeout: 20_000 }), ...Array.from({ length: 3 }, () => runChild(path.join(dir, "claude"), modelList, { timeout: 20_000 }))]);
      }
      const records = readFileSync(out, "utf8").split("\x1e\n").filter((r) => r.trim());
      expect(records.length).toBe(rounds * 4);
      const sessions = records.filter((r) => r.includes("\n--plugin-dir\n") || r.startsWith("--plugin-dir\n"));
      expect(sessions.length).toBe(rounds);
      for (const r of sessions) {
        expect(r).toContain("MCP_CONFIG_FILE ");
        expect(r).not.toContain("--strict-mcp-config");
        expect(parseRecordedLaunch(`${r}\x1e\n`).servers.map((s) => s.name)).toEqual(["cmux"]);
      }
      // Whichever launch was recorded last, the probe reads the session's.
      expect(parseRecordedLaunch(readFileSync(out, "utf8")).servers.map((s) => s.name)).toEqual(["cmux"]);
      expect(parseRecordedLaunch(`${sessions[0]}\x1e\n${records.find((r) => r.includes("--strict-mcp-config"))}\x1e\n`).pluginDir).toBe("/p/x");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("probe: a record step whose session launch was not recorded starts it once more (roll 45914140136)", () => {
    const script = recordSteps("gateway", "PATH=/x:$PATH", "/tmp/l.txt").join("\n");
    expect(RECORD_TRIES).toBe(2);
    expect(script).toContain(`for try in $(seq 1 ${RECORD_TRIES}); do`);
    expect(script).toContain("grep -qx -- --plugin-dir /tmp/l.txt 2>/dev/null && break");
    expect(script.match(/acp new -d -m claude -n gateway/g)?.length).toBe(1);
  });

  test("probe: acpmux's gateway (#48374) attaches cmux as loopback HTTP with no command; the parser keeps its url", () => {
    // Bake run 44875111659: the launch's cmux entry was {type: http, url} and the probe threw on its missing command.
    const url = "http://127.0.0.1:41733/mcp/s-1f2e/tools";
    const text = `--print\n--mcp-config\n${JSON.stringify({ mcpServers: { cmux: { type: "http", url, headers: { Authorization: "Bearer x" } } } })}\n\x1e\n`;
    const servers = parseRecordedLaunch(text).servers;
    expect(servers).toEqual([{ name: "cmux", command: "", args: [], env: {}, url }]);
    expect(gatewayProblems(servers)).toEqual([]);
    expect(attachedComputerUse(servers)).toBeNull();
    expect(gatewayProblems([{ ...servers[0], url: "http://10.0.0.5:41733/mcp/s-1f2e/tools" }])).toEqual(["cmux url http://10.0.0.5:41733/mcp/s-1f2e/tools is not loopback"]);
    // Roll 44895229777: acpmux gives a harness its session endpoint itself, `/mcp/<session>` (mcp_gateway.rs).
    for (const path of ["/mcp/s-1f2e", "/mcp/s-1f2e/tools/cmux"]) expect(gatewayProblems([{ ...servers[0], url: `http://127.0.0.1:41733${path}` }])).toEqual([]);
    expect(gatewayProblems([{ ...servers[0], url: "http://127.0.0.1:41733/other" }])).toHaveLength(1);
    expect(gatewayProblems([{ ...servers[0], url: "http://127.0.0.1:41733/mcp/s-1f2e/admin" }])).toHaveLength(1);
    expect(gatewayProblems([{ name: "cmux", command: `${AGENT_TOOLS_BIN}/cmux`, args: ["mcp", "serve"], env: {} }])).toEqual([]);
    expect(gatewayProblems([{ name: "cmux", command: "/tmp/cmux", args: [], env: {} }])).toHaveLength(1);
    expect(gatewayProblems([])).toEqual(["no cmux server"]);
  });

  test("probe: in code mode the cmux server must list cmux_exec; with --all-tools its browser tools; cmux-cua always its own", () => {
    // Bake run 42112724172: the code-mode cmux server listed ["cmux_exec", "cmux_workflow"] and answered browser_repl_eval.
    expect(requiredTools("cmux", ["mcp", "serve"])).toEqual(["cmux_exec"]);
    expect(requiredTools("cmux", ["mcp", "serve", "--all-tools"])).toEqual(["browser_repl_eval", "browser_repl_open"]);
    expect(requiredTools("cmux-cua", ["mcp"])).toEqual(["get_desktop_state", "click"]);
    expect(requiredTools(CU_SERVER, ["acp", "computer-use-mcp"])).toEqual(["screenshot", "list_windows", "click", "type_text", "get_ui_tree"]);
  });

  test("probe: the Computer Use server is the one acpmux attached: cmux-tui's own (#37003) from the image's cmux-tui, else the cmux-cua wrapper", () => {
    // What roll 44806546922's candidate recorded (acpmux at cmux-tui 067b466a), folded into the cmux server's upstreams.
    const store = "/opt/cmux/store/25c0f8363379dd03d9da4b27b43a067f52602cd4abdb6aa5596413de2413afc6/cmux-tui";
    const cmux = { name: "cmux", command: `${AGENT_TOOLS_BIN}/cmux`, args: ["mcp", "serve"], env: {} };
    const cu = { name: CU_SERVER, command: store, args: ["acp", "computer-use-mcp"], env: {} };
    expect(attachedComputerUse([cmux, cu])).toEqual({ name: CU_SERVER, ok: true, legacy: false });
    expect(attachedComputerUse([{ ...cu, command: "/tmp/fake-cu" }])).toEqual({ name: CU_SERVER, ok: false, legacy: false });
    expect(attachedComputerUse([{ ...cu, args: ["acp", "offer-mcp"] }])?.ok).toBe(false);
    const legacy = { name: LEGACY_CU_SERVER, command: `${AGENT_TOOLS_BIN}/cmux-cua`, args: ["mcp"], env: {} };
    expect(attachedComputerUse([cmux, legacy])).toEqual({ name: LEGACY_CU_SERVER, ok: true, legacy: true });
    expect(attachedComputerUse([{ ...legacy, command: `${CURRENT_BIN}/cmux-cua` }])?.ok).toBe(false);
    // Both: cmux-tui's own wins; none: null, and the probe fails cmux-computer-use's checks.
    expect(attachedComputerUse([legacy, cu])?.name).toBe(CU_SERVER);
    expect(attachedComputerUse([cmux])).toBeNull();
  });

  test("probe: a Computer Use screenshot shows the whole display, at its size or scaled down whole (cmux-computer-use's 1456 px edge)", () => {
    expect(screenshotShowsDisplay("1920x1080", "1920x1080")).toBe(true);
    expect(screenshotShowsDisplay("1456x819", "1920x1080")).toBe(true);
    expect(screenshotShowsDisplay("1456x818", "1920x1080")).toBe(true);
    // A window-sized shot, a crop, a thumbnail, a larger image or nothing readable is not the display.
    expect(screenshotShowsDisplay("1280x800", "1920x1080")).toBe(false);
    expect(screenshotShowsDisplay("1456x1092", "1920x1080")).toBe(false);
    expect(screenshotShowsDisplay("1920x1000", "1920x1080")).toBe(false);
    expect(screenshotShowsDisplay("640x360", "1920x1080")).toBe(false);
    expect(screenshotShowsDisplay("3840x2160", "1920x1080")).toBe(false);
    expect(screenshotShowsDisplay("", "1920x1080")).toBe(false);
  });

  test("probe: role cua-video stays off: cmux-tui's Computer Use server may list no video or install tool", () => {
    // The bridge's catalog (cmux-computer-use tools.rs) as tools/list answers it.
    const catalog = ["status", "list_machines", "list_apps", "list_windows", "screenshot", "get_ui_tree", "click", "type_text", "press_key", "scroll", "drag", "set_value", "perform_action", "wait", "batch", "launch_app", "request_permission"];
    expect(videoToolProblems(catalog)).toEqual([]);
    expect(videoToolProblems([...catalog, "install_ffmpeg", "start_recording", "screen_video"])).toEqual(["lists install_ffmpeg", "lists start_recording", "lists screen_video"]);
  });

  test("probe: the record tool (#50070) passes only when a call to it was refused for want of an H.264 encoder", () => {
    const tools = ["status", "screenshot", "record"];
    expect(videoToolProblems(tools)).toEqual(["lists record"]);
    expect(videoToolProblems(tools, { isError: true, text: "unsupported: this desktop has no H.264 encoder, so it cannot record the screen yet" })).toEqual([]);
    expect(videoToolProblems(tools, { isError: true, text: "unsupported: the host has no H.264 encoder for recordings" })).toEqual([]);
    expect(videoToolProblems(tools, { isError: false, text: '{"path":"/tmp/r.mp4"}' })).toEqual(["lists record"]);
    expect(videoToolProblems(tools, { isError: true, text: "screen is locked" })).toEqual(["lists record"]);
    expect(videoToolProblems([...tools, "start_recording"], { isError: true, text: "unsupported: no H.264 encoder" })).toEqual(["lists start_recording"]);
  });

  test("probe: the worker check parses and reads the worker by its hidden mode, never its own pgrep line", async () => {
    const command = computerUseWorkerCommand();
    await bashSyntax(command);
    expect(command).toContain("pgrep -u cmux -f '[_]_computer-use-worker'");
    expect(command).toContain(`${DISPLAY_UNIT} ${A11Y_UNIT}`);
    expect(command).toContain("NoNewPrivs");
  });

  test("probe: acpmux's --mcp-config is a 0600 file it removes later: the recorder keeps its JSON, and code mode's upstreams count as servers", async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-agent-tools-rec-"));
    try {
      const out = path.join(dir, "launches.txt");
      writeFileSync(path.join(dir, "claude"), recorderScript(out));
      chmodSync(path.join(dir, "claude"), 0o755);
      // What acpmux writes today (agent_tools.rs folded + claude_args): one cmux server, the others in CMUX_MCP_UPSTREAMS.
      const upstreams = [{ name: "cmux-cua", command: `${AGENT_TOOLS_BIN}/cmux-cua`, args: ["mcp"], env: { CMUX_CUA_MCP_FORCE_PROXY: "1" } }];
      const configFile = path.join(dir, "session.json");
      writeFileSync(configFile, JSON.stringify({ mcpServers: { cmux: { type: "stdio", command: `${AGENT_TOOLS_BIN}/cmux`, args: ["mcp", "serve"], env: { CMUX_MCP_UPSTREAMS: JSON.stringify(upstreams) } } } }, null, 2), { mode: 0o600 });
      await runChild(path.join(dir, "claude"), ["--print", "--mcp-config", configFile, "--plugin-dir", "/p/x"], { timeout: 20_000 });
      rmSync(configFile);
      const launch = parseRecordedLaunch(readFileSync(out, "utf8"));
      expect(launch.servers.map((s) => [s.name, s.command, s.args])).toEqual([
        ["cmux", `${AGENT_TOOLS_BIN}/cmux`, ["mcp", "serve"]],
        ["cmux-cua", `${AGENT_TOOLS_BIN}/cmux-cua`, ["mcp"]],
      ]);
      expect(launch.servers[1].env).toEqual({ CMUX_CUA_MCP_FORCE_PROXY: "1" });
      expect(launch.pluginDir).toBe("/p/x");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  describe("desktop starter (cmux-tui's Computer Use worker on the agent display, #37003)", () => {
    /** Runs the starter with a recording `sudo` (exit 1 for `failUnit`) and, with `socket`, the display's X11 socket. */
    async function runStarter(opts: { failUnit?: string; socket?: boolean }): Promise<{ status: number | null; stdout: string; stderr: string; calls: string[] }> {
      const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-cu-starter-"));
      const x11 = path.join(dir, "x11");
      mkdirSync(x11);
      const server = opts.socket ? net.createServer() : null;
      try {
        if (server) await new Promise<void>((resolve) => server.listen(path.join(x11, "X99"), resolve));
        const log = path.join(dir, "calls.log");
        writeFileSync(path.join(dir, "sudo"), `#!/bin/sh\necho "sudo $*" >> ${log}\necho "starting $4" >&2\ncase "$4" in ${opts.failUnit ?? "none"}) exit 1;; esac\nexit 0\n`);
        chmodSync(path.join(dir, "sudo"), 0o755);
        writeFileSync(path.join(dir, "starter"), desktopStarterScript(x11));
        chmodSync(path.join(dir, "starter"), 0o755);
        const r = await runChild(path.join(dir, "starter"), [], { timeout: 20_000, env: { ...process.env, PATH: `${dir}:/usr/bin:/bin` } });
        const calls = existsSync(log) ? readFileSync(log, "utf8").trim().split("\n") : [];
        return { status: r.status, stdout: r.stdout, stderr: r.stderr, calls };
      } finally {
        server?.close();
        rmSync(dir, { recursive: true, force: true });
      }
    }

    test("it starts the display, then its AT-SPI bus, and names the worker's display, bus, headless switch, refusing PATH and no-new-privileges", async () => {
      const r = await runStarter({ socket: true });
      expect(r.status).toBe(0);
      expect(r.calls).toEqual([`sudo -n systemctl start ${DISPLAY_UNIT}`, `sudo -n systemctl start ${A11Y_UNIT}`]);
      const vars = Object.fromEntries(r.stdout.trim().split("\n").map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));
      const { PATH: workerPath, ...rest } = vars;
      expect(rest).toEqual({
        DISPLAY: ":99",
        XAUTHORITY: AGENT_XAUTHORITY,
        CMUX_CU_HEADLESS: "1",
        [NO_NEW_PRIVS_ENV]: "1",
        DBUS_SESSION_BUS_ADDRESS: `unix:path=${a11yRuntimeDir("99")}/bus`,
      });
      // The refusing tools first, then the daemon's PATH, so the worker still finds everything else.
      expect(workerPath.startsWith(`${CUA_REFUSE_DIR}:`)).toBe(true);
      expect(workerPath.endsWith(":/usr/bin:/bin")).toBe(true);

      // systemctl's own words go to stderr, never into the variables.
      expect(r.stdout).not.toContain("starting");
    });

    test("a bus that does not start leaves screenshots and X11 input: the display is named, the bus is not, and it says why", async () => {
      const r = await runStarter({ socket: true, failUnit: A11Y_UNIT });
      expect(r.status).toBe(0);
      expect(r.stdout).toContain("DISPLAY=:99");
      expect(r.stdout).not.toContain("DBUS_SESSION_BUS_ADDRESS");
      expect(r.stderr).toContain(`systemctl status ${A11Y_UNIT}`);
    });

    test("a display that does not start, or has no socket, gives no desktop and names the unit", async () => {
      for (const opts of [{ socket: true, failUnit: DISPLAY_UNIT }, { socket: false }]) {
        const r = await runStarter(opts);
        expect(r.status).toBe(1);
        expect(r.stdout).not.toContain("DISPLAY=");
        expect(r.stderr).toMatch(new RegExp(`systemctl status ${DISPLAY_UNIT}|has no socket`));
      }
    });

    test("the bake installs it root-owned at the path cmux-tui trusts, checks it parses and its folder is root's, and parses as sh", async () => {
      const file = agentToolsFiles(rdLock).find((f) => f.path === DESKTOP_STARTER);
      expect(DESKTOP_STARTER).toBe("/etc/cmux/computer-use-desktop");
      expect(file).toEqual({ path: DESKTOP_STARTER, text: desktopStarterScript(), mode: 0o755 });
      expect(agentToolsLinkCommand()).toContain(`sh -n ${DESKTOP_STARTER}`);
      expect(agentToolsLinkCommand()).toContain("'root:root 755 root:root 755 '");
      const r = await runChild("sh", ["-n"], { input: desktopStarterScript(), timeout: 20_000 });
      expect(r.status).toBe(0);
    });
  });

  test("the work user's cmux.json turns the cmux server on and gives agents cmux's tools (agents.cmuxMcp on, acpmux agent_tools.rs)", () => {
    // Without agents.cmuxMcp acpmux attaches no cmux server: roll 44806546922's candidate had no browser tools.
    expect(JSON.parse(WORK_USER_CMUX_JSON_TEXT)).toEqual({ mcp: { enabled: true }, agents: { cmuxMcp: "on" } });
  });

  test("cua-video stays off: the computer-use driver cannot install ffmpeg (install_ffmpeg runs `sudo -n apt-get install -y ffmpeg`)", async () => {
    const cua = cuaUnit();
    expect(cua).toContain("NoNewPrivileges=yes");
    expect(cua).toMatch(new RegExp(`Environment=PATH=${CUA_REFUSE_DIR}:`));
    const files = agentToolsFiles(rdLock).filter((f) => f.path.startsWith(`${CUA_REFUSE_DIR}/`));
    expect(files.map((f) => path.basename(f.path)).sort()).toEqual(["apt", "apt-get", "ffmpeg", "ffprobe", "sudo"]);
    const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-cua-refuse-"));
    try {
      for (const name of ["sudo", "apt-get", "ffmpeg", "ffprobe"]) {
        writeFileSync(path.join(dir, name), cuaRefuseScript(name));
        chmodSync(path.join(dir, name), 0o755);
      }
      const env = { ...process.env, PATH: `${dir}:${process.env.PATH ?? ""}` };
      const found = await runChild("sh", ["-c", "command -v apt-get"], { env, timeout: 20_000 });
      expect(found.stdout.trim()).toBe(path.join(dir, "apt-get"));
      // The image carries ffmpeg for people (graduated.json); the driver finds the refusing one first.
      for (const argv of [["sudo", "-n", "apt-get", "install", "-y", "ffmpeg"], ["apt-get", "install", "-y", "ffmpeg"], ["ffmpeg", "-f", "x11grab", "-i", ":99", "out.mp4"], ["ffprobe", "-version"]]) {
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
    expect(AGENT_DISPLAY_SIZE).toBe("1920x1080");
    expect(display).toContain(`ExecStart=/usr/bin/Xvfb :%i -screen 0 1920x1080x24 -nolisten tcp -auth ${agentXauthority("%i")} -s 0 -dpms -noreset\n`);
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

  test("the desktop session (ask-da398bba67): openbox and a terminal on :99 as the work user, bound to the display, its start checked", async () => {
    const unit = desktopSessionUnit();
    expect(DESKTOP_SESSION_UNIT).toBe("cmux-agent-desktop-session.service");
    expect(unit).toContain(`BindsTo=${DISPLAY_UNIT}\nAfter=${DISPLAY_UNIT}\n`);
    expect(unit).toContain("User=cmux\nGroup=cmux\n");
    expect(unit).toContain("Environment=DISPLAY=:99\n");
    expect(unit).toContain(`Environment=XAUTHORITY=${AGENT_XAUTHORITY}\n`);
    expect(unit).toContain(`ExecStart=${DESKTOP_SESSION_SCRIPT}\n`);
    // The start check: a session that shows nothing fails the unit, it does not pass quietly.
    expect(unit).toContain(`ExecStartPost=${DESKTOP_CHECK_SCRIPT} --wait ${DESKTOP_CHECK_SECONDS}\n`);
    expect(unit).toContain("Restart=on-failure\n");
    // No [Install]: the remote desktop host's unit wants it, so nothing runs while nobody looks.
    expect(unit).not.toContain("[Install]");
    const script = desktopSessionScript();
    await bashSyntax(script);
    expect(script).toContain("openbox --sm-disable &");
    expect(script).toMatch(/\nxterm .*&\n/);
    expect(script).toContain('wait "$wm"');
    const files = new Map(agentToolsFiles(rdLock).map((f) => [f.path, f]));
    expect(files.get(`/etc/systemd/system/${DESKTOP_SESSION_UNIT}`)).toEqual({ path: `/etc/systemd/system/${DESKTOP_SESSION_UNIT}`, text: unit, mode: 0o644 });
    expect(files.get(DESKTOP_SESSION_SCRIPT)?.mode).toBe(0o755);
    expect(files.get(DESKTOP_CHECK_SCRIPT)).toEqual({ path: DESKTOP_CHECK_SCRIPT, text: desktopCheckScript(), mode: 0o755 });
    const setup = rdSetupCommand();
    expect(setup).toContain(`/etc/systemd/system/${DESKTOP_SESSION_UNIT}`);
    expect(setup).toContain("command -v openbox >/dev/null && command -v xterm >/dev/null");
    expect(setup).toContain(`! systemctl is-active --quiet ${DESKTOP_SESSION_UNIT}`);
    // The host's start also checks, in the background, and names a black display in its own journal.
    const start = rdStartScript("/store/cmux-rd");
    expect(start).toContain(`DISPLAY=:99 ${DESKTOP_CHECK_SCRIPT} --wait ${DESKTOP_CHECK_SECONDS + 10} >/dev/null || echo "<3>cmux-rd-start: display :99 has no windows`);
    expect(start.indexOf(DESKTOP_CHECK_SCRIPT)).toBeLessThan(start.indexOf("exec '/store/cmux-rd' host"));
    const parsed = await runChild("python3", ["-I", "-c", "import ast, sys; ast.parse(sys.stdin.read())"], { input: desktopCheckScript(), timeout: 20_000 });
    expect(parsed.stderr).toBe("");
    expect(parsed.status).toBe(0);
  });

  const haveXvfbAlone = ["/usr/bin/Xvfb", "/usr/bin/xauth", "/usr/bin/mcookie"].every((f) => existsSync(f));
  (haveXvfbAlone ? test : test.skip)("the desktop check fails loudly on a black display and passes once a window is mapped (runs where Xvfb is installed)", async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-desktop-check-"));
    const display = `:${200 + Math.floor(Math.random() * 500)}`;
    const auth = path.join(dir, "Xauthority");
    const cookie = (await runChild("/usr/bin/mcookie", [])).stdout.trim();
    expect((await runChild("/usr/bin/xauth", ["-q", "-f", auth, "add", display, ".", cookie])).status).toBe(0);
    const xvfb = spawn("/usr/bin/Xvfb", [display, "-screen", "0", `${AGENT_DISPLAY_SIZE}x24`, "-nolisten", "tcp", "-auth", auth, "-noreset"], { stdio: "ignore" });
    let client: ReturnType<typeof spawn> | undefined;
    try {
      const sock = `/tmp/.X11-unix/X${display.slice(1)}`;
      for (let i = 0; i < 100 && !existsSync(sock); i++) await new Promise((resolve) => setTimeout(resolve, 100));
      writeFileSync(path.join(dir, "check"), desktopCheckScript());
      const env = { ...process.env, DISPLAY: display, XAUTHORITY: auth };
      const black = await runChild("python3", ["-I", path.join(dir, "check"), "--wait", "1"], { env, timeout: 20_000 });
      expect(black.status).toBe(1);
      expect(black.stdout.trim()).toBe(`windows=0 viewable=0 nonblack=0 size=${AGENT_DISPLAY_SIZE}`);
      // Error level in the journal (systemd reads the <3> prefix), naming the display.
      expect(black.stderr).toContain(`<3>cmux-agent-desktop-check: display ${display} shows a black screen`);
      // A client maps one white 400x300 window: the X11 helpers of the check, then CreateWindow and MapWindow.
      const mapWindow = `${desktopCheckScript().split("\ndef connect():")[0].replace(/^#!.*\n/, "")}
number = os.environ["DISPLAY"].split(":", 1)[1]
an, ad = cookie(number)
s = socket.socket(socket.AF_UNIX); s.connect("/tmp/.X11-unix/X" + number)
s.sendall(struct.pack("<BxHHHHxx", 0x6C, 11, 0, len(an), len(ad)) + pad(an) + pad(ad))
head = recv(s, 8); body = recv(s, 4 * struct.unpack_from("<H", head, 6)[0])
vendor = struct.unpack_from("<H", body, 16)[0]
root = struct.unpack_from("<I", body, 32 + len(pad(b"v" * vendor)) + 8 * body[21])[0]
wid = struct.unpack_from("<I", body, 4)[0] | 1
s.sendall(struct.pack("<BBHIIhhHHHHII", 1, 0, 9, wid, root, 50, 50, 400, 300, 0, 1, 0, 2) + struct.pack("<I", 0xFFFFFF))
s.sendall(struct.pack("<BxHI", 8, 2, wid))
s.sendall(struct.pack("<BxH", 43, 1)); reply(s)
print("mapped", flush=True)
sys.stdin.read()
`;
      writeFileSync(path.join(dir, "window"), mapWindow);
      client = spawn("python3", ["-I", path.join(dir, "window")], { env, stdio: ["pipe", "pipe", "inherit"] });
      await new Promise<void>((resolve) => client!.stdout!.once("data", () => resolve()));
      const lit = await runChild("python3", ["-I", path.join(dir, "check"), "--wait", "5"], { env, timeout: 20_000 });
      expect(lit.stderr).toBe("");
      expect(lit.status).toBe(0);
      expect(lit.stdout).toMatch(new RegExp(`^windows=1 viewable=1 nonblack=[1-9]\\d* size=${AGENT_DISPLAY_SIZE}\\n$`));
    } finally {
      client?.kill();
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
      const unit = rdUnit();
      expect(RD_UNIT).toBe("cmux-agent-rd.service");
      expect(RD_PEER_UID).toBe(DEVBOX_WORK_UID);
      // ExecStart is the start script, which execs exactly this host command (rdStartScript).
      expect(unit).toContain(`\nExecStart=${RD_START_SCRIPT}\n`);
      expect(rdStartScript(hostBin)).toContain(`exec '${hostBin}' host --listen-systemd --peer-uid ${DEVBOX_WORK_UID} --display :99 --xauthority ${RD_XAUTHORITY} --codec openh264 --link-stun ${RD_LINK_STUN}\n`);
      // The cookie copy lives in the host's own runtime dir, not in the socket dir the work user can traverse.
      expect(RD_HOST_DIR).toBe("/run/cmux-rd-host");
      expect(RD_XAUTHORITY).toBe("/run/cmux-rd-host/Xauthority-99");
      expect(unit).toContain("RuntimeDirectory=cmux-rd-host\nRuntimeDirectoryMode=0700\n");
      expect(unit).toContain("User=cmux-rd\n");
      expect(unit).toContain("Group=cmux-rd\n");
      expect(unit).not.toContain("User=cmux\n");
      // The dependency lines, pinned. BindsTo the display for its lifetime (a stop, restart or crash of
      // Xvfb stops the host, which would otherwise keep a stale cookie), with no After= on it, so a
      // display that fails to start never fails the start job before the start script can close the
      // connection. OpenH264 is wanted and ordered first; nothing else is required but the socket.
      const deps = unit.split("\n").filter((l) => /^(Wants|Requires|BindsTo|PartOf|Requisite|After|Before)=/.test(l));
      expect(deps).toEqual([
        `BindsTo=${DISPLAY_UNIT}`,
        `Wants=${RD_OPENH264_UNIT}`,
        // The person's desktop on the display, wanted and not waited for (ask-da398bba67).
        `Wants=${DESKTOP_SESSION_UNIT}`,
        `After=${RD_OPENH264_UNIT} ${RD_SOCKET_UNIT}`,
        `Requires=${RD_SOCKET_UNIT}`,
      ]);
      expect(deps.filter((l) => l.startsWith("After=")).join(" ")).not.toContain(DISPLAY_UNIT);
      expect(unit).toContain("StateDirectory=cmux-rd\n");
      expect(unit).toContain("Environment=XDG_DATA_HOME=/var/lib/cmux-rd\n");
      for (const line of ["NoNewPrivileges=yes", "CapabilityBoundingSet=", "AmbientCapabilities=", "ProtectHome=yes", "ProtectSystem=strict", "PrivateTmp=yes", "BindReadOnlyPaths=/tmp/.X11-unix", "PrivateDevices=yes", "RestrictSUIDSGID=yes"]) expect(unit).toContain(`\n${line}\n`);
      // The activated socket and the X display are Unix sockets; IPv4 (UDP) and netlink only for the datagram link.
      expect(unit).toContain("\nRestrictAddressFamilies=AF_UNIX AF_INET AF_NETLINK\n");
      // A run of failed starts never leaves the socket failed.
      expect(unit).toContain("\nStartLimitIntervalSec=0\n");
      expect(unit).not.toContain("StartLimitBurst");
      expect(unit).not.toContain("openh264-install");
      // Only the socket starts it; nothing listens on TCP and no token reaches it.
      expect(unit).not.toContain("[Install]");
      for (const word of ["--port", "--bind", "--token-fd", "--owner", "start-rd.sh", "token"]) expect(unit).not.toContain(word);
    });

    /**
     * Runs the start script as systemd would (the listening socket as fd 3, LISTEN_FDS=1,
     * LISTEN_PID its own pid) with `queued` client connections already waiting, and reports what
     * each client sees and what the stub host recorded.
     */
    const START_HARNESS = String.raw`import json, os, socket, subprocess, sys
script, sock, queued, record = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
l = socket.socket(socket.AF_UNIX); l.bind(sock); l.listen(8)
clients = []
for _ in range(queued):
    c = socket.socket(socket.AF_UNIX); c.connect(sock); c.settimeout(1); clients.append(c)
fd = l.fileno()
p = subprocess.Popen(["/bin/sh", "-c", 'exec 3<&%d; LISTEN_FDS=1 LISTEN_PID=$$ exec "$0"' % fd, script], pass_fds=[fd], stderr=subprocess.PIPE, text=True)
_, err = p.communicate(timeout=20)
seen = []
for c in clients:
    try:
        seen.append("closed" if c.recv(1) == b"" else "data")
    except ConnectionResetError:
        seen.append("closed")
    except socket.timeout:
        seen.append("open")
recorded = open(record).read().strip() if os.path.exists(record) else ""
print(json.dumps({"status": p.returncode, "pid": p.pid, "stderr": err.strip(), "clients": seen, "recorded": recorded}))
`;

    async function runStart(setup: { x11?: boolean; cookie?: boolean; openh264?: boolean }, queued = 2) {
      const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-rd-start-"));
      try {
        const x11 = path.join(dir, "X99");
        const xauthority = path.join(dir, "Xauthority-99");
        const marker = path.join(dir, "openh264-installed");
        const record = path.join(dir, "host-args");
        if (setup.x11) {
          const server = await runChild("python3", ["-I", "-c", "import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])", x11]);
          expect(server.status).toBe(0);
        }
        if (setup.cookie) writeFileSync(xauthority, "cookie");
        if (setup.openh264) writeFileSync(marker, "");
        // The stub host records its pid, LISTEN_PID, LISTEN_FDS and argv, then exits without accepting.
        const host = path.join(dir, "cmux-rd");
        writeFileSync(host, `#!/bin/sh\necho "$$ $LISTEN_PID $LISTEN_FDS $*" > ${record}\n`);
        chmodSync(host, 0o755);
        const script = path.join(dir, "cmux-rd-start");
        writeFileSync(script, rdStartScript(host, { x11Socket: x11, xauthority, openh264Marker: marker }));
        chmodSync(script, 0o755);
        const r = await runChild("python3", ["-I", "-c", START_HARNESS, script, path.join(dir, "rd.sock"), String(queued), record], { timeout: 60_000 });
        expect(r.stderr).toBe("");
        return JSON.parse(r.stdout) as { status: number; pid: number; stderr: string; clients: string[]; recorded: string };
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    }

    test("start script: with the display, the cookie copy and OpenH264 it execs the host in its own pid, so LISTEN_PID still matches", async () => {
      await bashSyntax(rdStartScript(hostBin));
      const r = await runStart({ x11: true, cookie: true, openh264: true }, 1);
      expect(r.status).toBe(0);
      const [pid, listenPid, listenFds, ...argv] = r.recorded.split(" ");
      expect(pid).toBe(String(r.pid));
      expect(listenPid).toBe(String(r.pid));
      expect(listenFds).toBe("1");
      expect(argv.join(" ")).toBe(`host --listen-systemd --peer-uid ${DEVBOX_WORK_UID} --display :99 --xauthority ${RD_XAUTHORITY} --codec openh264 --link-stun ${RD_LINK_STUN}`);
      // The stub never accepted: the connection is still open (the real host would serve it).
      expect(r.clients).toEqual(["open"]);
    });

    for (const [missing, setup, reason] of [
      ["the display", { cookie: true, openh264: true }, "display :99 is not running"],
      ["the cookie copy", { x11: true, openh264: true }, "no copy of the display cookie"],
      ["OpenH264", { x11: true, cookie: true }, "OpenH264 is not installed"],
    ] as const) {
      test(`start script: without ${missing} it closes every queued connection, says why and exits 1, so systemd never starts the host again for it`, async () => {
        const r = await runStart(setup, 2);
        expect(r.status).toBe(1);
        expect(r.recorded).toBe("");
        expect(r.clients).toEqual(["closed", "closed"]);
        expect(r.stderr).toContain(reason);
        expect(r.stderr).toContain("closed 2 queued desktop connection(s)");
      });
    }

    test("start script: run by hand (no socket from systemd) it refuses and never execs the host", async () => {
      const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-rd-start-hand-"));
      try {
        const script = path.join(dir, "s");
        writeFileSync(script, rdStartScript("/nonexistent/cmux-rd"));
        chmodSync(script, 0o755);
        const r = await runChild(script, [], { timeout: 20_000, env: { ...process.env, LISTEN_FDS: "1", LISTEN_PID: "1" } });
        expect(r.status).toBe(1);
        expect(r.stderr).toContain("no socket from systemd");
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
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
      const unit = rdUnit();
      const pre = unit.split("\n").filter((l) => l.startsWith("ExecStartPre="));
      // `-`: a failed copy does not fail the start; the start script finds no cookie and closes the connection.
      expect(pre).toEqual([`ExecStartPre=-+/bin/sh -c '${rdCookieCopy()}'`]);
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
      expect(files.get(`/etc/systemd/system/${RD_UNIT}`)).toEqual({ path: `/etc/systemd/system/${RD_UNIT}`, text: rdUnit(), mode: 0o644 });
      expect(files.get(RD_START_SCRIPT)).toEqual({ path: RD_START_SCRIPT, text: rdStartScript(hostBin), mode: 0o755 });
      expect(setup).toContain(`sh -n ${RD_START_SCRIPT}`);
      expect(setup).toContain("test -x /usr/bin/python3");
      // Any accept error ends the drain rather than raising and leaving the connection queued.
      expect(rdStartScript(hostBin)).toContain("except OSError:");
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

describe("refusedFirstUsePackages", () => {
  const closures = lock.apt.ubuntu.firstUse;
  const all = [...new Set(Object.values(closures).flatMap((c) => Object.keys(c)))].sort();

  test("without agent tools, every first-use package stays refused", () => {
    expect(refusedFirstUsePackages(lock, false)).toEqual(all);
  });

  test("with agent tools, the browser and display-wm closures the bake installs are not refused, the rest still is", () => {
    const refused = refusedFirstUsePackages(lock, true);
    for (const name of [...Object.keys(closures.browser), ...Object.keys(closures["display-wm"])]) expect(refused).not.toContain(name);
    // The layered bake's agents layer failed on this one: browser and display-wm both carry it.
    expect(closures.browser.fontconfig).toBeDefined();
    expect(closures["display-wm"].fontconfig).toBeDefined();
    expect(refused).not.toContain("fontconfig");
    // The desktop session's window manager and terminal are baked with the agent tools.
    expect(refused).not.toContain("openbox");
    expect(refused).not.toContain("xterm");
    expect(refused).toContain("ffmpeg");
    expect(refused).toEqual(all.filter((name) => !(name in closures.browser) && !(name in closures["display-wm"])));
  });
});

describe("image tools (bc, browser on PATH)", () => {
  test("the profile exports the baked browser and the bake links and runs it headless", async () => {
    const m = await import("../scripts/cmux-vm-image/agent-tools");
    expect(m.agentToolsProfileScript("/opt/x/chrome")).toContain("export CHROME_BIN=/opt/x/chrome");
    expect(m.agentToolsProfileScript()).not.toContain("CHROME_BIN");
    const cmd = m.browserLinkCommand("/opt/x/chrome");
    for (const l of m.BROWSER_LINKS) expect(cmd).toContain(l);
    expect(cmd).toContain("--headless=new");
    expect(m.imageToolsSmokeCommand()).toContain("bc");
  });
});
