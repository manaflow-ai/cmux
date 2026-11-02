import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { LANE_NOTICE_BATCH } from "../src/agent-session/acpmux/model";
import { appendLaneNotice, batchLaneNotices } from "../src/agent-session/acpmux/conversation/laneNoticeBatches";

const reportText = (verdict: string, sha: string, findings = "") => `Review (Astra): ${verdict} at ${sha}\n${findings}`;
const row = (
  id: string,
  text: string,
  options: {
    report?: boolean;
    threads?: { id: string; sender: string }[];
    steer?: "waiting";
    kind?: string;
    name?: string;
  } = {},
) =>
  ({
    id,
    version: 1,
    at: Number(id.replace(/\D/g, "")) || 1,
    kind: options.kind ?? "user",
    steer: options.steer,
    incoming: {
      kind: "message",
      message: {
        name: options.name ?? (options.report ? "review-lane" : "inbox"),
        text,
        raw: text,
        ...(options.report ? { report: true } : {}),
        ...(options.threads ? { noticeThreads: options.threads } : {}),
      },
    },
  }) as AcpmuxRow;

const sha = "0123456789abcdef0123456789abcdef01234567";

test("keeps a singleton report and batches consecutive reports with verdict counts", () => {
  const one = row("r1", reportText("SHIP", sha), { report: true });
  const two = row("r2", reportText("BLOCK", sha, "[P1] crash\n[P2] alignment"), { report: true });
  const single = batchLaneNotices([one]);
  expect(single).toBeInstanceOf(Array);
  expect(single[0]).toBe(one);
  const grouped = batchLaneNotices([one, two]);
  expect(grouped).toHaveLength(1);
  expect(grouped[0]!.kind).toBe(LANE_NOTICE_BATCH);
  expect(grouped[0]!.laneNoticeBatch?.verdicts).toEqual({ SHIP: 1, BLOCK: 1 });
  expect(grouped[0]!.laneNoticeBatch?.rows).toEqual([one, two]);
  expect(grouped[0]!.joined).toEqual(["r1", "r2"]);
  expect(grouped[0]!.text).toContain("SHIP at");
});

test("inbox threads deduplicate by thread id and count senders", () => {
  const first = row("i1", "New messages", {
    threads: [
      { id: "orch/pr:1", sender: "orch" },
      { id: "orch/pr:2", sender: "orch" },
    ],
  });
  const second = row("i2", "New messages", {
    threads: [
      { id: "orch/pr:2", sender: "orch" },
      { id: "other/pr:3", sender: "other" },
    ],
  });
  const [group] = batchLaneNotices([first, second]);
  expect(group!.laneNoticeBatch?.threads).toEqual([
    { id: "orch/pr:1", sender: "orch" },
    { id: "orch/pr:2", sender: "orch" },
    { id: "other/pr:3", sender: "other" },
  ]);
});

test("ordinary rows, kind boundaries, and waiting rows break a batch", () => {
  const report = row("r1", reportText("SHIP", sha), { report: true });
  const ordinary = row("u", "hello", { report: false, name: "peer" });
  const other = row("i", "[inbox] New messages from other agents in 1 thread. (thread from:orch/pr:2)");
  const waiting = row("r2", reportText("SHIP", sha), { report: true, steer: "waiting" });
  const out: AcpmuxRow[] = [];
  appendLaneNotice(out, report);
  appendLaneNotice(out, ordinary);
  appendLaneNotice(out, other);
  appendLaneNotice(out, waiting);
  expect(out).toEqual([report, ordinary, other, waiting]);
});

test("same source list returns the exact cached result", () => {
  const rows = [
    row("r1", reportText("SHIP", sha), { report: true }),
    row("r2", reportText("SHIP", sha), { report: true }),
  ];
  const first = batchLaneNotices(rows);
  expect(batchLaneNotices(rows)).toBe(first);
  const extended = batchLaneNotices([...rows, row("r3", reportText("SHIP", sha), { report: true })]);
  expect(extended[0]).not.toBe(first[0]);
  expect(batchLaneNotices([...rows, row("r3", reportText("SHIP", sha), { report: true })])[0]).not.toBe(extended[0]);
});

test("waiting reports batch together, but never cross into delivered reports", () => {
  const waitingOne = row("w1", reportText("SHIP", sha), { report: true, steer: "waiting" });
  const waitingTwo = row("w2", reportText("BLOCK", sha), { report: true, steer: "waiting" });
  const delivered = row("d1", reportText("SHIP", sha), { report: true });
  const pending = batchLaneNotices([waitingOne, waitingTwo]);
  expect(pending).toHaveLength(1);
  expect(pending[0]!.laneNoticeBatch?.rows).toEqual([waitingOne, waitingTwo]);
  expect(batchLaneNotices([waitingOne, waitingTwo, delivered])).toHaveLength(2);
});

test("queued and waiting notices share the pending delivery phase", () => {
  const queued = row("q1", reportText("SHIP", sha), { report: true, kind: "queuedMessage" });
  const waiting = row("w1", reportText("BLOCK", sha), { report: true, steer: "waiting" });
  const [group] = batchLaneNotices([queued, waiting]);
  expect(group!.laneNoticeBatch?.rows).toEqual([queued, waiting]);
});

test("repeating the same append pair reuses the synthetic row", () => {
  const first = row("a1", reportText("SHIP", sha), { report: true });
  const second = row("a2", reportText("SHIP", sha), { report: true });
  const firstOut: AcpmuxRow[] = [first];
  appendLaneNotice(firstOut, second);
  const secondOut: AcpmuxRow[] = [first];
  appendLaneNotice(secondOut, second);
  expect(secondOut[0]).toBe(firstOut[0]);
});

test("the transcript batches adjacent read reports within a turn and stops at the next prompt", async () => {
  const { turnView } = await import("../src/agent-session/acpmux/conversation/turns");
  const prompt: AcpmuxRow = { id: "prompt", version: 1, at: 1, kind: "user", text: "Review the change" };
  const first = { ...row("r1", reportText("SHIP", sha), { report: true }), continues: true };
  const second = { ...row("r2", reportText("BLOCK", sha), { report: true }), continues: true };
  const nextPrompt = { ...prompt, id: "next-prompt", at: 10 };
  const third = { ...row("r3", reportText("SHIP", sha), { report: true }), continues: true };
  const drawn = turnView([prompt, first, second, nextPrompt, third], new Set(), { working: true });
  const batches = drawn.filter((item) => item.laneNoticeBatch);
  expect(batches).toHaveLength(1);
  expect(batches[0]!.laneNoticeBatch!.rows.map((item) => item.id)).toEqual([first.id, second.id]);
  expect(drawn.some((item) => item.id === third.id)).toBe(true);
});
