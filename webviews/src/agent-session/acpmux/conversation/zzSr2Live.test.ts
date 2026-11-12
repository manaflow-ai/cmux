import { afterAll, beforeAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../../test/support/domTeardown";
import type { EventRecord } from "../direct";
import type { AcpmuxRow } from "../model";
import { turnReplies, undrawnReplies } from "./repliesDrawn";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document, had: "window" in scope };
beforeAll(() => { scope.window = dom.window; scope.document = dom.window.document; });
afterAll(async () => {
  await settleReact();
  if (saved.had) Object.assign(scope, { window: saved.window, document: saved.document });
  else { delete scope.window; delete scope.document; }
});
const settle = async (done: () => boolean) => {
  for (let turns = 0; !done(); turns += 1) {
    if (turns > 20_000) throw new Error(`never settled: ${done.toString()}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
};
const NON = new Set(["usage_update", "available_commands_update", "current_mode_update", "config_option_update", "compaction_summary", "prompt_suggestion"]);
const all: EventRecord[] = readFileSync(new URL("./fixtures-sr2-wide.ndjson", import.meta.url), "utf8").trim().split("\n").map((l) => JSON.parse(l));
const transcript = all.filter((e) => (e.dir === "mux") || (e.dir === "in" && e.msg?.method === "session/update" && !NON.has(e.kind)));

for (const batch of [1, 7, 50]) for (const fam of ["claude", undefined]) test(`live batch=${batch} fam=${fam}`, async () => {
  const { AcpmuxDirectClient } = await import("../direct");
  const { MockAcpmuxSocket, mockHost } = await import("../mock");
  const { turnView, turnViewFrom } = await import("./turns");
  const folds = new Set<string>();
  let live: any;
  let rows: readonly AcpmuxRow[] = [];
  let shown: any;
  let socket!: any;
  let snapshots = 0;
  const client = await AcpmuxDirectClient.connect(mockHost, (snapshot) => {
    shown = snapshot; rows = snapshot.rows; snapshots += 1;
    live = turnViewFrom(snapshot.rows, folds as never, {
      working: snapshot.isWorking, clockOffset: snapshot.clockOffsetMs, turnStartedAtMs: snapshot.turnStartedAtMs,
      agentFamily: fam, waitingSteers: snapshot.waitingSteers } as never, live);
  }, undefined, () => (socket = new MockAcpmuxSocket(() => Promise.resolve())) as unknown as WebSocket);
  const id = mockHost.sessionId!;
  await settle(() => shown?.summary !== undefined);
  const sent: EventRecord[] = [];
  const replies = turnReplies(transcript);
  const misses = new Map<number, string>();
  let i = 0;
  for (const e of transcript) {
    if (e.dir === "mux") {
      if (e.kind === "turn_started") socket.touch(id, { status: "running", turn: { turnId: e.msg?.turnId } });
      socket.emit(id, { mux: e.kind, msg: e.msg });
      if (e.kind === "turn_result") socket.touch(id, { status: "idle", turn: undefined });
    } else socket.emit(id, { update: e.msg.params.update, ...(e.msg.params._meta && { meta: e.msg.params._meta }) });
    sent.push(e);
    i += 1;
    if (i % batch === 0 || e.kind === "turn_result" || e.kind === "turn_started") {
      const before = snapshots;
      await settle(() => snapshots > before || true);
      await new Promise((r) => setTimeout(r, 0));
      if (e.kind === "turn_result" || e.kind === "turn_started") {
        await new Promise((r) => setTimeout(r, 5));
        const ended = replies.filter((r) => r.endSeq <= e.seq);
        for (const r of undrawnReplies(ended, live?.rows ?? [])) if (!misses.has(r.startSeq)) misses.set(r.startSeq, `${r.startSeq}-${r.endSeq} missing at ${e.kind}@${e.seq}`);
      }
    }
  }
  await new Promise((r) => setTimeout(r, 20));
  const finalLive = undrawnReplies(replies, live.rows);
  const finalView = undrawnReplies(replies, turnView(rows, new Set(), { agentFamily: fam as any }));
  console.log(`LIVE batch=${batch} fam=${fam} replies=${replies.length} transient=${[...misses.values()].join(" | ")} finalLive=${finalLive.map((r) => r.startSeq)} finalView=${finalView.map((r) => r.startSeq)}`);
  if (finalLive.length) {
    const r = finalLive[0]!;
    const at = live.rows.findIndex((x: any) => x.kind === "user" && x.at >= 0 && JSON.stringify(x).includes(String(r.startSeq)));
    console.log("LIVE ROWS\n" + live.rows.map((x: any) => `${x.kind}|${x.id}|fr=${x.foldedReply ? 1 : 0}|fp=${x.foldedPrompt ? 1 : 0}|len=${(x.text ?? "").length}`).join("\n"));
    console.log("RAW ROWS\n" + rows.map((x: any) => `${x.kind}|${x.id}|len=${(x.text ?? "").length}|stream=${x.streaming ? 1 : 0}`).join("\n"));
  }
  client.close?.();
  expect(true).toBe(true);
}, 120_000);
