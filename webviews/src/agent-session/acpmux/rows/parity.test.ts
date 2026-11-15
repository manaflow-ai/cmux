// The detector of decision 233: each corpus log drawn by v1 (the direct client's replay) and by the
// store and adapter (the change strings the real translator and encoders gave for the same log,
// written by acpmux-core's `stream/parity_tests.rs`), compared field by field. A field may differ
// only when `notYet.ts` names it or a difference below is named with its fixture row; a listed
// field that no longer differs anywhere fails too, so both lists only shrink.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { AcpmuxDirectClient, type EventRecord } from "../direct";
import { harnessModeName } from "../harnessModes";
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import { permissionDecision } from "../permissions/record";
import { permissionOptionKind } from "../permissions/prompt";
import { adaptChat, askDecision } from "./adapter";
import { ChatRowsHost } from "./host";
import { NOT_YET } from "./notYet";
import { ChatRowStore } from "./store";
import type { ChatRow } from "./wire";

const FIXTURES = `${import.meta.dir}/../../../../../cmux-tui/crates/acpmux-book/src/translate/fixtures`;
const CORPUS = ["seed-turn", "r1-reply-1", "r1-reply-2", "parity"];
const SESSION = "s1";
const SID = "rows.1";

/// Differences that are by design, each with the corpus row that shows it (`<log>:<rowId>`).
const NAMED: readonly { field: string; row: string; why: string }[] = [
  {
    field: "user.turnId",
    row: "parity:1",
    why: "a turn is named by its prompt's rowId (`row.turn`), not acpmux's turn id; the view compares turn ids only with each other",
  },
  {
    field: "turnSummary.turnId",
    row: "parity:6",
    why: "as user.turnId",
  },
  {
    field: "permissionRecord.at",
    row: "parity:16",
    why: "the ask row is written when asked and patched with its answer; v1's receipt is a row at the answer",
  },
];

/// v1's snapshot of a corpus log: its records replayed through the direct client to the end.
function v1(name: string): AcpmuxSnapshot {
  const events: EventRecord[] = readFileSync(`${FIXTURES}/${name}.ndjson`, "utf8")
    .split("\n")
    .filter((line) => line.trim())
    // A permission draws only for the chat the replay shows.
    .map((line) => ({ ...JSON.parse(line), sessionId: SESSION }));
  let snapshot: AcpmuxSnapshot | undefined;
  const client = AcpmuxDirectClient.replay(SESSION, events, (next) => (snapshot = next));
  try {
    client.seekReplay(events.at(-1)!.seq);
  } finally {
    client.close();
  }
  return snapshot!;
}

/// The store's snapshot of the same log: the window, then each settled turn's fold as the Rust
/// half paged it (one `page {fold}` per group row, in order), through the host client.
async function v2(name: string) {
  const changes = (
    readFileSync(`${import.meta.dir}/parity/${name}.changes.jsonl`, "utf8")
      .split("\n")
      .filter((line) => line.trim())
      .map((line) => JSON.parse(line)) as string[]
  ).map((text) => ({ text, change: JSON.parse(text) as { kind: string } }));
  const store = new ChatRowStore();
  const host = new ChatRowsHost(
    async (method, params) => (method === "chat.rows.open" ? { sid: params.sid } : {}),
    store,
    () => SID,
  );
  await host.open("parity");
  let batch = 0;
  const folds: number[] = [];
  for (const { text, change } of changes) {
    if (change.kind === "chatPage") expect(host.page(SID, "after", { from: folds[0], fold: folds.shift() })).toBe(true);
    host.receive({ batch: ++batch, changes: [text] });
    if (change.kind === "chatWindow")
      for (const row of (change as unknown as { window: { rows: ChatRow[] } }).window.rows)
        if (row.kind === "group" && !row.open) folds.push(row.id);
  }
  expect(folds).toEqual([]);
  return store.snapshot(SID)!;
}

