/**
 * A timed end-to-end journey through NEXT Cloud's cmux VM API (vm.cmux.dev,
 * vm-staging.cmux.dev; workers/cmux-vm/openapi.json), the way a headless
 * client drives one machine:
 *
 *   health -> create -> running -> listed -> first exec -> agent CLIs present
 *   -> named terminal over WebSocket (first prompt) -> a background process
 *   -> pause -> paused -> exec refused while paused -> resume -> running
 *   -> the background process survived (memory kept) -> the same terminal
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
 */
import { randomBytes } from "node:crypto";
import { writeFileSync } from "node:fs";

const argv = process.argv.slice(2);
const option = (name: string): string | undefined => {
  const index = argv.indexOf(name);
  return index >= 0 ? argv[index + 1] : undefined;
};
const skipSleep = argv.includes("--skip-sleep");
const resultFile = option("--result-file");
const base = option("--url") ?? process.env["CMUX_VM_DOGFOOD_URL"] ?? "";
const tenantKey = process.env["CMUX_VM_SMOKE_API_KEY"] ?? "";
const serviceKey = process.env["CMUX_VM_SMOKE_SERVICE_KEY"] ?? "";
const serviceTeam = process.env["CMUX_VM_SMOKE_SERVICE_TEAM"] ?? "";
const useService = tenantKey === "" && serviceKey !== "" && serviceTeam !== "";
const bearer = useService ? serviceKey : tenantKey;
const teamHeaders: Record<string, string> = useService ? { "x-cmux-team-id": serviceTeam } : {};
if (base === "" || bearer === "") {
  console.error("needs --url (or CMUX_VM_DOGFOOD_URL) and CMUX_VM_SMOKE_API_KEY, or CMUX_VM_SMOKE_SERVICE_KEY with CMUX_VM_SMOKE_SERVICE_TEAM");
  process.exit(2);
}
const origin = new URL(base);
if (origin.protocol !== "https:" || origin.pathname !== "/") {
  console.error("the VM API URL must be an https origin");
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

async function call(method: string, path: string, body?: unknown, headers: Record<string, string> = {}, timeoutMs = REQUEST_TIMEOUT_MS): Promise<Reply> {
  const response = await fetch(new URL(path, origin), {
    method,
    headers: {
      authorization: `Bearer ${bearer}`,
      ...teamHeaders,
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
  if (vmId === null) {
    if (cleanupState === "unverified") cleanupState = "completed";
    return;
  }
  const id = vmId;
  try {
    const deleted = await call("DELETE", vmPath(id));
    const gone = await call("GET", vmPath(id));
    cleanupState = (deleted.status === 204 || deleted.status === 404) && gone.status === 404 ? "completed" : "failed";
  } catch (error) {
    cleanupState = "failed";
    console.error(`cleanup failed: ${error instanceof Error ? error.message : String(error)}`);
  }
  if (cleanupState !== "completed") console.error(`cleanup_needed_vm=${id}`);
}

function summary(outcome: Record<string, unknown>): Record<string, unknown> {
  const error = typeof outcome["error"] === "string" ? { error: outcome["error"].replace(/\s+/g, " ").slice(0, 600) } : {};
  return {
    ...outcome,
    ...error,
    api: "cmux-vm",
    url: origin.origin,
    auth: useService ? "service" : "tenant",
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
const DEADLINE_MS = 25 * 60_000;
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

    await timed("pause", async () => {
      expectStatus(await call("POST", `${vmPath(id)}/pause`, undefined, {}, 3 * 60_000), [200], "POST pause");
    });
    const pausedAt = performance.now();
    await timed("paused", () => waitForState(id, "paused", 3 * 60_000));
    result["statusAfterPauseSeries"] = await stateSeries(id, pausedAt, [1_000, 5_000, 15_000]);
    result["statusAfterPause"] = (result["statusAfterPauseSeries"] as Array<{ status: string }>).at(-1)?.status ?? "unknown";
    // A paused VM refuses exec with 409 instead of waking for it.
    const whilePaused = await call("POST", `${vmPath(id)}/exec`, { command: "true", timeoutMs: 10_000 }, {}, 40_000);
    result["execWhilePausedStatus"] = whilePaused.status;
    if (whilePaused.status !== 409) note(`exec on a paused VM answered ${whilePaused.status}, expected 409`);

    await timed("resume", async () => {
      expectStatus(await call("POST", `${vmPath(id)}/resume`, undefined, {}, 5 * 60_000), [200], "POST resume");
    });
    await timed("runningAfterResume", () => waitForState(id, "running", 3 * 60_000));
    result["memoryKept"] = await timed("memoryKept", async () => {
      const out = await exec(id, `kill -0 ${pid} 2>/dev/null && echo alive || echo gone`);
      return out.stdout.trim() === "alive";
    });
    if (result["memoryKept"] !== true) failed.push("memoryKept");
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
