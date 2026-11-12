import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { AcpmuxDirectClient, type EventRecord } from "../direct";
import type { AcpmuxRow } from "../model";
import { turnView } from "./turns";
import { turnReplies, undrawnReplies } from "./repliesDrawn";

const events: EventRecord[] = readFileSync(new URL("./fixtures-sr2-wide.ndjson", import.meta.url), "utf8")
  .trim().split("\n").map((l) => JSON.parse(l));
function replay(evs: EventRecord[], upTo: number): AcpmuxRow[] {
  let rows: readonly AcpmuxRow[] = [];
  const client = AcpmuxDirectClient.replay("01a18a35-b1e8-7951-ba2f-703bf916b9a6", evs, (s) => { rows = s.rows; });
  try { client.seekReplay(upTo); } finally { client.close(); }
  return [...rows];
}
test("wide", () => {
  const replies = turnReplies(events);
  console.log("REPLIES", replies.length, replies.map((r) => `${r.startSeq}-${r.endSeq}:${r.fromSeq}-${r.toSeq}`).join(" "));
  const rows = replay(events, events.at(-1)!.seq);
  const ids = new Set(rows.map((r) => r.id));
  console.log("RAW MISSING", replies.filter((r) => !ids.has(`assistant-${r.segment}`)).map((r) => r.startSeq).join(" "));
  for (const fam of ["claude", undefined]) {
    const drawn = turnView(rows, new Set(), { agentFamily: fam as any });
    const bad = undrawnReplies(replies, drawn);
    console.log(`UNDRAWN fam=${fam}`, bad.length, bad.map((r) => `${r.startSeq}-${r.endSeq}:${r.fromSeq}-${r.toSeq}`).join(" "));
    for (const r of bad.slice(0, 6)) {
      const at = drawn.findIndex((d: any) => d.id === `assistant-${r.segment}`);
      const near = drawn.filter((d: any) => (d.at ?? 0) >= r.startSeq - 1 && (d.at ?? 0) <= r.endSeq + 1);
      console.log(` turn ${r.startSeq}: drawnAt=${at} raw=${ids.has(`assistant-${r.segment}`)}`);
    }
    // dump around 2414207
    const i = drawn.findIndex((d: any) => d.id === "user-2414205" || d.id?.endsWith?.("2414205") || d.id === "user-2414207");
    console.log("AROUND", drawn.slice(Math.max(0, i - 2), i + 8).map((d: any) => `${d.kind}|${d.id}|fr=${d.foldedReply ? 1 : 0}|len=${(d.text ?? "").length}`).join("\n"));
  }
  expect(true).toBe(true);
});