type Unit = { key: string; kind: string; fields: Record<string, unknown> };

/// A snapshot's rows as units keyed by what both sides share: a prompt by its promptId, a reply by
/// its text, a call by its id, a turn's end by its seq, a receipt by its permission. An activity
/// row's calls and thoughts are units of their own (v1 runs them together, the store does not).
function units(rows: readonly AcpmuxRow[]): Unit[] {
  const out: Unit[] = [];
  const seen = new Map<string, number>();
  const add = (base: string, kind: string, fields: Record<string, unknown>) => {
    const n = (seen.get(base) ?? 0) + 1;
    seen.set(base, n);
    const kept: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(fields))
      if (value !== undefined && key !== "id" && key !== "version") kept[key] = value;
    out.push({ key: n > 1 ? `${base}#${n}` : base, kind, fields: kept });
  };
  for (const row of rows) {
    if (row.kind === "activity") {
      for (const item of row.items ?? []) {
        if (item.tool) add(`tool:${item.tool.id}`, "tool", { ...item.tool, text: item.text, at: row.at });
        else add(`${item.kind}:${item.text}`, item.kind, { ...item, at: row.at });
      }
      continue;
    }
    const key =
      row.kind === "user"
        ? `user:${row.promptId}`
        : row.kind === "assistant"
          ? `assistant:${row.text}`
          : row.kind === "turnSummary"
            ? `turnSummary:${row.seq}`
            : row.kind === "permissionRecord"
              ? `permissionRecord:${row.permission?.permissionId}`
              : `${row.kind}:${row.id}`;
    add(key, row.kind, { ...row });
  }
  return out;
}

const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);

/// Every field key that differs between v1's units and the adapter's, with one example each.
function differences(want: Unit[], got: Unit[]): Map<string, string> {
  const found = new Map<string, string>();
  const note = (key: string, example: string) => {
    if (!found.has(key)) found.set(key, example);
  };
  const gotByKey = new Map(got.map((unit) => [unit.key, unit]));
  const wantByKey = new Map(want.map((unit) => [unit.key, unit]));
  for (const unit of want) {
    const other = gotByKey.get(unit.key);
    if (!other) {
      note(`row:${unit.kind}`, `v1 only: ${unit.key}`);
      continue;
    }
    for (const field of new Set([...Object.keys(unit.fields), ...Object.keys(other.fields)]))
      if (!same(unit.fields[field], other.fields[field]))
        note(
          `${unit.kind}.${field}`,
          `${unit.key}: v1 ${JSON.stringify(unit.fields[field])} store ${JSON.stringify(other.fields[field])}`,
        );
  }
  for (const unit of got) if (!wantByKey.has(unit.key)) note(`row:${unit.kind}`, `store only: ${unit.key}`);
  const order = (list: Unit[], other: Map<string, Unit>) =>
    list.filter((unit) => other.has(unit.key)).map((u) => u.key);
  if (!same(order(want, gotByKey), order(got, wantByKey)))
    note("order", `v1 ${order(want, gotByKey).join(",")} store ${order(got, wantByKey).join(",")}`);
  return found;
}

test("the corpus draws the same through the store and adapter as through v1, but for the fields named", async () => {
  const found = new Map<string, string[]>();
  for (const name of CORPUS) {
    const before = v1(name);
    const snapshot = await v2(name);
    const after = adaptChat(snapshot, { sessionId: SESSION });
    const rows = differences(units(before.rows), units(after.rows));
    // The queue's waiting prompts and the paging state are the window's (home d).
    if (
      !same(
        before.queue.map(({ id, prompt }) => ({ id, prompt })),
        after.queue,
      )
    )
      rows.set("queue", `v1 ${JSON.stringify(before.queue)} store ${JSON.stringify(after.queue)}`);
    if (before.canLoadOlder !== after.canLoadOlder) rows.set("canLoadOlder", `${before.canLoadOlder}`);
    for (const [key, example] of rows) found.set(key, [...(found.get(key) ?? []), `${name}: ${example}`]);
  }
  const allowed = new Set([...NOT_YET.map((entry) => entry.field), ...NAMED.map((entry) => entry.field)]);
  const offList = [...found].filter(([key]) => !allowed.has(key));
  const stale = [...allowed].filter((key) => !found.has(key));
  // What differs, for the reader of a failure.
  for (const [key, examples] of found)
    console.log(`PARITY ${allowed.has(key) ? "listed" : "OFF THE LIST"} ${key} | ${examples[0]}`);
  expect(offList.map(([key]) => key)).toEqual([]);
  expect(stale).toEqual([]);
});

