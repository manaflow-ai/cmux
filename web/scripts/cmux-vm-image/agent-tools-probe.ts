/**
 * Agent tools probe for a cmux VM image clone baked with `--agent-tools` (agent-tools.ts, bead cx-h8n).
 *
 * On one clone, the way a person would: a terminal of the machine's own daemon starts the
 * machine's acpmux (`cmux-tui acp`), which starts a Claude Code session. The probe then checks
 * that the agent lists the cmux-cua tools, the cmux browser REPL tools and the cmux:cmux-browser
 * skill; that it takes a browser screenshot of a loopback page through the browser host (the
 * daemon socket-activates it, Chrome sandboxed); and that it takes a computer-use screenshot of
 * the machine's Xvfb display (started on demand by the cmux-cua wrapper), with a Chrome window on it.
 *
 * Usage (from web/):
 *   bun scripts/cmux-vm-image/agent-tools-probe.ts --snapshot <sh-id> --tag <tag> --claude-token-file <env file> [--out-dir <dir>]
 * The token file holds CLAUDE_CODE_OAUTH_TOKEN= or ANTHROPIC_OAUTH_TOKEN= (a Claude Code token);
 * it is read here, written only to a 0600 file on the clone (deleted with it) and never printed.
 * The clone is named cmuxnp-dev-vmimg-<tag>-agenttools, pauses after 300 s of network idleness,
 * is recorded in <out-dir>/resources.tsv, deleted by its exact id at the end (also on failure),
 * and a lookup by that id must then answer not found.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { DEVBOX_WORK_HOME, DEVBOX_WORK_USER } from "../../services/vms/images/workUser";
import { AGENT_DISPLAY, AGENT_TOOLS_BIN, AGENT_XAUTHORITY, CUA_UNIT, DISPLAY_UNIT, WORK_USER_CMUX_JSON } from "./agent-tools";
import { argValue, createVm, deleteVm, firstExec, freestyleClient, Ledger, run, sleep, type Vm } from "./guest";
import { CURRENT_BIN, sq } from "./lock";
import { readEnvFile } from "./dev-e2e";

const PROBE_DIR = "/tmp/cmux-agent-tools-probe";
const WORK_DIR = `${DEVBOX_WORK_HOME}/agent-tools-probe`;
const PAGE_PORT = 18732;
export const PAGE_TITLE = "cmux agent tools probe";
const CUA_PAGE_TEXT = "cmux computer use probe";
const WORKSPACE = "agent-tools-probe";
const SESSION = "tools";
const TURN_SECONDS = 270;

/** Tools and skills the agent must name (Claude Code prefixes MCP tools with mcp__<server>__). */
export const REQUIRED_TOOLS = ["mcp__cmux-cua__get_desktop_state", "mcp__cmux-cua__click", "mcp__cmux__browser_repl_eval", "mcp__cmux__browser_repl_open"] as const;
export const REQUIRED_SKILLS = ["cmux:cmux-browser"] as const;

/** Problems in the agent's tool list reply. */
export function toolListProblems(reply: string): string[] {
  return [...REQUIRED_TOOLS, ...REQUIRED_SKILLS].filter((name) => !reply.includes(name)).map((name) => `the agent does not list ${name}`);
}

/** The Claude Code token from an env file: CLAUDE_CODE_OAUTH_TOKEN, else ANTHROPIC_OAUTH_TOKEN. */
export function claudeToken(envText: string): string {
  const env = readEnvFile(envText);
  const token = env.CLAUDE_CODE_OAUTH_TOKEN || env.ANTHROPIC_OAUTH_TOKEN;
  if (!token) throw new Error("the token file has no CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_OAUTH_TOKEN");
  return token;
}

/**
 * A shell file run in a daemon terminal: the model plane goes to the token (this clone has no
 * edge route), then `cmux-tui acp` (which starts the machine's acpmux from this terminal's env)
 * runs `body`, and `done` is written last.
 */
export function terminalScript(name: string, body: string): string {
  return [
    `. ${PROBE_DIR}/claude.env`,
    "unset ANTHROPIC_BASE_URL ANTHROPIC_API_KEY",
    `mkdir -p ${WORK_DIR} && cd ${WORK_DIR}`,
    body,
    `echo done > ${PROBE_DIR}/${name}.done`,
    "",
  ].join("\n");
}

