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
 *    screenshot of a loopback page (the daemon socket-activates the host), and Computer Use takes
 *    a screenshot of the Xvfb display with a Chrome window on it and lists that window. Computer Use
 *    is the server the image's acpmux attaches: `cmux-computer-use` (cmux-tui since #37003, whose
 *    first call makes the daemon start its worker, which runs the machine's desktop starter for the
 *    display), or `cmux-cua` before it (whose wrapper starts the display).
 * 3. Desktop (role desktop): the cmux-rd host's user, run dir and socket; another user cannot
 *    connect (EACCES); a connection as the work user (the link receiver's uid) starts the host,
 *    which runs as its own user with Unix sockets only and no TCP or UDP socket; the work user
 *    cannot read the host's cookie copy.
 * 4. The agent step (a Claude Code session that lists the tools and takes both screenshots
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
import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { DEVBOX_WORK_HOME, DEVBOX_WORK_USER } from "../../services/vms/workUser";
import { A11Y_TEMPLATE_UNIT, A11Y_UNIT, AGENT_DISPLAY, AGENT_DISPLAY_SIZE, AGENT_TOOLS_BIN, CUA_REFUSE_DIR, DESKTOP_CHECK_SCRIPT, DESKTOP_CHECK_SECONDS, DESKTOP_SESSION_UNIT, DESKTOP_STARTER, AGENT_XAUTHORITY, CUA_UNIT, DISPLAY_TEMPLATE_UNIT, DISPLAY_UNIT, NO_NEW_PRIVS_ENV, RD_HOST_DIR, RD_PEER_UID, RD_RUN_DIR, RD_SOCKET, RD_SOCKET_UNIT, RD_START_SCRIPT, RD_UNIT, RD_USER, RD_XAUTHORITY, WORK_USER_CMUX_JSON } from "./agent-tools";
import { createVm, deleteVm, firstExec, freestyleClient, Ledger, run, type Vm } from "./guest";
import { BROWSER_CHECKS, checkRegressionGate, ensureOutputFile, harnessEnsureScript, LIVE_FAILING_FILE, liveBootImage, liveFailingLines, pickerHarnesses, regressionGate } from "./harness-gate";
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
/** The launch acpmux makes by default, with its MCP gateway on (acpmux mcp_gateway.rs, #48374). */
const GATEWAY_LAUNCHES = `${PROBE_DIR}/claude-launches-gateway.txt`;
/** The recorder for the gateway launch: its own directory, so the two launches land in their own files. */
const GATEWAY_RECORDER_DIR = `${PROBE_DIR}/recorder-gateway`;
/** Ends one recorded launch (ASCII record separator on its own line). */
const RECORD_END = "\x1e";
/** Prefixes the recorded contents of the launch's --mcp-config file (the recorder's last line before RECORD_END). */
const MCP_CONFIG_LINE = "MCP_CONFIG_FILE ";
/** acpmux folds every other server into the cmux server's env under this name (acpmux agent_tools.rs UPSTREAMS_ENV). */
const UPSTREAMS_ENV = "CMUX_MCP_UPSTREAMS";

/** cmux-tui's Computer Use server (acpmux `computer-use-mcp`, since #37003). */
export const CU_SERVER = "cmux-computer-use";
/** The Computer Use server of an image whose cmux-tui predates #37003 (the cmux-cua proxy). */
export const LEGACY_CU_SERVER = "cmux-cua";
/** The worker the cmux-tui daemon starts for CU_SERVER (cmux-tui-core computer_use_host.rs WORKER_MODE). */
const CU_WORKER_MODE = "__computer-use-worker";

/** Tools and skills the agent must name (Claude Code prefixes MCP tools with mcp__<server>__). */
export const REQUIRED_TOOLS = [`mcp__${CU_SERVER}__screenshot`, `mcp__${CU_SERVER}__click`, "mcp__cmux__browser_repl_eval", "mcp__cmux__browser_repl_open"] as const;
export const REQUIRED_SKILLS = ["cmux:cmux-browser"] as const;
/** The same tools by server, as an MCP client lists them. */
const REQUIRED_BY_SERVER: Record<string, string[]> = {
  [CU_SERVER]: ["screenshot", "list_windows", "click", "type_text", "get_ui_tree"],
  [LEGACY_CU_SERVER]: ["get_desktop_state", "click"],
  cmux: ["browser_repl_eval", "browser_repl_open"],
};

/**
 * The Computer Use server among `servers`, as acpmux attached it: CU_SERVER from the image's own
 * cmux-tui (the acpmux binary, `computer-use-mcp`), else LEGACY_CU_SERVER through the image's
 * wrapper in AGENT_TOOLS_BIN; `ok` is false for one attached any other way. Null when none is.
 */
export function attachedComputerUse(servers: readonly RecordedServer[]): { name: string; ok: boolean; legacy: boolean } | null {
  const cu = servers.find((s) => s.name === CU_SERVER);
  if (cu) return { name: CU_SERVER, ok: /\/cmux-tui$/.test(cu.command) && cu.args.includes("computer-use-mcp"), legacy: false };
  const legacy = servers.find((s) => s.name === LEGACY_CU_SERVER);
  if (legacy) return { name: LEGACY_CU_SERVER, ok: legacy.command.startsWith(`${AGENT_TOOLS_BIN}/`), legacy: true };
  return null;
}

/**
 * Problems with the `cmux` server of the default launch: acpmux (#48374) serves it from the daemon's
 * MCP gateway as loopback HTTP (`/mcp/<session>`, or its `/tools` and `/tools/<server>` endpoints, mcp_gateway.rs);
 * a stdio `cmux` from the tool dir is also right
 * (an acpmux without the gateway). Empty when it is attached one of those ways.
 */
export function gatewayProblems(servers: readonly RecordedServer[]): string[] {
  const cmux = servers.find((s) => s.name === "cmux");
  if (!cmux) return ["no cmux server"];
  if (cmux.url === undefined) return cmux.command.startsWith(`${AGENT_TOOLS_BIN}/`) ? [] : [`cmux attached as ${cmux.command || "nothing"}`];
  let url: URL;
  try {
    url = new URL(cmux.url);
  } catch {
    return [`cmux url ${cmux.url} is not a URL`];
  }
  const problems: string[] = [];
  if (!["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)) problems.push(`cmux url ${cmux.url} is not loopback`);
  if (!/^\/mcp\/[^/]+(\/tools(\/[^/]+)?)?$/.test(url.pathname)) problems.push(`cmux url ${cmux.url} is not a gateway tool endpoint`);
  return problems;
}

/**
 * Tools of a Computer Use server that would record video or install software: role cua-video (ffmpeg,
 * libx264) stays off on cmux machines, so CU_SERVER must list none. One exception: cmux-computer-use's
 * `record` tool (#50070) encodes with the desktop's own H.264 encoder, which only the macOS worker has, so
 * on a cmux machine it is listed but refused. It passes when `recordCall` (the probe's call to it) was
 * refused as unsupported.
 */
export function videoToolProblems(tools: readonly string[], recordCall?: { isError: boolean; text: string }): string[] {
  const recordRefused = recordCall !== undefined && recordCall.isError && /unsupported|H\.264 encoder/i.test(recordCall.text);
  return tools.filter((t) => /ffmpeg|video|record|install/i.test(t) && !(t === "record" && recordRefused)).map((t) => `lists ${t}`);
}
/**
 * The tools server NAME must list, as acpmux launched it (`args`). In code mode (no `--all-tools`, acpmux
 * agent_tools.rs `listing`) the cmux server lists only cmux_exec and cmux_workflow; its tools still answer a
 * direct call, which mcp-cmux-calls checks.
 */
export function requiredTools(name: string, args: readonly string[]): string[] {
  if (name === "cmux" && !args.includes("--all-tools")) return ["cmux_exec"];
  return REQUIRED_BY_SERVER[name] ?? [];
}

/** Problems in the agent's tool list reply. */
export function toolListProblems(reply: string): string[] {
  return [...REQUIRED_TOOLS, ...REQUIRED_SKILLS].filter((name) => !reply.includes(name)).map((name) => `the agent does not list ${name}`);
}

export type ModelRoute = "none" | "edge";
/** The harness gate's baseline: `live` also runs the ensure on a clone of production's boot image (harness-gate.ts regressionGate). */
export type Baseline = "none" | "live";
export type ProbeOptions = { snapshotId?: string; tag: string; vmId?: string; modelRoute: ModelRoute; outDir: string; baseline: Baseline };

const VALUE_FLAGS = ["--snapshot", "--tag", "--vm", "--model-route", "--out-dir", "--baseline"] as const;

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
  const baseline = values["--baseline"] ?? "none";
  if (baseline !== "none" && baseline !== "live") throw new Error("agent-tools-probe: --baseline is none or live");
  return { snapshotId, tag, vmId, modelRoute: route, outDir: path.resolve(values["--out-dir"] ?? `cmux-vm-image-out/${tag}-agenttools`), baseline };
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
    // acpmux passes --mcp-config as a 0600 file it deletes when the session ends: keep its JSON (one line) too.
    // acpmux starts its model listing (live_models) beside the chat's launch: each launch's record is built in its
    // own file and appended in one write, so two launches never interleave their lines (roll 45906244147's
    // attempt 2 had the chat's arguments and a model listing's in one record).
    `rec=${sq(out)}.$$; { cfg=; prev=; for a in "$@"; do printf '%s\\n' "$a"; [ "$prev" = --mcp-config ] && cfg="$a"; prev="$a"; done; if [ -n "$cfg" ] && [ -f "$cfg" ]; then printf '${MCP_CONFIG_LINE}%s\\n' "$(tr -d '\\n' < "$cfg")"; fi; printf '\\036\\n'; } > "$rec"; cat "$rec" >> ${sq(out)}; rm -f "$rec"`,
    `if [ "\${1:-}" = --version ]; then echo "2.1.267 (Claude Code)"; exit 0; fi`,
    `echo "cmux agent tools probe: recorder, no model" >&2`,
    "exit 3",
    "",
  ].join("\n");
}

/** A server of the launch: a stdio command, or (`url`) an HTTP server such as acpmux's gateway, with no command. */
export type RecordedServer = { name: string; command: string; args: string[]; env: Record<string, string>; url?: string };

/**
 * The last recorded chat launch that carries `--mcp-config`: its servers and its `--plugin-dir`. acpmux's model
 * listing (live_models/claude.rs) passes an empty inline `--mcp-config` under `--strict-mcp-config` and can start
 * after the chat's launch (roll 45890407908's gateway leg), so a `--strict-mcp-config` launch is never the chat's:
 * acpmux gives such a launch no tools (agent_tools.rs `left_out`).
 */
export function parseRecordedLaunch(text: string): { servers: RecordedServer[]; pluginDir?: string } {
  const launches = text.split(`${RECORD_END}\n`).map((block) => block.split("\n").filter((line, i, all) => i < all.length - 1 || line !== ""));
  const launch = launches.reverse().find((args) => args.includes("--mcp-config") && !args.includes("--strict-mcp-config"));
  if (!launch) return { servers: [] };
  // The value is a file path (acpmux writes the config to a 0600 file); an inline JSON value is read as it is.
  const value = launch[launch.indexOf("--mcp-config") + 1] ?? "";
  const fileLine = launch.find((line) => line.startsWith(MCP_CONFIG_LINE));
  const json = value.trimStart().startsWith("{") ? value : (fileLine?.slice(MCP_CONFIG_LINE.length) ?? "{}");
  const config = JSON.parse(json) as { mcpServers?: Record<string, { command?: string; args?: string[]; env?: Record<string, string>; type?: string; url?: string }> };
  const servers: RecordedServer[] = [];
  for (const [name, s] of Object.entries(config.mcpServers ?? {})) {
    const env = { ...(s.env ?? {}) };
    // Code mode: the other servers ride in the cmux server's upstreams; each is started as its own server here.
    const upstreams = env[UPSTREAMS_ENV] ? (JSON.parse(env[UPSTREAMS_ENV]) as Array<{ name: string; command: string; args?: string[]; env?: Record<string, string> }>) : [];
    servers.push({ name, command: s.command ?? "", args: s.args ?? [], env, ...(s.url ? { url: s.url } : {}) });
    for (const u of upstreams) servers.push({ name: u.name, command: u.command, args: u.args ?? [], env: u.env ?? {} });
  }
  const plugin = launch.indexOf("--plugin-dir");
  return { servers, pluginDir: plugin >= 0 ? launch[plugin + 1] : undefined };
}

/**
 * MCP client over stdio (python3 on the image): starts one server from a spec file, initializes,
 * lists tools, runs `before_calls` (a shell command), makes `calls`, and writes a JSON report.
 * A call `{shell}` runs that shell command at its place instead. A call with `until` is repeated
 * every 2 s, for up to `until_s` seconds, until its text contains `until`; the report keeps each
 * attempt's duration (`ms`). A call's PNG (an image
 * content item, else a PNG path in its text) is written to `copy_png_to`.
 */
const MCP_CLIENT_PY = String.raw`import base64, json, os, re, select, shutil, subprocess, sys, time
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
    if "shell" in call:
        subprocess.run(call["shell"], shell=True); continue
    deadline = time.time() + call.get("until_s", 0)
    ms = []
    while True:
        t0 = time.time()
        res = rpc(10 + n, "tools/call", {"name": call["name"], "arguments": call["arguments"]}, 180)
        body = res.get("result", {})
        text = " ".join(c.get("text", "") for c in body.get("content", []) if c.get("type") == "text")
        ms.append(int((time.time() - t0) * 1000))
        if not call.get("until") or call["until"] in text or time.time() >= deadline: break
        time.sleep(2)
    entry = {"name": call["name"], "isError": bool(body.get("isError")) or "error" in res, "expect_error": bool(call.get("expect_error")), "attempts": len(ms), "ms": ms, "text": (text or str(res.get("error", "")))[:1500]}
    images = [c["data"] for c in body.get("content", []) if c.get("type") == "image" and c.get("data")]
    m = re.search(r"(/[^\s\"']+\.png)", text)
    if call.get("copy_png_to") and images:
        open(call["copy_png_to"], "wb").write(base64.b64decode(images[0])); entry["copied"] = call["copy_png_to"]
    elif call.get("copy_png_to") and m and os.path.exists(m.group(1)):
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
    `2) Computer use: I explicitly ask you to use cmux Computer Use through the mcp__${CU_SERVER}__ tools.`,
    `Take a screenshot of the whole display of this machine (capture the display, not one window), save the PNG to ${WORK_DIR}/agent-cua.png, and report the screen size.`,
    "End your reply with the line RESULT browser=<ok|failed> cua=<ok|failed>.",
  ].join(" ");
}

/** Static image checks: the tool dir, the wrapper, the units (off), cmux.json, the daemon env, the browser role. */
export function staticCheckCommand(): string {
  return [
    `test "$(readlink ${AGENT_TOOLS_BIN}/cmux)" = ${CURRENT_BIN}/cmux-tui && echo cmux-link=ok`,
    `grep -q 'systemctl start ${CUA_UNIT}' ${AGENT_TOOLS_BIN}/cmux-cua && echo cua-wrapper=ok`,
    `echo "starter=$(stat -c '%U:%G:%a' ${DESKTOP_STARTER} /etc/cmux 2>/dev/null | tr '\\n' ' ')"`,
    `sh -n ${DESKTOP_STARTER} 2>/dev/null && grep -q 'systemctl start ${DISPLAY_UNIT}' ${DESKTOP_STARTER} && echo starter-script=ok`,
    `for u in ${DISPLAY_UNIT} ${CUA_UNIT} ${A11Y_UNIT}; do echo "unit-$u=$(systemctl is-active $u)"; done`,
    `for u in ${DISPLAY_TEMPLATE_UNIT} ${A11Y_TEMPLATE_UNIT}; do systemctl cat $u >/dev/null 2>&1 && echo "template-$u=ok"; done`,
    `for u in ${DISPLAY_TEMPLATE_UNIT.replace("@", "@1")} ${A11Y_TEMPLATE_UNIT.replace("@", "@1")}; do echo "unit-$u=$(systemctl is-active $u)"; done`,
    `echo "mcp-enabled=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mcp"]["enabled"])' ${WORK_USER_CMUX_JSON})"`,
    `p=$(pgrep -f 'cmux-tui server [s]tart' | head -1); tr '\\0' '\\n' < /proc/$p/environ | grep -E '^CMUX_(AGENT_TOOLS_BIN_DIR|BROWSER_HOST_BIN|BROWSER_HOST_CHROMIUM)=' | sort | sed 's/^/env-/'`,
    `for v in CMUX_BROWSER_HOST_BIN CMUX_BROWSER_HOST_CHROMIUM; do f=$(tr '\\0' '\\n' < /proc/$p/environ | sed -n "s/^$v=//p"); test -x "$f" && echo "exists-$v=ok"; done`,
    `${CURRENT_BIN}/cmux-tui --version | sed 's/^/version=/'`,
  ].join("; ");
}

