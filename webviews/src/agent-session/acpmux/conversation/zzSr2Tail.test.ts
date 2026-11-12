import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { AcpmuxDirectClient, type EventRecord } from "../direct";
import type { AcpmuxRow } from "../model";
import { turnView } from "./turns";
import { turnReplies, undrawnReplies } from "./repliesDrawn";
import { KEPT_EVENTS, keptEvents, packStreamed, unpackStreamed } from "../tailCache";

const NON = new Set(["usage_update", "available_commands_update", "current_mode_update", "config_option_update", "compaction_summary", "prompt_suggestion"]);
const all: EventRecord[] = readFileSync(new URL("./fixtures-sr2-wide.ndjson", import.meta.url), "utf8").trim().split("\n").map((l) => JSON.parse(l));
const transcript = all.filter((e) => e.dir === "mux" || (e.dir === "in" && e.msg?.method === "session/update" && !NON.has(e.kind)));
function replay(evs: EventRecord[]): AcpmuxRow[] {
  let rows: readonly AcpmuxRow[] = [];
  const client = AcpmuxDirectClient.replay("01a18a35-b1e8-7951-ba2f-703bf916b9a6", evs, (s) => { rows = s.rows; });
  try { client.seekReplay(evs.at(-1)!.seq); } finally { client.close(); }
  return [...rows];
}
const check = (name: string, evs: EventRecord[]) => {
  const replies = turnReplies(transcript).filter((r) => r.startSeq >= (evs[0]?.seq ?? 0));
  const drawn = turnView(replay(evs), new Set(), { agentFamily: "claude" });
  const bad = undrawnReplies(replies, drawn);
  const chunks = evs.filter((e) => e.kind === "agent_message_chunk").length;
  console.log(`TAIL ${name}: records=${evs.length} first=${evs[0]?.seq} chunks=${chunks} replies=${replies.length} undrawn=${bad.map((r) => r.startSeq).join(",")}`);
  return bad;
};
test("kept tail round trip", () => {
  for (const cut of [2412000, 2414000, 2414560, 2414830, 2415240]) {
    const upTo = transcript.filter((e) => e.seq <= cut);
    const kept = keptEvents(upTo);
    check(`keptEvents@${cut}`, kept);
    const packed = packStreamed(kept);
    console.log(`  packed ${kept.length} -> ${packed.length}`);
    const host = JSON.parse(JSON.stringify(packed)).slice(-KEPT_EVENTS);
    check(`host@${cut}`, unpackStreamed(host));
    // the same records without the per-record cursor (as the mock emits them)
    const bare = upTo.map(({ cursor: _c, ...e }: any) => e);
    const keptBare = keptEvents(bare);
    console.log(`  bare kept=${keptBare.length} packed=${packStreamed(keptBare).length}`);
    check(`hostBare@${cut}`, unpackStreamed(JSON.parse(JSON.stringify(packStreamed(keptBare))).slice(-KEPT_EVENTS)));
  }
  expect(true).toBe(true);
});
