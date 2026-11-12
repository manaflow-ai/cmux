import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { AcpmuxDirectClient, type EventRecord } from "../direct";
import type { AcpmuxRow } from "../model";
import { turnView } from "./turns";

const events: EventRecord[] = readFileSync(new URL("./fixtures-sr2-turn-2414207.ndjson", import.meta.url), "utf8")
  .trim().split("\n").map((l) => JSON.parse(l));
const finalText = events
  .filter((e) => e.kind === "agent_message_chunk" && e.seq >= 2414413 && e.seq <= 2414548)
  .map((e) => e.msg.params.update.content.text).join("");

function replay(evs: EventRecord[], upTo: number): AcpmuxRow[] {
  let rows: readonly AcpmuxRow[] = [];
  const client = AcpmuxDirectClient.replay("01a18a35-b1e8-7951-ba2f-703bf916b9a6", evs, (s) => { rows = s.rows; });
  try { client.seekReplay(upTo); } finally { client.close(); }
  return [...rows];
}
const show = (rows: readonly any[]) => rows.map((r) =>
  `${r.kind} id=${r.id} turn=${r.turnId ?? ""} hidden=${r.hidden ?? ""} sys=${r.system ?? ""} fr=${r.foldedReply ? "Y" : ""} fp=${r.foldedPrompt ? "Y" : ""} ` +
  `${JSON.stringify((r.text ?? "").slice(0, 40))} len=${(r.text ?? "").length} kids=${(r.rows ?? r.children ?? []).length}`).join("\n");

for (const upTo of [2414556, 2414566, 2414830]) {
  test(`repro upTo ${upTo}`, () => {
    const rows = replay(events, upTo);
    console.log(`==== RAW ROWS upTo ${upTo} (final len ${finalText.length})\n` + show(rows));
    for (const family of ["claude", undefined]) {
      const drawn = turnView(rows, new Set(), { agentFamily: family as any });
      console.log(`---- DRAWN family=${family}\n` + show(drawn));
      console.log("has final:", drawn.some((r: any) => r.kind === "assistant" && r.text === finalText && !r.foldedReply));
    }
    expect(true).toBe(true);
  });
}
