// The detector of decision 233: each corpus log drawn by v1 (the direct client's replay) and by the
// store and adapter (the change strings the real translator and encoders gave for the same log,
// written by acpmux-core's `stream/parity_tests.rs`), compared field by field. A field may differ
// only when `notYet.ts` names it or a difference below is named with its fixture row; a listed
// field that no longer differs anywhere fails too, so both lists only shrink.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { AcpmuxDirectClient, type EventRecord } from "../direct";
import { harnessModeName } from "../harnessModes";
import { turnView } from "../conversation/turns";
import type { Folds } from "../conversation/viewFolds";
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import { permissionDecision } from "../permissions/record";
import { permissionOptionKind } from "../permissions/prompt";
import { chatRowsFeed } from "../../../../test/support/chatRowsFeed";
import { adaptChat, askDecision } from "./adapter";
import { ChatRowsHost, type ChatRowsPost } from "./host";
import { NOT_IN_CORPUS, NOT_YET } from "./notYet";
import { ChatRowStore } from "./store";
import type { ChatRow } from "./wire";

const FIXTURES = `${import.meta.dir}/../../../../../cmux-tui/crates/acpmux-book/src/translate/fixtures`;
const CORPUS = ["seed-turn", "r1-reply-1", "r1-reply-2", "parity"];
const SESSION = "s1";
const SID = "rows.1";

/// Differences that are by design, each with the corpus row that shows it (`<log>:<rowId>`). A
/// `view: "same"` one is a difference of the rows only: the view's turn shaping (`turnView`) draws
/// both the same, and the view comparison below fails if it does not.
const NAMED: readonly { field: string; row: string; why: string; view: "same" | "differs" }[] = [
  {
    field: "user.turnId",
    row: "parity:1",
    why: "a turn is named by its prompt's rowId (`row.turn`), not acpmux's turn id; the view compares turn ids only with each other",
    view: "differs",
  },
  {
    field: "turnSummary.turnId",
    row: "parity:6",
    why: "as user.turnId",
    view: "differs",
  },
  {
    field: "permissionRecord.at",
    row: "parity:16",
    why: "the ask row is written when asked and patched with its answer; v1's receipt is a row at the answer",
    view: "differs",
  },
  {
    field: "row:activity",
    row: "r1-reply-1:11",
    why: "v1 runs a turn's calls and thoughts together in one activity row as its reducer meets them; the store has a row per call or thought",
    view: "same",
  },
  {
    field: "activity.items",
    row: "r1-reply-1:11",
    why: "as row:activity",
    view: "same",
  },
  {
    field: "activity.toolCount",
    row: "r1-reply-1:11",
    why: "as row:activity: v1 counts the run's calls, a store row has one",
    view: "same",
  },
];

/// Fields neither comparison reads, beside NAMED: what each side names a row by, never drawn.
const UNCOMPARED: readonly { field: string; why: string }[] = [
  {
    field: "id",
    why: "v1 names a row by its record, the store by `row-<rowId>`; units are matched by what both share instead (`units`)",
  },
  {
    field: "version",
    why: "v1 counts its own edits of a row, the store gives the row's `rev`; either only tells the view a row changed",
  },
];
const UNCOMPARED_KEYS = new Set(UNCOMPARED.map((entry) => entry.field));

