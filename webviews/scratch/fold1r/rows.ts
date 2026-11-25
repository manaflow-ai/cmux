// scratch: print the store rows (before the turn view) whose id has one of the given parts, as JSON.
import { readFileSync } from "node:fs";
import { parseRecords } from "../../src/agent-session/acpmux/sim/sanitize";
import { AcpmuxDirectClient } from "../../src/agent-session/acpmux/direct";
const [file, seq, ...ids] = process.argv.slice(2);
const events = parseRecords(readFileSync(file!, "utf8")).sort((a, b) => a.seq - b.seq);
let snap: any;
const client: any = AcpmuxDirectClient.replay(events[0]!.sessionId, events, (next: any) => (snap = next));
client.seekReplay(Number(seq));
const rows = snap.rows as any[];
const first = ids[0] ? rows.findIndex((row) => row.id.includes(ids[0]!)) : 0;
for (const row of rows.slice(Math.max(0, first)))
  console.log(JSON.stringify({ ...row, items: row.items?.map((i: any) => ({ kind: i.kind, text: (i.text ?? "").slice(0, 40), tool: i.tool && { id: i.tool.id, title: i.tool.title?.slice(0, 40), kind: i.tool.kind, status: i.tool.status } })), text: row.text?.slice(0, 50) }).slice(0, 700));
