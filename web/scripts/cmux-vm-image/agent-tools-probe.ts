/**
 * Agent tools probe for a cmux VM image baked with `--agent-tools` (agent-tools.ts, bead cx-h8n).
 *
 * The probe never takes a credential. It has no token flag, it refuses every flag it does not
 * know, and it writes no credential to any machine (coordinator rule, 2026-10-07: no personal
 * credential on any VM, deleted test VMs included).
 *
 * Everything that needs no model runs on every machine, the way a person's session would: a
 * terminal of the machine's own daemon starts the machine's acpmux (`cmux-tui acp`).
 * 1. A recorder stands in for `claude` (first on PATH, own ACPMUX_HOME): acpmux launches it for a
 *    Claude Code session, and the recorder keeps the exact command line acpmux built (the
 *    `--mcp-config` servers and the `--plugin-dir` skills), then fails. No model is called.
 * 2. Each recorded MCP server is started with its recorded command, args and env from that
 *    terminal, and an MCP client lists its tools and calls them: the browser host takes a
 *    screenshot of a loopback page (the daemon socket-activates the host), and cmux-cua takes a
 *    screenshot of the Xvfb display (the wrapper starts it) with a Chrome window on it.
 * 3. The agent step (a Claude Code session that lists the tools and takes both screenshots
 *    itself) runs only with `--model-route edge` on a machine the backend created (`--vm`),
 *    whose agents reach the model through the coderouter edge. Otherwise it is UNVERIFIED.
 *
 * Usage (from web/):
 *   bun scripts/cmux-vm-image/agent-tools-probe.ts --snapshot <sh-id> --tag <tag> [--out-dir <dir>]
 *   bun scripts/cmux-vm-image/agent-tools-probe.ts --vm <provider vm id> --tag <tag> --model-route edge [--out-dir <dir>]
 * With --snapshot the clone is named cmuxnp-dev-vmimg-<tag>-agenttools, pauses after 300 s of
 * network idleness, is recorded in <out-dir>/resources.tsv, deleted by its exact id at the end
 * (also on failure), and a lookup by that id must then answer not found. With --vm the probe
 * neither creates nor deletes the machine; its owner (the backend) does.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { DEVBOX_WORK_HOME, DEVBOX_WORK_USER } from "../../services/vms/images/workUser";
import { AGENT_DISPLAY, AGENT_TOOLS_BIN, AGENT_XAUTHORITY, CUA_UNIT, DISPLAY_UNIT, WORK_USER_CMUX_JSON } from "./agent-tools";
import { createVm, deleteVm, firstExec, freestyleClient, Ledger, run, type Vm } from "./guest";
import { CURRENT_BIN, sq } from "./lock";

const PROBE_DIR = "/tmp/cmux-agent-tools-probe";
const WORK_DIR = `${DEVBOX_WORK_HOME}/agent-tools-probe`;
const PAGE_PORT = 18732;
export const PAGE_TITLE = "cmux agent tools probe";
const CUA_PAGE_TEXT = "cmux computer use probe";
const WORKSPACE = "agent-tools-probe";
const SESSION = "tools";
const TURN_SECONDS = 270;
const RECORDER_DIR = `${PROBE_DIR}/recorder`;
const LAUNCHES = `${PROBE_DIR}/claude-launches.txt`;
/** Ends one recorded launch (ASCII record separator on its own line). */
const RECORD_END = "\x1e";

/** Tools and skills the agent must name (Claude Code prefixes MCP tools with mcp__<server>__). */
export const REQUIRED_TOOLS = ["mcp__cmux-cua__get_desktop_state", "mcp__cmux-cua__click", "mcp__cmux__browser_repl_eval", "mcp__cmux__browser_repl_open"] as const;
export const REQUIRED_SKILLS = ["cmux:cmux-browser"] as const;
/** The same tools by server, as an MCP client lists them. */
const REQUIRED_BY_SERVER: Record<string, string[]> = { "cmux-cua": ["get_desktop_state", "click"], cmux: ["browser_repl_eval", "browser_repl_open"] };

/** Problems in the agent's tool list reply. */
export function toolListProblems(reply: string): string[] {
  return [...REQUIRED_TOOLS, ...REQUIRED_SKILLS].filter((name) => !reply.includes(name)).map((name) => `the agent does not list ${name}`);
}