const kv = (text: string) => Object.fromEntries(text.split("\n").filter((l) => /^[a-zA-Z0-9_.@-]+=/.test(l)).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));

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

/** The fewest pixels on a screenshot's long edge for it to count as the display (cmux-computer-use sends at most 1456). */
export const MIN_SCREENSHOT_EDGE = 1024;

/**
 * Whether a `WxH` screenshot shows the whole `WxH` display: the same size (cmux-cua), or the display scaled down
 * whole (cmux-computer-use scales its long edge to at most 1456 px) with the same aspect, to rounding, and a long
 * edge of at least MIN_SCREENSHOT_EDGE. A crop, a window-sized shot or a thumbnail does not.
 */
export function screenshotShowsDisplay(dims: string, display: string): boolean {
  const parse = (v: string) => /^(\d+)x(\d+)$/u.exec(v)?.slice(1).map(Number) as [number, number] | undefined;
  const shot = parse(dims);
  const screen = parse(display);
  if (!shot || !screen) return false;
  const [w, h] = shot;
  const [dw, dh] = screen;
  if (w === dw && h === dh) return true;
  const long = Math.max(w, h);
  if (long < MIN_SCREENSHOT_EDGE || w > dw || h > dh) return false;
  return w >= h ? Math.abs(h - (w * dh) / dw) <= 1 : Math.abs(w - (h * dw) / dh) <= 1;
}

