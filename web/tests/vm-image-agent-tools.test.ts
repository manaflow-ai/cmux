import { describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { agentStepPlan, parseRecordedLaunch, probeOptionsFromArgv, recorderScript, staticCheckCommand, toolListProblems } from "../scripts/cmux-vm-image/agent-tools-probe";
import { readFileSync as readSource } from "node:fs";
import {
  AGENT_TOOLS_BIN,
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
  displayUnit,
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
    expect(plain).not.toContain("CMUX_BROWSER_HOST");
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

  test("the display listens only on its Unix socket with a cookie, and the driver runs on it as the work user", () => {
    const display = displayUnit();
    expect(display).toContain("-nolisten tcp");
    expect(display).toContain("-auth ");
    expect(display).toContain("User=cmux");
    expect(display).not.toContain("[Install]");
    const cua = cuaUnit();
    expect(cua).toContain(`Requires=${DISPLAY_UNIT}`);
    expect(cua).toContain("Environment=DISPLAY=:99");
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
    expect(probeOptionsFromArgv(base)).toEqual({ snapshotId: "sh-1", tag: "t", vmId: undefined, modelRoute: "none", outDir: expect.any(String) });
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

  test("the agent tools bake installs only the browser role, never cua-video", () => {
    const phases = browserRoleBakePhases(lock).map((p) => p.command).join("\n");
    expect(phases).not.toContain("ffmpeg");
    expect(phases).not.toContain("x264");
  });
});