export type ModelRoute = "none" | "edge";
export type ProbeOptions = { snapshotId?: string; tag: string; vmId?: string; modelRoute: ModelRoute; outDir: string };

const VALUE_FLAGS = ["--snapshot", "--tag", "--vm", "--model-route", "--out-dir"] as const;

/** Parses the probe's flags; any other flag (a token file, credentials) is refused. */
export function probeOptionsFromArgv(argv: string[]): ProbeOptions {
  const values: Record<string, string> = {};
  for (let i = 2; i < argv.length; i += 2) {
    const flag = argv[i];
    if (!(VALUE_FLAGS as readonly string[]).includes(flag)) throw new Error(`agent-tools-probe: unknown argument ${flag}; the probe takes no credential`);
    const value = argv[i + 1];
    if (value === undefined) throw new Error(`agent-tools-probe: ${flag} needs a value`);
    values[flag] = value;
  }
  const route = values["--model-route"] ?? "none";
  if (route !== "none" && route !== "edge") throw new Error("agent-tools-probe: --model-route is none or edge");
  const tag = values["--tag"];
  const snapshotId = values["--snapshot"];
  const vmId = values["--vm"];
  if (!tag || (!snapshotId?.startsWith("sh-") && !vmId) || (snapshotId && vmId)) throw new Error("usage: agent-tools-probe.ts (--snapshot <sh-id> | --vm <provider vm id>) --tag <tag> [--model-route none|edge] [--out-dir <dir>]");
  if (route === "edge" && !vmId) throw new Error("agent-tools-probe: --model-route edge needs --vm (a machine the backend created has the coderouter edge; a raw clone does not)");
  return { snapshotId, tag, vmId, modelRoute: route, outDir: path.resolve(values["--out-dir"] ?? `cmux-vm-image-out/${tag}-agenttools`) };
}

/** Whether the agent step runs: only through the machine's own coderouter edge. */
export function agentStepPlan(options: Pick<ProbeOptions, "modelRoute" | "vmId">): { run: boolean; status: "RUN" | "UNVERIFIED"; reason: string } {
  if (options.modelRoute === "edge" && options.vmId) return { run: true, status: "RUN", reason: "the agent reaches the model through the machine's coderouter edge" };
  return { run: false, status: "UNVERIFIED", reason: "no model route: a raw clone has no coderouter edge and the probe takes no credential; the tools acpmux attaches are checked without a model" };
}

/** A `claude` stand-in that appends its command line (one argument per line, then RECORD_END) to `out`. */
export function recorderScript(out: string): string {
  return [
    "#!/bin/sh",
    "# cmux agent tools probe: records the launch acpmux makes; calls no model.",
    `{ for a in "$@"; do printf '%s\\n' "$a"; done; printf '\\036\\n'; } >> ${sq(out)}`,
    `if [ "\${1:-}" = --version ]; then echo "2.1.267 (Claude Code)"; exit 0; fi`,
    `echo "cmux agent tools probe: recorder, no model" >&2`,
    "exit 3",
    "",
  ].join("\n");
}

export type RecordedServer = { name: string; command: string; args: string[]; env: Record<string, string> };

/** The last recorded launch that carries `--mcp-config`: its servers and its `--plugin-dir`. */
export function parseRecordedLaunch(text: string): { servers: RecordedServer[]; pluginDir?: string } {
  const launches = text.split(`${RECORD_END}\n`).map((block) => block.split("\n").filter((line, i, all) => i < all.length - 1 || line !== ""));
  const launch = launches.reverse().find((args) => args.includes("--mcp-config"));
  if (!launch) return { servers: [] };
  const config = JSON.parse(launch[launch.indexOf("--mcp-config") + 1] ?? "{}") as { mcpServers?: Record<string, { command: string; args?: string[]; env?: Record<string, string> }> };
  const servers = Object.entries(config.mcpServers ?? {}).map(([name, s]) => ({ name, command: s.command, args: s.args ?? [], env: s.env ?? {} }));
  const plugin = launch.indexOf("--plugin-dir");
  return { servers, pluginDir: plugin >= 0 ? launch[plugin + 1] : undefined };
}

