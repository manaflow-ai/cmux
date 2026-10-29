// Fan-out through the Run API: N independent Runs created at once by one
// account, each with one codex variant that does a small read-only repo task.
// Measures admission, queue wait (Run created -> attempt.started), start-to-
// finish time and total time per Run, and reads each agent's last message
// from its retained VM. Pure orchestration over injected `api`, `now` and
// `sleep`, so tests/cloud-vm-run-fanout.test.ts covers it without a backend.
import { createHash } from "node:crypto";
import { summarize } from "./benchStats.mjs";

export const MAX_RUN_FANOUT = 32;
export const FANOUT_INSTRUCTION = "Read README.md in this repository and reply with its first non-empty line, verbatim. Do not modify any files.";

const sha256 = (text) => `sha256:${createHash("sha256").update(text).digest("hex")}`;

/** `--run-fanout N`: 0 when absent; otherwise an integer in 1..MAX_RUN_FANOUT. */
export function parseRunFanout(raw) {
  if (raw === undefined || raw === null || raw === "") return 0;
  const count = Number(raw);
  if (!Number.isSafeInteger(count) || count < 0 || count > MAX_RUN_FANOUT) {
    throw new Error(`--run-fanout must be an integer from 0 to ${MAX_RUN_FANOUT}, got ${JSON.stringify(raw)}`);
  }
  return count;
}

/** One single-variant cmux.run/v1 spec per fan-out lane. */
export function fanoutRunSpec({ marker, index, sourceCommit, setupManifestDigest, instruction = FANOUT_INSTRUCTION }) {
  return {
    schema: "cmux.run/v1",
    operationId: `${marker}-${index}`,
    source: { repository: "manaflow-ai/cmux", commit: sourceCommit, setupManifestDigest },
    intent: { digest: sha256(`fanout:${marker}`) },
    recipe: { id: "cloud-vm-dogfood", version: 1 },
    variants: [{ id: "codex", label: `Fan-out lane ${index}`, instructionDigest: sha256(instruction), instruction }],
    workspace: { kind: "ephemeral" },
    // Retained just long enough to read the agent reply; cleanup deletes it sooner.
    resources: { maxAttempts: 1, maxConcurrent: 1, wallTimeoutMs: 600_000, retainMs: 5 * 60_000 },
    routing: { executionProvider: "cloud-vm", backend: "freestyle" },
    capabilities: { secretRefs: [] },
    checks: ["terminal-receipt", "provider-cleanup"],
    policy: { mode: "fanout", humanApprovalRequired: false, evidenceKinds: ["patch"] },
  };
}

const TERMINAL = new Set(["succeeded", "failed", "cancelled"]);
const ms = (value) => (typeof value === "string" ? Date.parse(value) : Number.NaN);

/** Server-side timings from a Run snapshot: queue wait and attempt run time. */
export function runTimings(snapshot) {
  const created = ms(snapshot?.createdAt ?? snapshot?.run?.createdAt);
  const events = Array.isArray(snapshot?.events) ? snapshot.events : [];
  const started = ms(events.find((event) => event?.kind === "attempt.started")?.createdAt);
  const ended = ms(events.find((event) => ["attempt.succeeded", "attempt.failed", "attempt.cancelled"].includes(event?.kind))?.createdAt);
  const finite = (value) => (Number.isFinite(value) ? Math.round(value) : null);
  return {
    queueWaitMs: finite(started - created),
    attemptMs: finite(ended - started),
    serverTotalMs: finite(ended - created),
  };
}

/** Last agent message in a codex `exec --json` event stream. */
export function lastAgentMessage(jsonl) {
  let message = null;
  for (const line of String(jsonl ?? "").split("\n")) {
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }
    const item = event?.item ?? event?.msg;
    if (item && (item.type === "agent_message" || item.item_type === "assistant_message") && typeof (item.text ?? item.message) === "string") {
      message = item.text ?? item.message;
    }
  }
  return message;
}