/// What the view makes from a field on `notYet.ts` or UNCOMPARED, so it differs while that one does.
/// Each leaves with the field it is made from; one that no longer differs fails, as on the lists.
const DRAWN_FROM: readonly { field: string; from: readonly string[]; why: string }[] = [
  {
    field: "worked.at",
    from: ["user.at"],
    why: "a turn's fold is dated by its prompt",
  },
  {
    field: "turnSummary.turnWork",
    from: ["tool.startedAt", "tool.endedAt"],
    why: "the turn's waterfall holds the calls that have both times",
  },
  {
    field: "turnSummary.turnCopy",
    from: ["tool.startedAt", "tool.endedAt", "tool.provenance"],
    why: "the turn's copy holds its calls whole",
  },
  {
    field: "turnSummary.answerId",
    from: ["id"],
    why: "the turn's answer is named by its row's id",
  },
  {
    field: "turnSummary.retryRowId",
    from: ["id"],
    why: "the turn's Retry is named by its prompt row's id",
  },
  {
    field: "row:worked",
    from: ["row:permissionRecord"],
    why: "v1's receipt is the work of its turn, which the turn folds",
  },
  {
    field: "turnSummary.folded",
    from: ["row:permissionRecord"],
    why: "as row:worked",
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
  const post: ChatRowsPost = async (method, params) => (method === "chat.rows.open" ? { sid: params.sid } : {});
  const host = new ChatRowsHost(post, store, () => SID);
  await host.open("parity");
  const feed = chatRowsFeed(host, post);
  const folds: number[] = [];
  for (const { text, change } of changes) {
    if (change.kind === "chatPage") expect(host.page(SID, "after", { from: folds[0], fold: folds.shift() })).toBe(true);
    feed([text]);
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
/// row's calls and thoughts are units of their own, and the run is one more, keyed by its first
/// item: v1 runs calls and thoughts together and the store does not (NAMED).
function units(rows: readonly AcpmuxRow[]): Unit[] {
  const out: Unit[] = [];
  const seen = new Map<string, number>();
  const add = (base: string, kind: string, fields: Record<string, unknown>) => {
    const n = (seen.get(base) ?? 0) + 1;
    seen.set(base, n);
    const kept: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(fields))
      if (value !== undefined && !UNCOMPARED_KEYS.has(key)) kept[key] = value;
    out.push({ key: n > 1 ? `${base}#${n}` : base, kind, fields: kept });
  };
  const itemKey = (item: NonNullable<AcpmuxRow["items"]>[number]) =>
    item.tool ? `tool:${item.tool.id}` : `${item.kind}:${item.text}`;
  for (const row of rows) {
    if (row.kind === "activity") {
      const items = row.items ?? [];
      // The run itself: which items it holds, and its own fields.
      add(`activity:${items.map(itemKey)[0]}`, "activity", {
        items: items.map(itemKey),
        toolCount: row.toolCount,
        streaming: row.streaming,
      });
      for (const item of items) {
        if (item.tool) add(itemKey(item), "tool", { ...item.tool, text: item.text, at: row.at });
        else add(itemKey(item), item.kind, { ...item, at: row.at });
      }
      continue;
    }
    // The view's own rows (a turn's fold, its date) have no key both sides share but their place.
    const key =
      row.kind === "user"
        ? `user:${row.promptId}`
        : row.kind === "assistant"
          ? `assistant:${row.text}`
          : row.kind === "turnSummary"
            ? `turnSummary:${row.seq}`
            : row.kind === "permissionRecord"
              ? `permissionRecord:${row.permission?.permissionId}`
              : row.kind;
    add(key, row.kind, { ...row });
  }
  return out;
}

/// The same when drawn: a row held inside a field (a fold's rows) is read without its UNCOMPARED fields.
const drawn = (value: unknown) =>
  JSON.stringify(value, function (this: Record<string, unknown>, key, field) {
    return UNCOMPARED_KEYS.has(key) && typeof this.kind === "string" && typeof this.version === "number"
      ? undefined
      : field;
  });
const same = (a: unknown, b: unknown) => drawn(a) === drawn(b);

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

/// Every fold closed, as a chat opens, and every fold open, as a person who opens each one.
const FOLDS: readonly [string, Folds][] = [
  ["closed", new Set<string>()],
  ["open", { has: () => true, size: 1 }],
];

test("the view draws both the same: turnView over v1's rows and over the adapter's", async () => {
  const found = new Map<string, string[]>();
  for (const name of CORPUS) {
    const before = v1(name).rows;
    const after = adaptChat(await v2(name), { sessionId: SESSION }).rows;
    const now = Math.max(...before.map((row) => row.at)) + 60_000;
    for (const [folds, expanded] of FOLDS) {
      const rows = differences(units(turnView(before, expanded, { now })), units(turnView(after, expanded, { now })));
      for (const [key, example] of rows)
        found.set(key, [...(found.get(key) ?? []), `${name} (folds ${folds}): ${example}`]);
    }
  }
  // A difference of the rows only (NAMED `view: "same"`) is not allowed here.
  const allowed = new Set([
    ...NOT_YET.map((entry) => entry.field),
    ...NAMED.filter((entry) => entry.view === "differs").map((entry) => entry.field),
    ...DRAWN_FROM.map((entry) => entry.field),
  ]);
  for (const [key, examples] of found)
    console.log(`VIEW ${allowed.has(key) ? "listed" : "OFF THE LIST"} ${key} | ${examples[0]}`);
  expect([...found.keys()].filter((key) => !allowed.has(key))).toEqual([]);
  // A field made from another leaves with it, and stays only while it differs.
  const sources = new Set([...NOT_YET.map((entry) => entry.field), ...UNCOMPARED_KEYS]);
  expect(
    DRAWN_FROM.filter((entry) => !entry.from.every((field) => sources.has(field))).map((entry) => entry.field),
  ).toEqual([]);
  expect(DRAWN_FROM.map((entry) => entry.field).filter((field) => !found.has(field))).toEqual([]);
});

/// The `<kind>.<field>` keys v1 draws anywhere in the corpus, with `row:<kind>` for each kind, and
/// `snapshot.<field>` for what v1's last snapshot holds that is not empty.
async function shownByCorpus(): Promise<Set<string>> {
  const shown = new Set<string>();
  const empty = (value: unknown) =>
    value === undefined ||
    value === null ||
    value === false ||
    (Array.isArray(value) && value.length === 0) ||
    (value instanceof Map && value.size === 0) ||
    (typeof value === "object" && !Array.isArray(value) && !(value instanceof Map) && Object.keys(value).length === 0);
  for (const name of CORPUS) {
    const snapshot = v1(name);
    for (const unit of units(snapshot.rows)) {
      shown.add(`row:${unit.kind}`);
      for (const field of Object.keys(unit.fields)) shown.add(`${unit.kind}.${field}`);
    }
    // `permissionGroups` is the page's permission client state; what FIELDS.md names is its groups.
    for (const [field, value] of Object.entries(snapshot))
      if (!empty(field === "permissionGroups" ? snapshot.permissionGroups?.groups : value))
        shown.add(`snapshot.${field}`);
    for (const entry of snapshot.queue)
      for (const [field, value] of Object.entries(entry)) if (!empty(value)) shown.add(`queue.${field}`);
  }
  return shown;
}

/// The names FIELDS.md's "Not yet" gives in backquotes that are not one field the view reads: a
/// type, a method or a wire name, each with what it stands for.
const NOT_A_FIELD = new Map<string, string>([
  ["QueueItem", "the queue entry's wire type; its new fields are named one by one"],
  ["queue", "the snapshot's queue, compared whole (home d); its new fields are named one by one"],
  ["_acpmux/view", "the method that carries presence, typing and the read mark"],
  ["page {turns: true}", "the request for a page of turns"],
  ["tasks: [{sessionId, name?, harness?}]", "the shape of `tasks`"],
  ["background_turn", "the record a background turn comes from"],
]);

test("each field FIELDS.md has not yet is on one of notYet's lists, and the corpus shows none of the second", async () => {
  const text = readFileSync(`${import.meta.dir}/FIELDS.md`, "utf8");
  const section = text.slice(text.indexOf("\n## Not yet"));
  const names = new Set(
    [...section.matchAll(/`([^`]+)`/g)].map((match) => match[1]!).filter((name) => !NOT_A_FIELD.has(name)),
  );
  // FIELDS.md names the field (`<kind>.<field>` ends with it), the record a row is (`row:<kind>`),
  // or a name the entry covers.
  const entries = [...NOT_YET, ...NOT_IN_CORPUS];
  const placed = (name: string) =>
    entries.some(
      (entry) =>
        entry.field === name ||
        entry.field === `row:${name}` ||
        entry.field.endsWith(`.${name}`) ||
        entry.covers?.includes(name),
    );
  const shown = await shownByCorpus();
  console.log(`SHOWN ${[...shown].sort().join(" ")}`);
  const unplaced = [...names].filter((name) => !placed(name)).sort();
  console.log(`UNPLACED ${unplaced.join(" ")}`);
  expect(unplaced).toEqual([]);
  // The corpus showing one is a row to compare: it moves to NOT_YET, or off both lists once it draws the same.
  expect(NOT_IN_CORPUS.map((entry) => entry.field).filter((field) => shown.has(field))).toEqual([]);
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