/**
 * MCP client over stdio (python3 on the image): starts one server from a spec file, initializes,
 * lists tools, runs `before_calls` (a shell command), makes `calls`, and writes a JSON report.
 * A PNG path in a call's text is copied to `copy_png_to`.
 */
const MCP_CLIENT_PY = String.raw`import json, os, re, select, shutil, subprocess, sys, time
spec = json.load(open(sys.argv[1]))
env = dict(os.environ); env.update(spec.get("env", {}))
p = subprocess.Popen([spec["command"], *spec["args"]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(spec["stderr"], "wb"), env=env)
buf = b""
def rpc(i, method, params, timeout=120):
    global buf
    p.stdin.write((json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n").encode()); p.stdin.flush()
    end = time.time() + timeout
    while time.time() < end:
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try: msg = json.loads(line)
            except Exception: continue
            if msg.get("id") == i: return msg
        r, _, _ = select.select([p.stdout], [], [], 1)
        if r:
            chunk = os.read(p.stdout.fileno(), 1 << 20)
            if not chunk: return {"error": "server closed"}
            buf += chunk
    return {"error": "timeout"}
report = {"server": spec["name"], "tools": [], "calls": []}
init = rpc(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "cmux-agent-tools-probe", "version": "1"}})
report["initialize"] = "ok" if "result" in init else str(init.get("error"))[:300]
p.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n'); p.stdin.flush()
tools = rpc(2, "tools/list", {})
report["tools"] = [t["name"] for t in tools.get("result", {}).get("tools", [])]
if spec.get("before_calls"): subprocess.run(spec["before_calls"], shell=True)
for n, call in enumerate(spec.get("calls", [])):
    res = rpc(10 + n, "tools/call", {"name": call["name"], "arguments": call["arguments"]}, 180)
    body = res.get("result", {})
    text = " ".join(c.get("text", "") for c in body.get("content", []) if c.get("type") == "text")
    entry = {"name": call["name"], "isError": bool(body.get("isError")) or "error" in res, "expect_error": bool(call.get("expect_error")), "text": (text or str(res.get("error", "")))[:1500]}
    m = re.search(r"(/[^\s\"']+\.png)", text)
    if call.get("copy_png_to") and m and os.path.exists(m.group(1)):
        shutil.copy(m.group(1), call["copy_png_to"]); entry["copied"] = call["copy_png_to"]
    report["calls"].append(entry)
json.dump(report, open(spec["out"], "w"))
p.stdin.close()
try: p.wait(10)
except Exception: p.kill()
`;

/** A shell file run in a daemon terminal: `body` in the work folder, then the done file. */
export function terminalScript(name: string, body: string): string {
  return [`mkdir -p ${WORK_DIR} && cd ${WORK_DIR}`, body, `echo done > ${PROBE_DIR}/${name}.done`, ""].join("\n");
}

export const LIST_PROMPT = "List every MCP server you are connected to and the exact names of all tools whose names start with mcp__, one per line. Then list every skill whose name starts with cmux:. Do not call any tool.";

export function screenshotPrompt(pageUrl: string): string {
  return [
    `Do these two things with your MCP tools, then report. 1) Browser: call mcp__cmux__browser_repl_eval with session "agent" and code: await page.goto(${JSON.stringify(pageUrl)}); console.log(await page.title()); screenshot() .`,
    `Printing an image saves it to a file and prints its path; copy that PNG to ${WORK_DIR}/agent-browser.png with Bash.`,
    "2) Computer use: I explicitly ask you to use cmux Computer Use through the mcp__cmux-cua__ tools.",
    `Take a screenshot of the whole display of this machine (capture the desktop, not one window) and save the PNG to ${WORK_DIR}/agent-cua.png (use a screenshot_out_file argument if a tool offers one), and report the screen size.`,
    "End your reply with the line RESULT browser=<ok|failed> cua=<ok|failed>.",
  ].join(" ");
}