export const LIST_PROMPT = "List every MCP server you are connected to and the exact names of all tools whose names start with mcp__, one per line. Then list every skill whose name starts with cmux:. Do not call any tool.";

export function screenshotPrompt(pageUrl: string): string {
  return [
    `Do these two things with your MCP tools, then report. 1) Browser: call mcp__cmux__browser_repl_eval with session "probe" and code: await page.goto(${JSON.stringify(pageUrl)}); console.log(await page.title()); screenshot() .`,
    `Printing an image saves it to a file and prints its path; copy that PNG to ${WORK_DIR}/browser.png with Bash.`,
    "2) Computer use: I explicitly ask you to use cmux Computer Use through the mcp__cmux-cua__ tools.",
    `Take a screenshot of the whole display of this machine (capture the desktop, not one window) and save the PNG to ${WORK_DIR}/cua.png (use a screenshot_out_file argument if a tool offers one), and report the screen size.`,
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

const kv = (text: string) => Object.fromEntries(text.split("\n").filter((l) => /^[a-zA-Z0-9_-]+=/.test(l)).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));

export type Check = { ok: boolean; detail: string };
export type ProbeResult = { checks: Record<string, Check>; timings: Record<string, number>; files: string[] };

/** Runs `script` in a terminal of the machine's daemon as the work user and waits (bounded) for its done file. */
async function inTerminal(vm: Vm, name: string, script: string, waitSeconds: number): Promise<number> {
  const t0 = Date.now();
  await vm.fs.writeFile(`${PROBE_DIR}/${name}.sh`, script, { mode: 0o644 });
  const C = `${CURRENT_BIN}/cmux-tui --session cloud`;
  const start = await run(vm, `${C} workspace name:${WORKSPACE} run --on-exit keep shell ${sq(`. ${PROBE_DIR}/${name}.sh`)} >/dev/null`, 60_000, DEVBOX_WORK_USER);
  if (start.code !== 0) throw new Error(`terminal run ${name}: ${start.stderr.slice(-300)}`);
  const wait = await run(vm, `for i in $(seq 1 ${waitSeconds}); do [ -e ${PROBE_DIR}/${name}.done ] && exit 0; sleep 1; done; exit 1`, (waitSeconds + 20) * 1000, DEVBOX_WORK_USER);
  if (wait.code !== 0) throw new Error(`terminal script ${name} did not finish within ${waitSeconds} s`);
  return Date.now() - t0;
}

async function readGuest(vm: Vm, file: string): Promise<string> {
  return new TextDecoder().decode(await vm.fs.readFile(file));
}

export async function agentToolsProbe(vm: Vm, options: { token: string; outDir: string }): Promise<ProbeResult> {
  const result: ProbeResult = { checks: {}, timings: {}, files: [] };
  const check = (name: string, ok: boolean, detail: string) => {
    result.checks[name] = { ok, detail };
    console.log(`${ok ? "PASS" : "FAIL"} ${name}: ${detail.slice(0, 500)}`);
  };
  const s = kv((await run(vm, staticCheckCommand())).stdout);
  check("tool-dir", s["cmux-link"] === "ok" && s["cua-wrapper"] === "ok", JSON.stringify({ cmux: s["cmux-link"], wrapper: s["cua-wrapper"] }));
  check("display-and-cua-off-until-asked", s[`unit-${DISPLAY_UNIT}`] === "inactive" && s[`unit-${CUA_UNIT}`] === "inactive", `${s[`unit-${DISPLAY_UNIT}`]} ${s[`unit-${CUA_UNIT}`]}`);
  check("mcp-enabled", s["mcp-enabled"] === "True", `cmux.json mcp.enabled=${s["mcp-enabled"]}`);
  check("daemon-env", s["env-CMUX_AGENT_TOOLS_BIN_DIR"] === AGENT_TOOLS_BIN && s["exists-CMUX_BROWSER_HOST_BIN"] === "ok" && s["exists-CMUX_BROWSER_HOST_CHROMIUM"] === "ok", JSON.stringify({ bin: s["env-CMUX_AGENT_TOOLS_BIN_DIR"], host: s["exists-CMUX_BROWSER_HOST_BIN"], chrome: s["exists-CMUX_BROWSER_HOST_CHROMIUM"] }));
  result.checks.version = { ok: true, detail: s.version ?? "" };

  // The token and the probe page, as the work user, in a 0700 folder.
  await run(vm, `install -d -m 0700 -o ${DEVBOX_WORK_USER} -g ${DEVBOX_WORK_USER} ${PROBE_DIR} ${PROBE_DIR}/www`);
  await vm.fs.writeFile(`${PROBE_DIR}/claude.env`, `export CLAUDE_CODE_OAUTH_TOKEN=${sq(options.token)}\n`, { mode: 0o600 });
  await vm.fs.writeFile(`${PROBE_DIR}/www/index.html`, `<!doctype html><title>${PAGE_TITLE}</title><h1>${PAGE_TITLE}</h1>`, { mode: 0o644 });
  await vm.fs.writeFile(`${PROBE_DIR}/www/cua.html`, `<!doctype html><title>${CUA_PAGE_TEXT}</title><body style="background:#2d8cff;color:#fff;font:64px sans-serif"><h1>${CUA_PAGE_TEXT}</h1>`, { mode: 0o644 });
  await run(vm, `chown -R ${DEVBOX_WORK_USER}:${DEVBOX_WORK_USER} ${PROBE_DIR}`);
  await run(vm, `setsid python3 -m http.server ${PAGE_PORT} --bind 127.0.0.1 --directory ${PROBE_DIR}/www >${PROBE_DIR}/www.log 2>&1 < /dev/null & echo started`, 30_000, DEVBOX_WORK_USER);
  const C = `${CURRENT_BIN}/cmux-tui --session cloud`;
  const ws = await run(vm, `${C} workspace create --name ${WORKSPACE} >/dev/null && echo ok`, 60_000, DEVBOX_WORK_USER);
  check("daemon-terminal", ws.code === 0, ws.stdout.trim() || ws.stderr.slice(-300));
  if (ws.code !== 0) return result;

  // The session: acpmux started from the terminal, a Claude Code session, the tool list.
  const list = terminalScript("list", [
    `{ ${CURRENT_BIN}/cmux-tui acp new -d -m claude -n ${SESSION} --cwd ${WORK_DIR} --policy approve-all; echo "exit $?"; } > ${PROBE_DIR}/new.txt 2>&1`,
    `{ timeout ${TURN_SECONDS} ${CURRENT_BIN}/cmux-tui acp send ${SESSION} ${sq(LIST_PROMPT)}; echo "exit $?"; } > ${PROBE_DIR}/list.txt 2>&1`,
  ].join("\n"));
  result.timings.listMs = await inTerminal(vm, "list", list, TURN_SECONDS + 30);
  const listReply = await readGuest(vm, `${PROBE_DIR}/list.txt`);
  writeFileSync(path.join(options.outDir, "list.txt"), listReply);
  const problems = toolListProblems(listReply);
  const toolCount = listReply.split("\n").filter((l) => l.trim().startsWith("mcp__")).length;
  check("agent-lists-tools", problems.length === 0, problems.join("; ") || `${toolCount} mcp__ tools named, including ${[...REQUIRED_TOOLS, ...REQUIRED_SKILLS].join(", ")}`);
  const units = await run(vm, `systemctl is-active ${DISPLAY_UNIT} ${CUA_UNIT} | tr '\\n' ' '`);
  check("display-and-cua-started-by-the-session", units.stdout.trim() === "active active", units.stdout.trim());

  // A window on the agent display, so the computer-use screenshot shows something.
  const page = `http://127.0.0.1:${PAGE_PORT}/cua.html`;
  const chrome = await run(vm, [
    `export DISPLAY=${AGENT_DISPLAY} XAUTHORITY=${AGENT_XAUTHORITY} $(tr '\\0' '\\n' < /proc/$(pgrep -f 'cmux-tui server [s]tart' | head -1)/environ | grep '^CMUX_BROWSER_HOST_CHROMIUM=')`,
    `setsid "$CMUX_BROWSER_HOST_CHROMIUM" --no-first-run --user-data-dir=${PROBE_DIR}/chrome-profile --window-position=0,0 --window-size=1280,800 --app=${page} >${PROBE_DIR}/chrome.log 2>&1 < /dev/null &`,
    "echo launched",
  ].join("; "), 30_000, DEVBOX_WORK_USER);
  check("display-window", chrome.code === 0, chrome.stdout.trim() || chrome.stderr.slice(-300));
  await sleep(5000);

  const shots = terminalScript("shots", `{ timeout ${TURN_SECONDS} ${CURRENT_BIN}/cmux-tui acp send ${SESSION} ${sq(screenshotPrompt(`http://127.0.0.1:${PAGE_PORT}/`))}; echo "exit $?"; } > ${PROBE_DIR}/shots.txt 2>&1`);
  result.timings.shotsMs = await inTerminal(vm, "shots", shots, TURN_SECONDS + 30);
  const shotsReply = await readGuest(vm, `${PROBE_DIR}/shots.txt`);
  writeFileSync(path.join(options.outDir, "shots.txt"), shotsReply);
  check("agent-reports-both", /RESULT browser=ok cua=ok/.test(shotsReply), shotsReply.trim().split("\n").slice(-3).join(" | "));
  check("browser-page-title", shotsReply.includes(PAGE_TITLE), `the reply ${shotsReply.includes(PAGE_TITLE) ? "names" : "does not name"} "${PAGE_TITLE}"`);
  for (const name of ["browser", "cua"]) {
    const file = path.join(options.outDir, `${name}.png`);
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
  const host = await run(vm, `pgrep -u ${DEVBOX_WORK_USER} -f '[c]mux-browser-host serve' | wc -l; tr '\\0' ' ' < /proc/$(pgrep -u ${DEVBOX_WORK_USER} -f '[c]hrome-linux64/chrome' | head -1)/cmdline 2>/dev/null | grep -cE -- '--no-sandbox|--disable-setuid-sandbox' || true`);
  const [hosts, sandboxOff] = host.stdout.trim().split("\n");
  check("browser-host-socket-activated-sandbox-on", Number(hosts) >= 1 && sandboxOff === "0", `hosts=${hosts} sandbox-off-switches=${sandboxOff}`);
  return result;
}

export async function main(argv = process.argv): Promise<number> {
  const snapshotId = argValue("--snapshot", argv);
  const tag = argValue("--tag", argv);
  const tokenFile = argValue("--claude-token-file", argv);
  if (!snapshotId?.startsWith("sh-") || !tag || !tokenFile) throw new Error("usage: agent-tools-probe.ts --snapshot <sh-id> --tag <tag> --claude-token-file <env file> [--out-dir <dir>]");
  const token = claudeToken(readFileSync(tokenFile, "utf8"));
  const outDir = path.resolve(argValue("--out-dir", argv) ?? `cmux-vm-image-out/${tag}-agenttools`);
  mkdirSync(outDir, { recursive: true });
  const ledger = new Ledger(path.join(outDir, "resources.tsv"));
  const name = `cmuxnp-dev-vmimg-${tag}-agenttools`;
  const fs = freestyleClient();
  const { vm, vmId, t0 } = await createVm(fs, ledger, { name, snapshotId });
  console.log(`VM ${vmId} (${name}) from ${snapshotId}`);
  let result: ProbeResult | null = null;
  let error: string | null = null;
  try {
    await firstExec(vm, t0);
    result = await agentToolsProbe(vm, { token, outDir });
  } catch (e) {
    error = String(e);
    console.error(`AGENT TOOLS PROBE FAILED: ${error}`);
  } finally {
    await deleteVm(vm, vmId, name, ledger);
  }
  let gone = "unknown";
  try {
    await fs.vms.get(vmId);
    gone = "still exists";
  } catch (e) {
    gone = String(e).slice(0, 160);
  }
  console.log(`after delete, get ${vmId}: ${gone}`);
  const deleted = /not found/i.test(gone);
  const passed = !error && deleted && result !== null && Object.values(result.checks).every((c) => c.ok);
  writeFileSync(path.join(outDir, `agent-tools-probe-${tag}.json`), `${JSON.stringify({ snapshotId, vmId, deleted, afterDelete: gone, passed, error, ...result }, null, 2)}\n`);
  console.log(passed ? "AGENT TOOLS PROBE PASSED" : "AGENT TOOLS PROBE FAILED");
  return passed ? 0 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(await main());