// A0's four named cases (2c's review), each shown at its fixture row.

test("an answered option and a mode are named from the ask row's request", async () => {
  const rows = (await v2("parity")).rows.flatMap((entry) => (entry.row?.kind === "ask" ? [entry.row] : []));
  const answered = rows.find((row) => (row.body as { permissionId?: string }).permissionId === "perm1")!;
  const full = rows.find((row) => (row.body as { permissionId?: string }).permissionId === "perm2")!;
  // The row says the option's id and the mode's id; the page names both.
  expect((answered.body as { decision: unknown }).decision).toEqual({ kind: "answered", option: "this" });
  expect(askDecision(answered.body as Record<string, unknown>, { sessionId: SESSION })).toEqual({
    kind: "answered",
    option: "Allow for this chat",
  });
  expect((full.body as { decision: unknown }).decision).toEqual({ kind: "fullAccess", mode: "full-access" });
  expect(askDecision(full.body as Record<string, unknown>, { sessionId: SESSION })).toEqual({
    kind: "fullAccess",
    mode: harnessModeName(undefined, undefined, "full-access"),
  });
});

test("options with no kind: the translator's decision is the one the card's reading gives", async () => {
  const before = v1("parity");
  const record = before.rows.find(
    (row) => row.kind === "permissionRecord" && row.permission?.permissionId === "perm1",
  )!;
  const options = record.permission!.options;
  // "Allow chat" reads as always, "Allow for this chat" as an answer.
  expect(permissionOptionKind(options.find((option) => option.id === "chat")!)).toBe("allow_chat");
  expect(permissionOptionKind(options.find((option) => option.id === "this")!)).toBeUndefined();
  const rows = (await v2("parity")).rows.flatMap((entry) => (entry.row?.kind === "ask" ? [entry.row] : []));
  for (const row of rows) {
    const body = row.body as { outcome?: unknown; decision: { kind: string } };
    if (body.outcome === undefined) continue;
    expect(body.decision.kind).toBe(permissionDecision(record.permission!, body.outcome).kind);
  }
});

test("a turn's tokens read the same with and without inputExcludesCache", async () => {
  const after = adaptChat(await v2("parity"), { sessionId: SESSION }).rows;
  const before = v1("parity").rows;
  // seq 8's record has no `inputExcludesCache`, seq 26's has it.
  for (const seq of [8, 26]) {
    const want = before.find((row) => row.kind === "turnSummary" && row.seq === seq)!;
    const got = after.find((row) => row.kind === "turnSummary" && row.seq === seq)!;
    expect(got.tokens).toEqual(want.tokens);
  }
});

test("a turn's end with no status reads completed on the page; the row writes none", async () => {
  const snapshot = await v2("parity");
  const notice = snapshot.rows.find((entry) => (entry.row?.body as { seq?: number } | undefined)?.seq === 17)!;
  expect((notice.row!.body as { status?: string }).status).toBeUndefined();
  const summary = adaptChat(snapshot, { sessionId: SESSION }).rows.find((row) => row.seq === 17)!;
  expect(summary.status).toBe("completed");
  expect(v1("parity").rows.find((row) => row.kind === "turnSummary" && row.seq === 17)!.status).toBe("completed");
});