/** Static image checks: the tool dir, the wrapper, the units (off), cmux.json, the daemon env, the browser role. */
export function staticCheckCommand(): string {
  return [
    `test "$(readlink ${AGENT_TOOLS_BIN}/cmux)" = ${CURRENT_BIN}/cmux-tui && echo cmux-link=ok`,
    `grep -q 'systemctl start ${CUA_UNIT}' ${AGENT_TOOLS_BIN}/cmux-cua && echo cua-wrapper=ok`,
    `for u in ${DISPLAY_UNIT} ${CUA_UNIT}; do echo "unit-$u=$(systemctl is-active $u)"; done`,
    `echo "mcp-enabled=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mcp"]["enabled"])' ${WORK_USER_CMUX_JSON})"`,
    `p=$(pgrep -f 'cmux-tui server [s]tart' | head -1); tr '\\0' '\\n' < /proc/$p/environ | grep -E '^CMUX_(AGENT_TOOLS_BIN_DIR|BROWSER_HOST_BIN|BROWSER_HOST_CHROMIUM)=' | sort | sed 's/^/env-/'`,
    `for v in CMUX_BROWSER_HOST_BIN CMUX_BROWSER_HOST_CHROMIUM; do f=$(tr '\\0' '\\n' < /proc/$p/environ | sed -n "s/^$v=//p"); test -x "$f" && echo "exists-$v=ok"; done`,
    `${CURRENT_BIN}/cmux-tui --version | sed 's/^/version=/'`,
  ].join("; ");
}

const kv = (text: string) => Object.fromEntries(text.split("\n").filter((l) => /^[a-zA-Z0-9_.-]+=/.test(l)).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));

export type Check = { ok: boolean; detail: string; status?: "UNVERIFIED" };
export type ProbeResult = { checks: Record<string, Check>; timings: Record<string, number>; files: string[] };

/** Runs `script` in a terminal of the machine's daemon as the work user and waits (bounded) for its done file. */
async function inTerminal(vm: Vm, name: string, script: string, waitSeconds: number): Promise<number> {
  const t0 = Date.now();
  await vm.fs.writeFile(`${PROBE_DIR}/${name}.sh`, script, { mode: 0o644 });
  const C = `${CURRENT_BIN}/cmux-tui --session cloud`;
  const start = await run(vm, `${C} workspace name:${WORKSPACE} run --on-exit keep shell ${sq(`. ${PROBE_DIR}/${name}.sh`)} >/dev/null`, 60_000, DEVBOX_WORK_USER);
  if (start.code !== 0) throw new Error(`terminal run ${name}: ${start.stderr.slice(-300)}`);
  // One exec may last at most 5 minutes: wait in slices of at most 240 s.
  for (let left = waitSeconds; left > 0; left -= 240) {
    const slice = Math.min(left, 240);
    const wait = await run(vm, `for i in $(seq 1 ${slice}); do [ -e ${PROBE_DIR}/${name}.done ] && exit 0; sleep 1; done; exit 1`, (slice + 20) * 1000, DEVBOX_WORK_USER);
    if (wait.code === 0) return Date.now() - t0;
  }
  throw new Error(`terminal script ${name} did not finish within ${waitSeconds} s`);
}

async function readGuest(vm: Vm, file: string): Promise<string> {
  return new TextDecoder().decode(await vm.fs.readFile(file));
}

type Checker = (name: string, ok: boolean, detail: string) => void;

/** Copies a PNG from the machine into the out dir and checks it. */
async function pngCheck(vm: Vm, check: Checker, result: ProbeResult, outDir: string, name: string): Promise<void> {
  const file = path.join(outDir, `${name}.png`);
  try {
    const bytes = Buffer.from(await vm.fs.readFile(`${WORK_DIR}/${name}.png`));
    writeFileSync(file, bytes);
    result.files.push(file);
    const png = bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
    check(`${name}-screenshot`, png && bytes.length > 2000, `${bytes.length} bytes, ${png ? "PNG" : "not a PNG"}, ${png ? `${bytes.readUInt32BE(16)}x${bytes.readUInt32BE(20)}` : ""}`);
  } catch (error) {
    check(`${name}-screenshot`, false, String(error).slice(0, 200));
  }
}