type Checker = (name: string, ok: boolean, detail: string) => void;

/** Copies a PNG from the machine into the out dir and checks it. */
async function pngCheck(vm: Vm, check: Checker, result: ProbeResult, outDir: string, name: string, size?: string): Promise<void> {
  const file = path.join(outDir, `${name}.png`);
  try {
    const bytes = Buffer.from(await vm.fs.readFile(`${WORK_DIR}/${name}.png`));
    writeFileSync(file, bytes);
    result.files.push(file);
    const png = bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
    const dims = png ? `${bytes.readUInt32BE(16)}x${bytes.readUInt32BE(20)}` : "";
    const fits = size === undefined || screenshotShowsDisplay(dims, size);
    check(`${name}-screenshot`, png && bytes.length > 2000 && fits, `${bytes.length} bytes, ${png ? "PNG" : "not a PNG"}, ${dims}${size && dims !== size ? ` (the display is ${size}${fits ? ", scaled down whole" : ""})` : ""}`);
  } catch (error) {
    check(`${name}-screenshot`, false, String(error).slice(0, 200));
  }
}

/** Static checks, the probe folder, the loopback pages and the probe workspace. */
async function prepare(vm: Vm, check: Checker, result: ProbeResult): Promise<boolean> {
  const s = kv((await run(vm, staticCheckCommand())).stdout);
  check("tool-dir", s["cmux-link"] === "ok" && s["cua-wrapper"] === "ok", JSON.stringify({ cmux: s["cmux-link"], wrapper: s["cua-wrapper"] }));
  check("display-and-cua-off-until-asked", s[`unit-${DISPLAY_UNIT}`] === "inactive" && s[`unit-${CUA_UNIT}`] === "inactive" && s[`unit-${A11Y_UNIT}`] === "inactive", `${s[`unit-${DISPLAY_UNIT}`]} ${s[`unit-${CUA_UNIT}`]} ${s[`unit-${A11Y_UNIT}`]}`);
  // cmux-tui's worker launcher runs the starter only when root owns it and its folder and nobody else can write them.
  check("desktop-starter", (s.starter ?? "").trim() === "root:root:755 root:root:755" && s["starter-script"] === "ok", `${DESKTOP_STARTER} and /etc/cmux: ${s.starter ?? "absent"}; script ${s["starter-script"] ?? "not checked"}`);
  const instances = [DISPLAY_TEMPLATE_UNIT, A11Y_TEMPLATE_UNIT].map((u) => u.replace("@", "@1"));
  check(
    "per-display-templates-off",
    s[`template-${DISPLAY_TEMPLATE_UNIT}`] === "ok" && s[`template-${A11Y_TEMPLATE_UNIT}`] === "ok" && instances.every((u) => s[`unit-${u}`] === "inactive"),
    instances.map((u) => `${u}=${s[`unit-${u}`]}`).join(" "),
  );
  check("mcp-enabled", s["mcp-enabled"] === "True", `cmux.json mcp.enabled=${s["mcp-enabled"]}`);
  check("daemon-env", s["env-CMUX_AGENT_TOOLS_BIN_DIR"] === AGENT_TOOLS_BIN && s["exists-CMUX_BROWSER_HOST_BIN"] === "ok" && s["exists-CMUX_BROWSER_HOST_CHROMIUM"] === "ok", JSON.stringify({ bin: s["env-CMUX_AGENT_TOOLS_BIN_DIR"], host: s["exists-CMUX_BROWSER_HOST_BIN"], chrome: s["exists-CMUX_BROWSER_HOST_CHROMIUM"] }));
  result.checks.version = { ok: true, detail: s.version ?? "" };
  await run(vm, `install -d -m 0700 -o ${DEVBOX_WORK_USER} -g ${DEVBOX_WORK_USER} ${PROBE_DIR} ${PROBE_DIR}/www ${RECORDER_DIR} ${GATEWAY_RECORDER_DIR}`);
  await vm.fs.writeFile(`${PROBE_DIR}/www/index.html`, `<!doctype html><title>${PAGE_TITLE}</title><h1>${PAGE_TITLE}</h1>`, { mode: 0o644 });
  await vm.fs.writeFile(`${PROBE_DIR}/www/cua.html`, `<!doctype html><title>${CUA_PAGE_TEXT}</title><body style="background:#2d8cff;color:#fff;font:64px sans-serif"><h1>${CUA_PAGE_TEXT}</h1>`, { mode: 0o644 });
  await vm.fs.writeFile(`${RECORDER_DIR}/claude`, recorderScript(LAUNCHES), { mode: 0o755 });
  await vm.fs.writeFile(`${GATEWAY_RECORDER_DIR}/claude`, recorderScript(GATEWAY_LAUNCHES), { mode: 0o755 });
  await vm.fs.writeFile(`${PROBE_DIR}/mcp-client.py`, MCP_CLIENT_PY, { mode: 0o644 });
  await run(vm, `chown -R ${DEVBOX_WORK_USER}:${DEVBOX_WORK_USER} ${PROBE_DIR}`);
  await run(vm, `setsid python3 -m http.server ${PAGE_PORT} --bind 127.0.0.1 --directory ${PROBE_DIR}/www >${PROBE_DIR}/www.log 2>&1 < /dev/null & echo started`, 30_000, DEVBOX_WORK_USER);
  const C = `${CURRENT_BIN}/cmux-tui --session cloud`;
  const ws = await run(vm, `${C} workspace name:${WORKSPACE} show >/dev/null 2>&1 || ${C} workspace create --name ${WORKSPACE} >/dev/null && echo ok`, 60_000, DEVBOX_WORK_USER);
  check("daemon-terminal", ws.code === 0, ws.stdout.trim() || ws.stderr.slice(-300));
  return ws.code === 0;
}

