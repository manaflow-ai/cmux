import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  FANOUT_INSTRUCTION,
  fanoutRunSpec,
  lastAgentMessage,
  parseRunFanout,
  runFanout,
  runTimings,
} from "../scripts/cloud-vm/run-fanout.mjs";
import { normalizeRunSpec } from "../services/runs/legacy/spec";

const commit = "a".repeat(40);
const setupManifestDigest = `sha256:${"b".repeat(64)}`;

test("--run-fanout accepts 0..32 and refuses anything else", () => {
  expect(parseRunFanout(undefined)).toBe(0);
  expect(parseRunFanout("5")).toBe(5);
  expect(parseRunFanout("20")).toBe(20);
  for (const bad of ["-1", "33", "2.5", "five"]) expect(() => parseRunFanout(bad)).toThrow();
});

test("each lane's spec passes the server's RunSpec validation with its instruction", () => {
  const spec = fanoutRunSpec({ marker: "m", index: 3, sourceCommit: commit, setupManifestDigest });
  const normalized = normalizeRunSpec(spec);
  expect(normalized.variants[0].instruction).toBe(FANOUT_INSTRUCTION);
  expect(normalized.variants[0].instructionDigest).toBe(`sha256:${createHash("sha256").update(FANOUT_INSTRUCTION).digest("hex")}`);
  expect(spec.operationId).toBe("m-3");
});

test("server timings come from the Run's own events", () => {
  expect(runTimings({
    createdAt: "2026-10-20T00:00:00.000Z",
    events: [
      { kind: "attempt.queued", createdAt: "2026-10-20T00:00:00.000Z" },
      { kind: "attempt.started", createdAt: "2026-10-20T00:00:02.500Z" },
      { kind: "attempt.succeeded", createdAt: "2026-10-20T00:01:02.500Z" },
    ],
  })).toEqual({ queueWaitMs: 2500, attemptMs: 60000, serverTotalMs: 62500 });
  expect(runTimings({ createdAt: "2026-10-20T00:00:00.000Z", events: [] })).toEqual({ queueWaitMs: null, attemptMs: null, serverTotalMs: null });
});

test("the agent's reply is the last agent message in codex's JSONL stream", () => {
  const stream = [
    JSON.stringify({ type: "thread.started" }),
    JSON.stringify({ type: "item.completed", item: { type: "agent_message", text: "first" } }),
    "not json",
    JSON.stringify({ type: "item.completed", item: { type: "agent_message", text: "# cmux" } }),
  ].join("\n");
  expect(lastAgentMessage(stream)).toBe("# cmux");
  expect(lastAgentMessage("")).toBeNull();
});

test("fan-out submits every lane at once and reports each outcome, including admission rejections", async () => {
  let clock = 0;
  const posted: string[] = [];
  const reads = new Map<string, number>();
  let admitted = 0;
  const cancelled: string[] = [];
  const api = async (method: string, route: string, body?: any) => {
    if (method === "POST" && route === "/api/runs") {
      posted.push(body.operationId);
      if (admitted >= 3) return { status: 429, text: "", json: { error: "run_admission_full", message: "This team already has 16 queued or running Runs" } };
      admitted += 1;
      return { status: 202, text: "", json: { id: `run-${body.operationId}`, status: "queued", createdAt: new Date(0).toISOString(), events: [], attempts: [] } };
    }
    if (method === "GET" && route === "/api/vm") return { status: 200, text: "", json: { vms: [], limits: { maxActiveVms: 5 } } };
    if (method === "POST" && route.endsWith("/cancel")) {
      cancelled.push(route);
      return { status: 200, text: "", json: {} };
    }
    if (method === "GET") {
      const id = route.split("/").pop()!;
      const n = (reads.get(id) ?? 0) + 1;
      reads.set(id, n);
      const failed = id.endsWith("-1");
      const status = n < 2 ? "running" : failed ? "failed" : "succeeded";
      return {
        status: 200, text: "", json: {
          id, status, createdAt: new Date(0).toISOString(),
          attempts: [{ id: "00000000-0000-0000-0000-000000000001", status, providerVmId: `vm-${id}`, error: failed ? "Run worker could not open the owner's Cloud session (cloud-origin)" : null }],
          events: [
            { kind: "attempt.started", createdAt: new Date(1000).toISOString() },
            ...(n >= 2 ? [{ kind: failed ? "attempt.failed" : "attempt.succeeded", createdAt: new Date(31000).toISOString() }] : []),
          ],
        },
      };
    }
    if (method === "POST" && route.endsWith("/exec")) {
      return { status: 200, text: "", json: { stdout: JSON.stringify({ type: "item.completed", item: { type: "agent_message", text: "# cmux" } }) } };
    }
    throw new Error(`unexpected ${method} ${route}`);
  };
  const receipt = await runFanout({
    api, count: 5, marker: "fan", sourceCommit: commit, setupManifestDigest,
    now: () => clock, sleep: async (ms: number) => { clock += ms; }, pollMs: 1000,
  });
  expect(posted.sort()).toEqual(["fan-0", "fan-1", "fan-2", "fan-3", "fan-4"]);
  expect(receipt.outcomes).toEqual({ succeeded: 2, failed: 1, rejected: 2 });
  expect(receipt.agentReplies).toBe(2);
  expect(receipt.stats.queueWaitMs).toMatchObject({ n: 3, p50: 1000 });
  const failed: any = receipt.lanes.find((lane: any) => lane.status === "failed");
  expect(failed.error).toContain("cloud-origin");
  const rejected = receipt.lanes.filter((lane: any) => lane.status === "rejected");
  expect(rejected.every((lane: any) => lane.httpStatus === 429 && lane.error.includes("16 queued or running"))).toBe(true);
  expect(receipt.maxActiveVms).toBe(5);
  // Failed and rejected lanes never count toward the run-time stats.
  expect(receipt.stats.attemptMs).toMatchObject({ n: 2, p50: 30000 });
  expect(receipt.stats.clientFirstRunningMs.n).toBe(3);
  expect(cancelled).toEqual([]);
});

test("a lane still running at the deadline is cancelled and reported as a timeout", async () => {
  let clock = 0;
  const cancelled: string[] = [];
  const api = async (method: string, route: string) => {
    if (method === "GET" && route === "/api/vm") return { status: 200, text: "", json: { vms: [], limits: { maxActiveVms: 5 } } };
    if (method === "POST" && route === "/api/runs") return { status: 202, text: "", json: { id: "run-slow", status: "queued", createdAt: new Date(0).toISOString(), events: [], attempts: [] } };
    if (method === "POST" && route.endsWith("/cancel")) {
      cancelled.push(route);
      return { status: 200, text: "", json: {} };
    }
    return { status: 200, text: "", json: { id: "run-slow", status: "queued", createdAt: new Date(0).toISOString(), events: [], attempts: [{ id: "a", status: "queued" }] } };
  };
  const receipt = await runFanout({
    api, count: 1, marker: "slow", sourceCommit: commit, setupManifestDigest,
    now: () => clock, sleep: async (ms: number) => { clock += ms; }, pollMs: 1000, timeoutMs: 5000,
  });
  expect(receipt.outcomes).toEqual({ timeout: 1 });
  expect(cancelled).toEqual(["/api/runs/run-slow/cancel"]);
});