/** Static checks, the probe folder, the loopback pages and the probe workspace. */
async function prepare(vm: Vm, check: Checker, result: ProbeResult): Promise<boolean> {
  const s = kv((await run(vm, staticCheckCommand())).stdout);
  check("tool-dir", s["cmux-link"] === "ok" && s["cua-wrapper"] === "ok", JSON.stringify({ cmux: s["cmux-link"], wrapper: s["cua-wrapper"] }));
  check("display-and-cua-off-until-asked", s[`unit-${DISPLAY_UNIT}`] === "inactive" && s[`unit-${CUA_UNIT}`] === "inactive", `${s[`unit-${DISPLAY_UNIT}`]} ${s[`unit-${CUA_UNIT}`]}`);
  check("mcp-enabled", s["mcp-enabled"] === "True", `cmux.json mcp.enabled=${s["mcp-enabled"]}`);
  check("daemon-env", s["env-CMUX_AGENT_TOOLS_BIN_DIR"] === AGENT_TOOLS_BIN && s["exists-CMUX_BROWSER_HOST_BIN"] === "ok" && s["exists-CMUX_BROWSER_HOST_CHROMIUM"] === "ok", JSON.stringify({ bin: s["env-CMUX_AGENT_TOOLS_BIN_DIR"], host: s["exists-CMUX_BROWSER_HOST_BIN"], chrome: s["exists-CMUX_BROWSER_HOST_CHROMIUM"] }));
  result.checks.version = { ok: true, detail: s.version ?? "" };
  await run(vm, `install -d -m 0700 -o ${DEVBOX_WORK_USER} -g ${DEVBOX_WORK_USER} ${PROBE_DIR} ${PROBE_DIR}/www ${RECORDER_DIR}`);
  await vm.fs.writeFile(`${PROBE_DIR}/www/index.html`, `<!doctype html><title>${PAGE_TITLE}</title><h1>${PAGE_TITLE}</h1>`, { mode: 0o644 });
  await vm.fs.writeFile(`${PROBE_DIR}/www/cua.html`, `<!doctype html><title>${CUA_PAGE_TEXT}</title><body style="background:#2d8cff;color:#fff;font:64px sans-serif"><h1>${CUA_PAGE_TEXT}</h1>`, { mode: 0o644 });
  await vm.fs.writeFile(`${RECORDER_DIR}/claude`, recorderScript(LAUNCHES), { mode: 0o755 });
  await vm.fs.writeFile(`${PROBE_DIR}/mcp-client.py`, MCP_CLIENT_PY, { mode: 0o644 });
  await run(vm, `chown -R ${DEVBOX_WORK_USER}:${DEVBOX_WORK_USER} ${PROBE_DIR}`);
  await run(vm, `setsid python3 -m http.server ${PAGE_PORT} --bind 127.0.0.1 --directory ${PROBE_DIR}/www >${PROBE_DIR}/www.log 2>&1 < /dev/null & echo started`, 30_000, DEVBOX_WORK_USER);
  const C = `${CURRENT_BIN}/cmux-tui --session cloud`;
  const ws = await run(vm, `${C} workspace name:${WORKSPACE} show >/dev/null 2>&1 || ${C} workspace create --name ${WORKSPACE} >/dev/null && echo ok`, 60_000, DEVBOX_WORK_USER);
  check("daemon-terminal", ws.code === 0, ws.stdout.trim() || ws.stderr.slice(-300));
  return ws.code === 0;
}

/** The launch acpmux builds for a Claude Code session, captured by the recorder (no model). */
async function recordLaunch(vm: Vm, check: Checker, result: ProbeResult, outDir: string): Promise<RecordedServer[]> {
  const body = [
    `export ACPMUX_HOME=${PROBE_DIR}/acpmux-recorder PATH=${RECORDER_DIR}:$PATH`,
    `{ ${CURRENT_BIN}/cmux-tui acp new -d -m claude -n recorder --cwd ${WORK_DIR}; echo "exit $?"; } > ${PROBE_DIR}/recorder-new.txt 2>&1`,
    `{ timeout 60 ${CURRENT_BIN}/cmux-tui acp send recorder hello; echo "exit $?"; } > ${PROBE_DIR}/recorder-send.txt 2>&1`,
    `{ timeout 60 ${CURRENT_BIN}/cmux-tui acp daemon shutdown; echo "exit $?"; } > ${PROBE_DIR}/recorder-shutdown.txt 2>&1`,
  ].join("\n");
  result.timings.recordMs = await inTerminal(vm, "record", terminalScript("record", body), 180);
  let text = "";
  try {
    text = await readGuest(vm, LAUNCHES);
  } catch {
    text = "";
  }
  writeFileSync(path.join(outDir, "claude-launches.txt"), text);
  const launch = parseRecordedLaunch(text);
  const names = launch.servers.map((s) => `${s.name}=${s.command} ${s.args.join(" ")}`);
  check("acpmux-attaches-servers", ["cmux-cua", "cmux"].every((n) => launch.servers.some((s) => s.name === n && s.command.startsWith(`${AGENT_TOOLS_BIN}/`))), names.join("; ") || "no launch with --mcp-config was recorded");
  const skills = launch.pluginDir ? await run(vm, `ls ${sq(`${launch.pluginDir}/skills`)} && test -s ${sq(`${launch.pluginDir}/skills/cmux-browser/SKILL.md`)} && echo skill-ok`) : { stdout: "", code: 1 };
  check("acpmux-attaches-skills", skills.stdout.includes("skill-ok"), `plugin dir ${launch.pluginDir ?? "absent"}: ${skills.stdout.trim().replace(/\n/g, " ")}`);
  return launch.servers;
}