async function oneLane({ api, now, sleep, spec, index, startedAt, timeoutMs, pollMs }) {
  const lane = { index, status: "unsubmitted" };
  const submitAt = now();
  let response;
  try {
    response = await api("POST", "/api/runs", spec, 5 * 60_000, { "idempotency-key": spec.operationId });
  } catch (error) {
    return { ...lane, status: "admission-error", error: String(error?.message ?? error).slice(0, 300) };
  }
  lane.admitMs = Math.round(now() - submitAt);
  lane.httpStatus = response.status;
  if (![200, 202].includes(response.status) || typeof response.json?.id !== "string") {
    // Run API errors are `{ error: code, message }`.
    return { ...lane, status: response.status === 429 ? "rejected" : "admission-error", error: String(response.json?.message ?? response.json?.error ?? response.text ?? "").slice(0, 300) };
  }
  lane.id = response.json.id;
  let snapshot = response.json;
  const deadline = now() + timeoutMs;
  while (!TERMINAL.has(snapshot?.status) && now() < deadline) {
    await sleep(pollMs);
    const read = await api("GET", `/api/runs/${encodeURIComponent(lane.id)}`).catch((error) => ({ status: 0, text: String(error?.message ?? error) }));
    if (read.status === 200 && read.json) snapshot = read.json;
    if (lane.firstRunningAtMs === undefined && (snapshot?.status === "running" || snapshot?.attempts?.[0]?.status === "running")) {
      lane.firstRunningAtMs = Math.round(now() - startedAt);
    }
  }
  if (!TERMINAL.has(snapshot?.status)) {
    // Never leave a Run behind that could still create a VM after the
    // account is deleted.
    const cancel = await api("POST", `/api/runs/${encodeURIComponent(lane.id)}/cancel`, {}).catch(() => null);
    lane.cancelStatus = cancel?.status ?? 0;
  }
  const attempt = snapshot?.attempts?.[0];
  lane.status = TERMINAL.has(snapshot?.status) ? snapshot.status : "timeout";
  lane.attemptStatus = attempt?.status ?? null;
  lane.providerVmId = typeof attempt?.providerVmId === "string" ? attempt.providerVmId : null;
  lane.attemptId = typeof attempt?.id === "string" ? attempt.id : null;
  lane.wallMs = Math.round(now() - startedAt);
  Object.assign(lane, runTimings(snapshot));
  if (lane.status !== "succeeded") lane.error = String(attempt?.error ?? snapshot?.run?.error ?? snapshot?.error ?? lane.status).slice(0, 300);
  if (lane.status === "succeeded" && lane.providerVmId && lane.attemptId) {
    const read = await api("POST", `/api/vm/${encodeURIComponent(lane.providerVmId)}/exec`, {
      command: `tail -c 20000 /tmp/cmux-agent-output-${lane.attemptId}.jsonl`,
      timeoutMs: 30_000,
    }, 60_000).catch(() => null);
    lane.agentReply = read?.status === 200 ? lastAgentMessage(read.json?.stdout)?.slice(0, 300) ?? null : null;
  }
  return lane;
}

/**
 * Create `count` Runs at the same instant and follow each to a terminal state.
 * Never throws for a lane failure: the receipt carries every lane's outcome.
 */
export async function runFanout({ api, now, sleep, count, marker, sourceCommit, setupManifestDigest, timeoutMs = 20 * 60_000, pollMs = 3_000 }) {
  // Paid plans cap active VMs per account; Runs past it fail VM create, so
  // the receipt names the cap next to the outcomes.
  const vms = await api("GET", "/api/vm").catch(() => null);
  const maxActiveVms = vms?.status === 200 ? vms.json?.limits?.maxActiveVms ?? null : null;
  const startedAt = now();
  const lanes = await Promise.all(Array.from({ length: count }, (_, index) => oneLane({
    api, now, sleep, index, startedAt, timeoutMs, pollMs,
    spec: fanoutRunSpec({ marker, index, sourceCommit, setupManifestDigest }),
  })));
  const counts = {};
  for (const lane of lanes) counts[lane.status] = (counts[lane.status] ?? 0) + 1;
  const succeeded = lanes.filter((lane) => lane.status === "succeeded");
  const pick = (key, from = lanes) => from.map((lane) => lane[key]);
  return {
    count,
    maxActiveVms,
    wallMs: Math.round(now() - startedAt),
    outcomes: counts,
    agentReplies: lanes.filter((lane) => typeof lane.agentReply === "string" && lane.agentReply.length > 0).length,
    stats: {
      admitMs: summarize(pick("admitMs")),
      queueWaitMs: summarize(pick("queueWaitMs")),
      clientFirstRunningMs: summarize(pick("firstRunningAtMs")),
      // Run-time stats cover succeeded lanes only; fast failures would skew them.
      attemptMs: summarize(pick("attemptMs", succeeded)),
      serverTotalMs: summarize(pick("serverTotalMs", succeeded)),
      wallMs: summarize(pick("wallMs", succeeded)),
    },
    lanes,
  };
}