/** One recorded launch: a fresh daemon with `env`, a session named `name`, one prompt, then shutdown. */
function recordSteps(name: string, env: string): string[] {
  return [
    `export ${env}`,
    `{ ${CURRENT_BIN}/cmux-tui acp new -d -m claude -n ${name} --cwd ${WORK_DIR}; echo "exit $?"; } > ${PROBE_DIR}/${name}-new.txt 2>&1`,
    `{ timeout 60 ${CURRENT_BIN}/cmux-tui acp send ${name} hello; echo "exit $?"; } > ${PROBE_DIR}/${name}-send.txt 2>&1`,
    `{ timeout 60 ${CURRENT_BIN}/cmux-tui acp daemon shutdown --end-agents; echo "exit $?"; } > ${PROBE_DIR}/${name}-shutdown.txt 2>&1`,
  ];
}

/** The launch acpmux builds for a Claude Code session, captured by the recorder (no model). */
async function recordLaunch(vm: Vm, check: Checker, result: ProbeResult, outDir: string): Promise<RecordedServer[]> {
  const body = [
    // acpmux never creates a missing ACPMUX_HOME (it refuses to start a daemon there): make it first.
    `install -d -m 0700 ${PROBE_DIR}/acpmux-recorder`,
    // The daemon puts the login shell's PATH first (acpmux login_env.rs), where the image's real claude is;
    // ACPMUX_LOGIN_ENV=0 keeps this PATH, so the recorder is the claude it launches.
    `export ACPMUX_HOME=${PROBE_DIR}/acpmux-recorder ACPMUX_LOGIN_ENV=0`,
    // First the launch a person's chat gets (the gateway on), kept apart; then the same with the gateway off
    // (ACPMUX_MCP_GATEWAY=0), whose stdio servers the probe starts and calls itself.
    ...recordSteps("gateway", `PATH=${GATEWAY_RECORDER_DIR}:$PATH`),
    ...recordSteps("recorder", `PATH=${RECORDER_DIR}:$PATH ACPMUX_MCP_GATEWAY=0`),
  ].join("\n");
  result.timings.recordMs = await inTerminal(vm, "record", terminalScript("record", body), 180);
  let text = "";
  try {
    text = await readGuest(vm, LAUNCHES);
  } catch {
    text = "";
  }
  writeFileSync(path.join(outDir, "claude-launches.txt"), text);
  // What acpmux said: without a recorded launch these are the only evidence of why.
  // Each leg's own: the gateway leg's were never kept, so its failure (no session launch recorded, rolls 45890407908
  // and 45906244147) left no evidence of why.
  const saidBy = async (leg: string): Promise<string[]> => {
    const lines: string[] = [];
    for (const step of ["new", "send", "shutdown"]) {
      const name = `${leg}-${step}`;
      const out = await readGuest(vm, `${PROBE_DIR}/${name}.txt`).catch((error) => `unreadable: ${String(error).slice(0, 120)}`);
      writeFileSync(path.join(outDir, `${name}.txt`), out);
      lines.push(`${name}: ${out.trim().replace(/\s+/g, " ").slice(-240)}`);
    }
    return lines;
  };
  const said = await saidBy("recorder");
  const gatewaySaid = await saidBy("gateway");
  const gatewayText = await readGuest(vm, GATEWAY_LAUNCHES).catch(() => "");
  writeFileSync(path.join(outDir, "claude-launches-gateway.txt"), gatewayText);
  const gateway = parseRecordedLaunch(gatewayText);
  const gatewayIssues = gatewayProblems(gateway.servers);
  check("acpmux-attaches-cmux-gateway", gatewayIssues.length === 0, `${gatewayIssues.join("; ")}${gatewayIssues.length ? ": " : ""}${gateway.servers.map((s) => `${s.name}=${s.url ?? s.command}`).join("; ") || `no launch with --mcp-config was recorded (${gatewayText.split(`${RECORD_END}\n`).filter((b) => b.trim()).length} launches recorded, none of them the chat's); ${gatewaySaid.join(" | ")}`}`);
  const launch = parseRecordedLaunch(text);
  const names = launch.servers.map((s) => `${s.name}=${s.url ?? `${s.command} ${s.args.join(" ")}`}`);
  const cu = attachedComputerUse(launch.servers);
  const cmuxOk = launch.servers.some((s) => s.name === "cmux" && s.url === undefined && s.command.startsWith(`${AGENT_TOOLS_BIN}/`));
  check(
    "acpmux-attaches-servers",
    cmuxOk && cu?.ok === true,
    `${cmuxOk ? "" : "no cmux server from the tool dir; "}${cu ? (cu.ok ? "" : `${cu.name} attached another way; `) : `no Computer Use server (${CU_SERVER} or ${LEGACY_CU_SERVER}); `}${names.join("; ") || `no launch with --mcp-config was recorded (${text ? "launches without it" : "no launch at all"}); ${said.join(" | ")}`}`,
  );
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
    // The first call makes the daemon start the worker, which runs the desktop starter (the display and
    // its AT-SPI bus); then a Chrome window goes on the display, which the worker must see and capture.
    [CU_SERVER]: {
      calls: [
        { name: "status", arguments: {} },
        { shell: displayWindowCommand(`http://127.0.0.1:${PAGE_PORT}/cua.html`) },
        { name: "screenshot", arguments: { force: true }, copy_png_to: `${WORK_DIR}/cua.png` },
        // Chrome can still be mapping the window, titled by its URL, after the 5 s (cmux run 44955837342's bake).
        { name: "list_windows", arguments: {}, until: CUA_PAGE_TEXT, until_s: 30 },
        // Role cua-video stays off: a cmux machine's desktop has no H.264 encoder, so `record` must refuse.
        { name: "record", arguments: { seconds: 1 }, expect_error: true },
      ],
    },
    [LEGACY_CU_SERVER]: {
      before: displayWindowCommand(`http://127.0.0.1:${PAGE_PORT}/cua.html`),
      calls: [
        { name: "set_config", arguments: { capture_scope: "desktop" } },
        { name: "get_desktop_state", arguments: { screenshot_out_file: `${WORK_DIR}/cua.png` } },
        // Role cua-video stays off: the driver must refuse to install ffmpeg (agent-tools.ts CUA_REFUSE_DIR).
        { name: "install_ffmpeg", arguments: { confirm: true }, expect_error: true },
      ],
    },
    // The browser host's first call after launch sets the browser up (Browser.setPermission, a 10 s bound in the
    // host); on a clone of a just-baked snapshot it timed out in about half the rolls (cmux run 45119294989) and
    // answered in 631 ms on the next (45124861415). A timed-out attempt is repeated for up to 60 s, and the
    // check names the attempts, so a slow first start shows its numbers and a host that never answers still fails.
    cmux: { calls: [{ name: "browser_repl_eval", arguments: { session: "probe", code: `await page.goto(${JSON.stringify(`http://127.0.0.1:${PAGE_PORT}/`)}); console.log(await page.title()); screenshot()` }, copy_png_to: `${WORK_DIR}/browser.png`, until: PAGE_TITLE, until_s: 60 }] },
  };
  const lines: string[] = [];
  for (const server of servers.filter((s) => s.name in calls)) {
    const spec = { ...server, stderr: `${PROBE_DIR}/mcp-${server.name}.stderr`, out: `${PROBE_DIR}/mcp-${server.name}.json`, before_calls: calls[server.name].before, calls: calls[server.name].calls };
    await vm.fs.writeFile(`${PROBE_DIR}/mcp-${server.name}.spec.json`, JSON.stringify(spec), { mode: 0o644 });
    lines.push(`timeout 280 python3 ${PROBE_DIR}/mcp-client.py ${PROBE_DIR}/mcp-${server.name}.spec.json`);
  }
  await run(vm, `chown -R ${DEVBOX_WORK_USER}:${DEVBOX_WORK_USER} ${PROBE_DIR}`);
  result.timings.mcpMs = await inTerminal(vm, "mcp", terminalScript("mcp", lines.join("\n")), 600);
  // Only the Computer Use server acpmux attached is judged; with none, CU_SERVER's checks fail.
  const cu = attachedComputerUse(servers) ?? { name: CU_SERVER, ok: false, legacy: false };
  for (const name of Object.keys(calls).filter((n) => n === "cmux" || n === cu.name)) {
    let report: { tools: string[]; initialize: string; calls: Array<{ name: string; isError: boolean; text: string; expect_error?: boolean; attempts: number; ms: number[] }> };
    const stderr = await readGuest(vm, `${PROBE_DIR}/mcp-${name}.stderr`).catch(() => "");
    if (stderr) writeFileSync(path.join(outDir, `mcp-${name}.stderr`), stderr);
    try {
      report = JSON.parse(await readGuest(vm, `${PROBE_DIR}/mcp-${name}.json`));
    } catch (error) {
      check(`mcp-${name}`, false, `no report: ${String(error).slice(0, 160)}`);
      continue;
    }
    writeFileSync(path.join(outDir, `mcp-${name}.json`), JSON.stringify(report, null, 2));
    const required = requiredTools(name, servers.find((s) => s.name === name)?.args ?? []);
    const missing = required.filter((t) => !report.tools.includes(t));
    check(`mcp-${name}-tools`, report.initialize === "ok" && missing.length === 0, missing.length ? `missing ${missing.join(", ")} (listed: ${report.tools.slice(0, 12).join(", ")})` : `${report.tools.length} tools, including ${required.join(", ")}`);
    const failed = report.calls.filter((c) => c.isError !== (c.expect_error === true));
    check(`mcp-${name}-calls`, report.calls.length > 0 && failed.length === 0, report.calls.map((c) => `${c.name}${c.attempts > 1 ? ` (${c.attempts} attempts, ms ${c.ms.join("/")})` : ""}: ${c.isError ? "error " : ""}${c.text.slice(0, 160)}`).join(" | "));
  }
  // The image carries ffmpeg for people (graduated.json); the driver must still find the refusing one first.
  const ffmpeg = await run(vm, `PATH=${CUA_REFUSE_DIR}:$PATH; [ "$(command -v ffmpeg)" = ${CUA_REFUSE_DIR}/ffmpeg ] && [ "$(command -v ffprobe)" = ${CUA_REFUSE_DIR}/ffprobe ] && ! ffmpeg -version >/dev/null 2>&1 && echo refused || echo not-refused`);
  if (cu.legacy) {
    const cuaReport = await readGuest(vm, `${PROBE_DIR}/mcp-${LEGACY_CU_SERVER}.json`).catch(() => "");
    check("cua-video-refused", cuaReport.includes("cua-video") && ffmpeg.stdout.trim() === "refused", `install_ffmpeg ${cuaReport.includes("cua-video") ? "refused with the cua-video message" : "was not refused"}; the driver's ffmpeg: ${ffmpeg.stdout.trim()}`);
    const units = await run(vm, `systemctl is-active ${DISPLAY_UNIT} ${CUA_UNIT} | tr '\\n' ' '`);
    check("display-and-cua-started-by-cmux-cua-mcp", units.stdout.trim() === "active active", units.stdout.trim());
  } else {
    await computerUseChecks(vm, check, ffmpeg.stdout.trim());
  }
  const mcpBrowser = await readGuest(vm, `${PROBE_DIR}/mcp-cmux.json`).catch(() => "");
  check("browser-page-title", mcpBrowser.includes(PAGE_TITLE), `the browser host ${mcpBrowser.includes(PAGE_TITLE) ? "returned" : "did not return"} "${PAGE_TITLE}"`);
  await pngCheck(vm, check, result, outDir, "browser");
  await pngCheck(vm, check, result, outDir, "cua", AGENT_DISPLAY_SIZE);
  const host = await run(vm, `pgrep -u ${DEVBOX_WORK_USER} -f '[c]mux-browser-host serve' | wc -l; tr '\\0' ' ' < /proc/$(pgrep -u ${DEVBOX_WORK_USER} -f '[c]hrome-linux64/chrome' | head -1)/cmdline 2>/dev/null | grep -cE -- '--no-sandbox|--disable-setuid-sandbox' || true`);
  const [hosts, sandboxOff] = host.stdout.trim().split("\n");
  check("browser-host-socket-activated-sandbox-on", Number(hosts) >= 1 && sandboxOff === "0", `hosts=${hosts} sandbox-off-switches=${sandboxOff}`);
}

/** As root: the worker the daemon started for CU_SERVER, its units and what it may do (worker-* keys). */
export function computerUseWorkerCommand(): string {
  return [
    `pid=$(pgrep -u ${DEVBOX_WORK_USER} -f '[_]${CU_WORKER_MODE.slice(1)}' | head -1)`,
    'echo "worker-pid=${pid:-none}"',
    `for u in ${DISPLAY_UNIT} ${A11Y_UNIT}; do echo "worker-unit-$u=$(systemctl is-active $u)"; done`,
    `[ -n "$pid" ] && sed -n 's/^NoNewPrivs:[[:space:]]*/worker-nnp=/p' /proc/$pid/status`,
    `[ -n "$pid" ] && tr '\\0' '\\n' < /proc/$pid/environ | grep -E '^(DISPLAY|XAUTHORITY|CMUX_CU_HEADLESS|DBUS_SESSION_BUS_ADDRESS|PATH)=' | sed 's/^/worker-env-/'`,
    "true",
  ].join("; ");
}

/** The worker runs, its display and AT-SPI units are active, and its env points at that display and bus, headless. */
function workerStartedByComputerUse(w: Record<string, string>, bus: string): boolean {
  return (
    w["worker-pid"] !== "none" &&
    w[`worker-unit-${DISPLAY_UNIT}`] === "active" &&
    w[`worker-unit-${A11Y_UNIT}`] === "active" &&
    w["worker-env-DISPLAY"] === AGENT_DISPLAY &&
    w["worker-env-XAUTHORITY"] === AGENT_XAUTHORITY &&
    w["worker-env-CMUX_CU_HEADLESS"] === "1" &&
    w["worker-env-DBUS_SESSION_BUS_ADDRESS"] === bus
  );
}

/**
 * CU_SERVER's machine checks: the first call started the display, its AT-SPI bus and the worker on it,
 * headless; the worker cannot gain privileges and finds the refusing sudo/apt first (role cua-video
 * stays off), the server lists no video or install tool, and the Chrome window is in its window list.
 */
async function computerUseChecks(vm: Vm, check: Checker, ffmpegRefused: string): Promise<void> {
  const w = kv((await run(vm, computerUseWorkerCommand())).stdout);
  const bus = `unix:path=/run/cmux-agent-a11y-${AGENT_DISPLAY.slice(1)}/bus`;
  check(
    "display-and-worker-started-by-computer-use",
    workerStartedByComputerUse(w, bus),
    JSON.stringify({ worker: w["worker-pid"], display: w[`worker-unit-${DISPLAY_UNIT}`], a11y: w[`worker-unit-${A11Y_UNIT}`], DISPLAY: w["worker-env-DISPLAY"], headless: w["worker-env-CMUX_CU_HEADLESS"], bus: w["worker-env-DBUS_SESSION_BUS_ADDRESS"] }),
  );
  const report = await readGuest(vm, `${PROBE_DIR}/mcp-${CU_SERVER}.json`).then((t) => JSON.parse(t) as { tools: string[]; calls: Array<{ name: string; isError: boolean; text: string }> }).catch(() => null);
  const listed = videoToolProblems(report?.tools ?? [], report?.calls.find((c) => c.name === "record"));
  const firstPath = (w["worker-env-PATH"] ?? "").split(":")[0];
  check(
    "cua-video-refused",
    report !== null && listed.length === 0 && w["worker-nnp"] === "1" && firstPath === CUA_REFUSE_DIR && ffmpegRefused === "refused",
    `${report ? (listed.length ? listed.join(", ") : "no video or install tool") : "no report"}; worker NoNewPrivs ${w["worker-nnp"] ?? "unread"} (${NO_NEW_PRIVS_ENV}), PATH first ${firstPath || "unread"}; the driver's ffmpeg: ${ffmpegRefused}`,
  );
  const windows = report?.calls.find((c) => c.name === "list_windows")?.text ?? "";
  check("cu-window-listed", windows.includes(CUA_PAGE_TEXT), `list_windows ${windows.includes(CUA_PAGE_TEXT) ? "names" : "does not name"} the "${CUA_PAGE_TEXT}" window: ${windows.slice(0, 200)}`);
}

/** Connects RD_SOCKET and prints `connected` or the errno name; with `holdSeconds`, keeps the connection open that long. */
export function rdConnectCommand(holdSeconds = 0): string {
  const py = `import errno, socket, sys, time
s = socket.socket(socket.AF_UNIX)
try:
    s.connect(sys.argv[1])
except OSError as e:
    print("connect=" + errno.errorcode.get(e.errno, str(e.errno))); sys.exit(0)
print("connect=connected"); sys.stdout.flush(); time.sleep(float(sys.argv[2]))`;
  return `python3 -I -c ${sq(py)} ${RD_SOCKET} ${holdSeconds}`;
}

/** The desktop host's user, run dir, socket and units before any connection (as root). */
export function rdStaticCheckCommand(): string {
  return [
    `echo "rd-user=$(getent passwd ${RD_USER} | cut -d: -f7)"`,
    `echo "rd-groups=$(id -nG ${RD_USER} | tr ' ' ',')"`,
    `echo "rd-run-dir=$(stat -c '%a:%U:%G' ${RD_RUN_DIR})"`,
    `echo "rd-socket=$(stat -c '%F:%a:%U:%G' ${RD_SOCKET})"`,
    `echo "rd-socket-unit=$(systemctl is-active ${RD_SOCKET_UNIT})"`,
    `echo "rd-socket-enabled=$(systemctl is-enabled ${RD_SOCKET_UNIT})"`,
    `echo "rd-unit=$(systemctl is-active ${RD_UNIT})"`,
    `echo "rd-peer-uid=$(grep -o -- '--peer-uid [0-9]*' ${RD_START_SCRIPT} | cut -d' ' -f2)"`,
    `echo "rd-exec-start=$(systemctl show -p ExecStart --value ${RD_UNIT} | grep -o 'path=[^ ;]*' | head -1)"`,
    `echo "rd-work-uid=$(id -u ${DEVBOX_WORK_USER})"`,
    `echo "rd-families=$(systemctl show -p RestrictAddressFamilies --value ${RD_UNIT})"`,
  ].join("; ");
}

/** As root: a user that is neither root nor the work user (nobody) is refused by the socket's mode. */
export function rdOtherUserCommand(): string {
  return `setpriv --reuid=nobody --regid=nogroup --clear-groups ${rdConnectCommand(0)} | sed 's/^/other-/'`;
}

/**
 * As root: a connection made as the work user (the link receiver's uid) and held open starts the
 * host (bounded: the first start downloads OpenH264); then who runs it and what sockets it has.
 */
export function rdActivateCommand(waitSeconds = 90): string {
  return [
    `{ setpriv --reuid=${DEVBOX_WORK_USER} --regid=${DEVBOX_WORK_USER} --init-groups ${rdConnectCommand(waitSeconds + 10)} > /tmp/cmux-rd-probe-connect.txt 2>&1 & held=$!; }`,
    `for i in $(seq 1 ${waitSeconds * 5}); do pid=$(systemctl show -p MainPID --value ${RD_UNIT}); [ "\${pid:-0}" != 0 ] && break; sleep 0.2; done`,
    "sleep 1",
    `pid=$(systemctl show -p MainPID --value ${RD_UNIT})`,
    `echo "rd-unit-active=$(systemctl is-active ${RD_UNIT})"`,
    `echo "rd-host-user=$(ps -o user= -p "\${pid:-0}" 2>/dev/null | tr -d ' ')"`,
    `echo "rd-host-cmd=$(tr '\\0' ' ' < /proc/\${pid:-0}/cmdline 2>/dev/null | sed 's/^[^ ]*cmux-rd /cmux-rd /')"`,
    `echo "rd-host-tcp=$(ss -Htanp 2>/dev/null | grep -c "pid=\${pid:-0}," || true)"`,
    `echo "rd-host-udp=$(ss -Huanp 2>/dev/null | grep -c "pid=\${pid:-0}," || true)"`,
    `echo "rd-xauth=$(stat -c '%a:%U' ${RD_XAUTHORITY} 2>/dev/null)"`,
    `echo "rd-host-dir=$(stat -c '%a:%U' ${RD_HOST_DIR} 2>/dev/null)"`,
    // While the connection is held (the host runs, so its runtime dir and cookie copy exist): the
    // work user's read of the copy must fail with EACCES, never ENOENT (a gone file proves nothing).
    `setpriv --reuid=${DEVBOX_WORK_USER} --regid=${DEVBOX_WORK_USER} --init-groups ${rdReadCommand(RD_XAUTHORITY)} | sed 's/^/rd-work-/'`,
    `sed 's/^/rd-work-/' /tmp/cmux-rd-probe-connect.txt`,
    // The host's unit wants the desktop session: it must come up (its start ends with the check), and
    // the display a viewer streams must show a window and lit pixels, never the empty black root.
    `for i in $(seq 1 ${(DESKTOP_CHECK_SECONDS + 10) * 5}); do st=$(systemctl is-active ${DESKTOP_SESSION_UNIT}); [ "$st" = active ] || [ "$st" = failed ] && break; sleep 0.2; done`,
    `echo "rd-desktop-session=$(systemctl is-active ${DESKTOP_SESSION_UNIT})"`,
    `setpriv --reuid=${DEVBOX_WORK_USER} --regid=${DEVBOX_WORK_USER} --init-groups env DISPLAY=${AGENT_DISPLAY} XAUTHORITY=${AGENT_XAUTHORITY} ${DESKTOP_CHECK_SCRIPT} 2>/dev/null | tail -1 | tr ' ' '\\n' | sed 's/^/rd-desktop-/'`,
    'kill "$held" 2>/dev/null; wait "$held" 2>/dev/null; true',
  ].join("; ");
}

/** Opens `file` for reading and prints `read=readable` or the errno name (EACCES, ENOENT, ...). */
export function rdReadCommand(file: string): string {
  const py = `import errno, sys
try:
    open(sys.argv[1], "rb").close()
except OSError as e:
    print("read=" + errno.errorcode.get(e.errno, str(e.errno))); sys.exit(0)
print("read=readable")`;
  return `python3 -I -c ${sq(py)} ${file}`;
}

/**
 * Desktop checks (role desktop). The boundary is the link admission; on the machine the work
 * user (the link receiver's uid) reaches the socket, others do not, and the host keeps its own files.
 */
async function desktopChecks(vm: Vm, check: Checker): Promise<void> {
  const s = kv((await run(vm, rdStaticCheckCommand())).stdout);
  check("rd-user", s["rd-user"] === "/usr/sbin/nologin" && s["rd-groups"] === RD_USER, `shell ${s["rd-user"]}, groups ${s["rd-groups"]} (not ${DEVBOX_WORK_USER}, no sudo)`);
  check("rd-run-dir-and-socket", s["rd-run-dir"] === "711:root:root" && s["rd-socket"] === `socket:660:root:${DEVBOX_WORK_USER}`, `${RD_RUN_DIR} ${s["rd-run-dir"]}, ${RD_SOCKET} ${s["rd-socket"]}`);
  check("rd-socket-enabled-host-off", s["rd-socket-unit"] === "active" && s["rd-socket-enabled"] === "enabled" && s["rd-unit"] === "inactive", `socket ${s["rd-socket-unit"]}/${s["rd-socket-enabled"]}, host ${s["rd-unit"]}`);
  check("rd-peer-uid-is-work-user", s["rd-peer-uid"] === String(RD_PEER_UID) && s["rd-work-uid"] === String(RD_PEER_UID) && s["rd-exec-start"] === `path=${RD_START_SCRIPT}`, `--peer-uid ${s["rd-peer-uid"]}, ${DEVBOX_WORK_USER} uid ${s["rd-work-uid"]}, ${s["rd-exec-start"]}`);
  // Unix sockets, plus IPv4 UDP and netlink for the datagram link (agent-tools.ts rdUnit); never IPv6 or another family.
  const families = (s["rd-families"] ?? "").split(/\s+/).filter(Boolean).sort().join(" ");
  check("rd-host-families", families === "AF_INET AF_NETLINK AF_UNIX", `RestrictAddressFamilies=${s["rd-families"]}`);
  const other = kv((await run(vm, rdOtherUserCommand(), 30_000)).stdout);
  check("rd-other-user-refused", other["other-connect"] === "EACCES", `connect as nobody: ${other["other-connect"]}`);
  const a = kv((await run(vm, rdActivateCommand(), 190_000)).stdout);
  check(
    "rd-work-user-connection-starts-host-as-its-user-no-tcp-or-udp",
    a["rd-work-connect"] === "connected" && a["rd-unit-active"] === "active" && a["rd-host-user"] === RD_USER && (a["rd-host-cmd"] ?? "").includes(`--listen-systemd --peer-uid ${RD_PEER_UID} `) && a["rd-host-tcp"] === "0" && a["rd-host-udp"] === "0",
    JSON.stringify({ connect: a["rd-work-connect"], unit: a["rd-unit-active"], user: a["rd-host-user"], cmd: a["rd-host-cmd"], tcpSockets: a["rd-host-tcp"], udpSockets: a["rd-host-udp"] }),
  );
  check("rd-cookie-copy", a["rd-xauth"] === `600:${RD_USER}` && a["rd-host-dir"] === `700:${RD_USER}`, `${RD_XAUTHORITY} ${a["rd-xauth"]}, ${RD_HOST_DIR} ${a["rd-host-dir"]}`);
  // Read while the host runs (in rdActivateCommand): EACCES only; ENOENT would mean the copy was not there to test.
  check("rd-work-user-cannot-read-cookie", a["rd-work-read"] === "EACCES", `${DEVBOX_WORK_USER} reading ${RD_XAUTHORITY} while the host runs: ${a["rd-work-read"]}`);
  check(
    "rd-desktop-session-shows-windows",
    a["rd-desktop-session"] === "active" && Number(a["rd-desktop-viewable"] ?? 0) > 0 && Number(a["rd-desktop-nonblack"] ?? 0) > 0 && a["rd-desktop-size"] === AGENT_DISPLAY_SIZE,
    `${DESKTOP_SESSION_UNIT} ${a["rd-desktop-session"]}; ${AGENT_DISPLAY} ${a["rd-desktop-size"]}: ${a["rd-desktop-windows"]} window(s), ${a["rd-desktop-viewable"]} viewable, ${a["rd-desktop-nonblack"]} lit pixels sampled`,
  );
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

/**
 * The image roll's harness gate (harness-gate.ts): `acp ensure` for every harness the Cloud chat picker offers, in a
 * terminal of the machine's own daemon with the guest's own acpmux, one check per harness. A failure names the
 * harness and its ensure output, here and as a workflow error, and fails the probe: the roll promotes nothing.
 */
async function harnessEnsureChecks(vm: Vm, check: Checker, result: ProbeResult, outDir: string, live: HarnessOutputs | null): Promise<void> {
  const harnesses = await pickerHarnesses();
  const t0 = Date.now();
  const outputs = await harnessEnsureOutputs(vm, harnesses, outDir, "harness-ensure");
  result.timings.harnessEnsureMs = Date.now() - t0;
  const gate = regressionGate(harnesses, outputs, live);
  const blocked = new Set(gate.blocking.map((b) => b.harness));
  for (const h of harnesses) {
    const warned = gate.warnings.find((w) => w.harness === h);
    check(`harness-ensure-${h}`, !blocked.has(h), warned?.detail ?? gate.blocking.find((b) => b.harness === h)?.detail ?? gate.results[h]!.detail);
  }
  const one = (s: string) => s.replace(/[\r\n%]/g, " ");
  for (const f of gate.blocking) console.log(`::error title=Image harness gate (${f.harness})::${one(f.detail)}`);
  for (const w of gate.warnings) console.log(`::warning title=Image harness gate (${w.harness})::${one(w.detail)}`);
  fileLiveFailing(outDir, liveFailingLines("harness gate", gate.warnings.map((w) => ({ name: w.harness, detail: w.detail }))));
  const summary = process.env.GITHUB_STEP_SUMMARY;
  if (summary && gate.warnings.length) {
    appendFileSync(summary, ["", "### Image harness gate: already failing on the live image (not blocking)", "", ...gate.warnings.map((w) => `- **${w.harness}**: ${one(w.detail).slice(0, 400)}`), ""].join("\n"));
  }
}

export type HarnessOutputs = Record<string, string | undefined>;

/** Runs the harness gate's ensure script in a terminal of `vm`'s daemon and reads each harness's output (also kept in outDir). */
async function harnessEnsureOutputs(vm: Vm, harnesses: readonly string[], outDir: string, label: string): Promise<HarnessOutputs> {
  const guestOut = `${PROBE_DIR}/${label}`;
  const body = harnessEnsureScript({ cmux: `${CURRENT_BIN}/cmux-tui`, cwd: WORK_DIR, outDir: guestOut, harnesses });
  await inTerminal(vm, label, terminalScript(label, body), harnesses.length * 160 + 60);
  const outputs: HarnessOutputs = {};
  for (const h of harnesses) {
    outputs[h] = await readGuest(vm, ensureOutputFile(guestOut, h)).catch(() => undefined);
    writeFileSync(path.join(outDir, `${label}-${h}.txt`), outputs[h] ?? "");
  }
  return outputs;
}

export type LiveBaseline = { harness: HarnessOutputs | null; checks: Record<string, Check> | null };

/**
 * The live image's results, for the gates that block only regressions: a clone of production's boot image
 * (harness-gate.ts liveBootImage) runs the probe's own steps (static checks, the recorded launch, the MCP server calls)
 * and then the harness gate's ensure, through the same daemon terminal; its files go to `live/`; deleted by its id.
 * A part that cannot be read is null, so its gate falls back to blocking every candidate failure.
 */
async function liveBaseline(fs: ReturnType<typeof freestyleClient>, ledger: Ledger, options: ProbeOptions): Promise<LiveBaseline> {
  const none: LiveBaseline = { harness: null, checks: null };
  if (options.baseline !== "live") return none;
  const name = `cmuxnp-dev-vmimg-${options.tag}-agenttools-live`;
  const outDir = path.join(options.outDir, "live");
  mkdirSync(outDir, { recursive: true });
  const warn = (what: string, e: unknown) =>
    console.log(`::warning title=Image roll baseline::no live image ${what} (${String(e).slice(0, 300).replace(/[\r\n%]/g, " ")}); every candidate failure of it blocks`);
  const result: ProbeResult = { checks: {}, timings: {}, files: [] };
  const check: Checker = (n, ok, detail) => {
    result.checks[n] = { ok, detail };
    console.log(`live ${ok ? "PASS" : "FAIL"} ${n}: ${detail.slice(0, 300)}`);
  };
  let created: Awaited<ReturnType<typeof createVm>> | null = null;
  try {
    const live = await liveBootImage();
    console.log(`baseline: live image ${live.id} (${live.snapshotId})`);
    created = await createVm(fs, ledger, { name, snapshotId: live.snapshotId });
    await firstExec(created.vm, created.t0);
    await run(created.vm, `install -d -o ${DEVBOX_WORK_USER} -g ${DEVBOX_WORK_USER} ${WORK_DIR}`);
    let checks: Record<string, Check> | null = null;
    try {
      if (!(await prepare(created.vm, check, result))) throw new Error(`daemon terminal: ${result.checks["daemon-terminal"]?.detail ?? "unavailable"}`);
      await callServers(created.vm, check, result, outDir, await recordLaunch(created.vm, check, result, outDir));
      checks = result.checks;
    } catch (e) {
      warn("browser checks", e);
    }
    try {
      return { harness: await harnessEnsureOutputs(created.vm, await pickerHarnesses(), options.outDir, "harness-ensure-live"), checks };
    } catch (e) {
      warn("harness result", e);
      return { harness: null, checks };
    }
  } catch (e) {
    warn("result", e);
    return none;
  } finally {
    if (created) await deleteVm(created.vm, created.vmId, name, ledger);
  }
}

/** Appends a gate's warnings to LIVE_FAILING_FILE, which the roll files as an issue (harness-gate.ts liveFailingLines). */
function fileLiveFailing(outDir: string, lines: string[]): void {
  if (lines.length) appendFileSync(path.join(outDir, LIVE_FAILING_FILE), `${lines.join("\n")}\n`);
}

/**
 * The browser checks block only regressions (harness-gate.ts checkRegressionGate): a candidate failure the live image
 * shares is re-judged a pass carrying its warning, here, as a workflow warning and in the step summary.
 */
function browserGate(result: ProbeResult, live: Record<string, Check> | null, outDir: string): void {
  const gate = checkRegressionGate(BROWSER_CHECKS, result.checks, live);
  const one = (s: string) => s.replace(/[\r\n%]/g, " ");
  for (const b of gate.blocking) console.log(`::error title=Image browser check (${b.check})::${one(b.detail)}`);
  for (const w of gate.warnings) {
    result.checks[w.check] = { ok: true, detail: w.detail };
    console.log(`WARN ${w.check}: ${w.detail.slice(0, 500)}`);
    console.log(`::warning title=Image browser check (${w.check})::${one(w.detail)}`);
  }
  fileLiveFailing(outDir, liveFailingLines("browser check", gate.warnings.map((w) => ({ name: w.check, detail: w.detail }))));
  const summary = process.env.GITHUB_STEP_SUMMARY;
  if (summary && gate.warnings.length) {
    appendFileSync(summary, ["", "### Image browser check: already failing on the live image (not blocking)", "", ...gate.warnings.map((w) => `- **${w.check}**: ${one(w.detail).slice(0, 400)}`), ""].join("\n"));
  }
}

export async function agentToolsProbe(vm: Vm, options: ProbeOptions, live: LiveBaseline = { harness: null, checks: null }): Promise<ProbeResult> {
  const result: ProbeResult = { checks: {}, timings: {}, files: [] };
  const check: Checker = (name, ok, detail) => {
    result.checks[name] = { ok, detail };
    console.log(`${ok ? "PASS" : "FAIL"} ${name}: ${detail.slice(0, 500)}`);
  };
  if (!(await prepare(vm, check, result))) return result;
  const servers = await recordLaunch(vm, check, result, options.outDir);
  await callServers(vm, check, result, options.outDir, servers);
  browserGate(result, live.checks, options.outDir);
  await desktopChecks(vm, check);
  await harnessEnsureChecks(vm, check, result, options.outDir, live.harness);
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
  // The live image first, on its own clone: the candidate's harness and browser gates compare against it.
  const live = await liveBaseline(fs, ledger, options);
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
    result = await agentToolsProbe(vm, options, live);
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