/** Starts a Chrome window on the agent display (sandbox on). */
function displayWindowCommand(page: string): string {
  return [
    `export DISPLAY=${AGENT_DISPLAY} XAUTHORITY=${AGENT_XAUTHORITY} $(tr '\\0' '\\n' < /proc/$(pgrep -f 'cmux-tui server [s]tart' | head -1)/environ | grep '^CMUX_BROWSER_HOST_CHROMIUM=')`,
    `setsid "$CMUX_BROWSER_HOST_CHROMIUM" --no-first-run --user-data-dir=${PROBE_DIR}/chrome-profile --window-position=0,0 --window-size=1280,800 --app=${page} >${PROBE_DIR}/chrome.log 2>&1 < /dev/null &`,
    "sleep 5",
  ].join("\n");
}

/** Each recorded server started as acpmux would start it, from a daemon terminal; tools listed and called. */
async function callServers(vm: Vm, check: Checker, result: ProbeResult, outDir: string, servers: RecordedServer[]): Promise<void> {
  const calls: Record<string, { before?: string; calls: unknown[] }> = {
    "cmux-cua": {
      before: displayWindowCommand(`http://127.0.0.1:${PAGE_PORT}/cua.html`),
      calls: [
        { name: "set_config", arguments: { capture_scope: "desktop" } },
        { name: "get_desktop_state", arguments: { screenshot_out_file: `${WORK_DIR}/cua.png` } },
        // Role cua-video stays off: the driver must refuse to install ffmpeg (agent-tools.ts CUA_REFUSE_DIR).
        { name: "install_ffmpeg", arguments: { confirm: true }, expect_error: true },
      ],
    },
    cmux: { calls: [{ name: "browser_repl_eval", arguments: { session: "probe", code: `await page.goto(${JSON.stringify(`http://127.0.0.1:${PAGE_PORT}/`)}); console.log(await page.title()); screenshot()` }, copy_png_to: `${WORK_DIR}/browser.png` }] },
  };
  const lines: string[] = [];
  for (const server of servers.filter((s) => s.name in calls)) {
    const spec = { ...server, stderr: `${PROBE_DIR}/mcp-${server.name}.stderr`, out: `${PROBE_DIR}/mcp-${server.name}.json`, before_calls: calls[server.name].before, calls: calls[server.name].calls };
    await vm.fs.writeFile(`${PROBE_DIR}/mcp-${server.name}.spec.json`, JSON.stringify(spec), { mode: 0o644 });
    lines.push(`timeout 280 python3 ${PROBE_DIR}/mcp-client.py ${PROBE_DIR}/mcp-${server.name}.spec.json`);
  }
  await run(vm, `chown -R ${DEVBOX_WORK_USER}:${DEVBOX_WORK_USER} ${PROBE_DIR}`);
  result.timings.mcpMs = await inTerminal(vm, "mcp", terminalScript("mcp", lines.join("\n")), 600);
  for (const name of Object.keys(calls)) {
    let report: { tools: string[]; initialize: string; calls: Array<{ name: string; isError: boolean; text: string; expect_error?: boolean }> } | null = null;
    try {
      report = JSON.parse(await readGuest(vm, `${PROBE_DIR}/mcp-${name}.json`));
    } catch (error) {
      check(`mcp-${name}`, false, `no report: ${String(error).slice(0, 160)}`);
      continue;
    }
    writeFileSync(path.join(outDir, `mcp-${name}.json`), JSON.stringify(report, null, 2));
    const missing = REQUIRED_BY_SERVER[name].filter((t) => !report.tools.includes(t));
    check(`mcp-${name}-tools`, report.initialize === "ok" && missing.length === 0, missing.length ? `missing ${missing.join(", ")}` : `${report.tools.length} tools, including ${REQUIRED_BY_SERVER[name].join(", ")}`);
    const failed = report.calls.filter((c) => c.isError !== (c.expect_error === true));
    check(`mcp-${name}-calls`, report.calls.length > 0 && failed.length === 0, report.calls.map((c) => `${c.name}: ${c.isError ? "error " : ""}${c.text.slice(0, 160)}`).join(" | "));
  }
  const cuaReport = await readGuest(vm, `${PROBE_DIR}/mcp-cmux-cua.json`).catch(() => "");
  const ffmpeg = await run(vm, "command -v ffmpeg; dpkg-query -W -f='${Status}' ffmpeg libx264-164 2>/dev/null | grep -c 'ok installed' || true");
  check("cua-video-refused", cuaReport.includes("cua-video") && ffmpeg.stdout.trim() === "0", `install_ffmpeg ${cuaReport.includes("cua-video") ? "refused with the cua-video message" : "was not refused"}; ffmpeg/libx264 installed packages: ${ffmpeg.stdout.trim()}`);
  const units = await run(vm, `systemctl is-active ${DISPLAY_UNIT} ${CUA_UNIT} | tr '\\n' ' '`);
  check("display-and-cua-started-by-cmux-cua-mcp", units.stdout.trim() === "active active", units.stdout.trim());
  const mcpBrowser = await readGuest(vm, `${PROBE_DIR}/mcp-cmux.json`).catch(() => "");
  check("browser-page-title", mcpBrowser.includes(PAGE_TITLE), `the browser host ${mcpBrowser.includes(PAGE_TITLE) ? "returned" : "did not return"} "${PAGE_TITLE}"`);
  await pngCheck(vm, check, result, outDir, "browser");
  await pngCheck(vm, check, result, outDir, "cua");
  const host = await run(vm, `pgrep -u ${DEVBOX_WORK_USER} -f '[c]mux-browser-host serve' | wc -l; tr '\\0' ' ' < /proc/$(pgrep -u ${DEVBOX_WORK_USER} -f '[c]hrome-linux64/chrome' | head -1)/cmdline 2>/dev/null | grep -cE -- '--no-sandbox|--disable-setuid-sandbox' || true`);
  const [hosts, sandboxOff] = host.stdout.trim().split("\n");
  check("browser-host-socket-activated-sandbox-on", Number(hosts) >= 1 && sandboxOff === "0", `hosts=${hosts} sandbox-off-switches=${sandboxOff}`);
}

/** The agent itself, through the machine's own model route (no credential is written). */
async function agentStep(vm: Vm, check: Checker, result: ProbeResult, outDir: string): Promise<void> {
  const list = terminalScript("list", [
    `{ ${CURRENT_BIN}/cmux-tui acp new -d -m claude -n ${SESSION} --cwd ${WORK_DIR} --policy approve-all; echo "exit $?"; } > ${PROBE_DIR}/new.txt 2>&1`,
    `{ timeout ${TURN_SECONDS} ${CURRENT_BIN}/cmux-tui acp send ${SESSION} ${sq(LIST_PROMPT)}; echo "exit $?"; } > ${PROBE_DIR}/list.txt 2>&1`,
  ].join("\n"));
  result.timings.listMs = await inTerminal(vm, "list", list, TURN_SECONDS + 30);
  const listReply = await readGuest(vm, `${PROBE_DIR}/list.txt`);
  writeFileSync(path.join(outDir, "list.txt"), listReply);
  const problems = toolListProblems(listReply);
  check("agent-lists-tools", problems.length === 0, problems.join("; ") || `${new Set(listReply.match(/mcp__[A-Za-z0-9_-]+/g) ?? []).size} mcp__ tools named`);
  const shots = terminalScript("shots", `{ timeout ${TURN_SECONDS} ${CURRENT_BIN}/cmux-tui acp send ${SESSION} ${sq(screenshotPrompt(`http://127.0.0.1:${PAGE_PORT}/`))}; echo "exit $?"; } > ${PROBE_DIR}/shots.txt 2>&1`);
  result.timings.shotsMs = await inTerminal(vm, "shots", shots, TURN_SECONDS + 30);
  const reply = await readGuest(vm, `${PROBE_DIR}/shots.txt`);
  writeFileSync(path.join(outDir, "shots.txt"), reply);
  check("agent-reports-both", /RESULT browser=ok cua=ok/.test(reply), reply.trim().split("\n").slice(-3).join(" | "));
  await pngCheck(vm, check, result, outDir, "agent-browser");
  await pngCheck(vm, check, result, outDir, "agent-cua");
}

export async function agentToolsProbe(vm: Vm, options: ProbeOptions): Promise<ProbeResult> {
  const result: ProbeResult = { checks: {}, timings: {}, files: [] };
  const check: Checker = (name, ok, detail) => {
    result.checks[name] = { ok, detail };
    console.log(`${ok ? "PASS" : "FAIL"} ${name}: ${detail.slice(0, 500)}`);
  };
  if (!(await prepare(vm, check, result))) return result;
  const servers = await recordLaunch(vm, check, result, options.outDir);
  await callServers(vm, check, result, options.outDir, servers);
  const plan = agentStepPlan(options);
  if (plan.run) await agentStep(vm, check, result, options.outDir);
  else {
    result.checks["agent-in-vm"] = { ok: true, status: "UNVERIFIED", detail: plan.reason };
    console.log(`UNVERIFIED agent-in-vm: ${plan.reason}`);
  }
  return result;
}

export async function main(argv = process.argv): Promise<number> {
  const options = probeOptionsFromArgv(argv);
  mkdirSync(options.outDir, { recursive: true });
  const fs = freestyleClient();
  const ledger = new Ledger(path.join(options.outDir, "resources.tsv"));
  const name = `cmuxnp-dev-vmimg-${options.tag}-agenttools`;
  let vm: Vm;
  let vmId: string;
  let t0 = Date.now();
  if (options.vmId) {
    vmId = options.vmId;
    vm = fs.vms.ref(vmId) as unknown as Vm;
    console.log(`VM ${vmId} (existing; not created or deleted by the probe)`);
  } else {
    ({ vm, vmId, t0 } = await createVm(fs, ledger, { name, snapshotId: options.snapshotId! }));
    console.log(`VM ${vmId} (${name}) from ${options.snapshotId}`);
  }
  let result: ProbeResult | null = null;
  let error: string | null = null;
  try {
    await firstExec(vm, t0);
    result = await agentToolsProbe(vm, options);
  } catch (e) {
    error = String(e);
    console.error(`AGENT TOOLS PROBE FAILED: ${error}`);
  } finally {
    if (!options.vmId) await deleteVm(vm, vmId, name, ledger);
  }
  let gone = "kept (existing machine)";
  if (!options.vmId) {
    try {
      await fs.vms.get(vmId);
      gone = "still exists";
    } catch (e) {
      gone = String(e).slice(0, 160);
    }
    console.log(`after delete, get ${vmId}: ${gone}`);
  }
  const deleted = options.vmId ? true : /not found/i.test(gone);
  const checks = Object.values(result?.checks ?? {});
  const passed = !error && deleted && result !== null && checks.every((c) => c.ok);
  const unverified = Object.entries(result?.checks ?? {}).filter(([, c]) => c.status === "UNVERIFIED").map(([n]) => n);
  writeFileSync(path.join(options.outDir, `agent-tools-probe-${options.tag}.json`), `${JSON.stringify({ snapshotId: options.snapshotId, vmId, deleted, afterDelete: gone, passed, unverified, error, ...result }, null, 2)}\n`);
  console.log(passed ? `AGENT TOOLS PROBE PASSED${unverified.length ? ` (UNVERIFIED: ${unverified.join(", ")})` : ""}` : "AGENT TOOLS PROBE FAILED");
  return passed ? 0 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(await main());
