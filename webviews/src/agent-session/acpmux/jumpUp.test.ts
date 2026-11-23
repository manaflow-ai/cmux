// l10n-allow-file: test fixture prompts, not shipped UI.
// Jump up's "sent" mark (jumpUp.ts `lastOwnPrompt`) is the last prompt the reader sent by hand: never
// another agent's message, a task's result, the Chief's message to a subagent, or another person's
// prompt in a shared chat (Leo, 2026-11-10: "jumping up since like the last time you interacted
// manually").
import { expect, jest, test } from "bun:test";
import type { AcpmuxRow } from "./model";
import {
  IDLE_KEEP_MS,
  IdleTracker,
  keepIdle,
  keptIdle,
  lastOwnPrompt,
  loadIdle,
  ownPrompt,
  readerScrolled,
  readerSent,
  settleIdle,
  type IdleMark,
  type ManualMark,
  type PromptScan,
} from "./jumpUp";

const row = (id: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at: Number(id.replace(/\D/g, "")) || 0,
  kind: "user",
  text: id,
  ...extra,
});
const reply = (id: string): AcpmuxRow => ({ id, version: 1, at: 0, kind: "agent", text: "ok" });
const scan = (): { current: PromptScan } => ({ current: { length: 0 } });

test("the last prompt the reader sent, past the prompts they did not type", () => {
  const rows: AcpmuxRow[] = [
    row("typed-1"),
    reply("reply-1"),
    row("typed-2"),
    reply("reply-2"),
    row("task-result-3", { untyped: true }),
    row("agent-message-4", { incoming: { kind: "message" } as AcpmuxRow["incoming"] }),
    row("chief-5", { from: "chief" }),
    reply("reply-3"),
  ];
  expect(lastOwnPrompt(rows, scan())?.id).toBe("typed-2");
  const noneTyped = rows.filter((each) => each.kind !== "user" || each.untyped);
  expect(lastOwnPrompt(noneTyped, scan())).toBeUndefined();
});

test("in a shared chat, yours is the one with your author: none for the owner, your id for a guest", () => {
  const guest = { id: "guest-1", name: "Sam" };
  const other = { id: "guest-2", name: "Kim" };
  const rows: AcpmuxRow[] = [row("owner-1"), row("guest-2", { author: guest }), row("other-3", { author: other })];
  expect(lastOwnPrompt(rows, scan())?.id).toBe("owner-1");
  expect(lastOwnPrompt(rows, scan(), "guest-1")?.id).toBe("guest-2");
  expect(lastOwnPrompt(rows, scan(), "guest-3")).toBeUndefined();
  expect(ownPrompt(rows[2]!, "guest-2")).toBe(true);
});

test("appended rows are scanned alone, and another person's prompt after yours does not move the mark", () => {
  const memo = scan();
  const rows: AcpmuxRow[] = [row("owner-1"), reply("reply-1")];
  expect(lastOwnPrompt(rows, memo)?.id).toBe("owner-1");
  const more = [...rows, row("guest-2", { author: { id: "guest-1", name: "Sam" } }), reply("reply-2")];
  expect(lastOwnPrompt(more, memo)?.id).toBe("owner-1");
  expect(memo.current.length).toBe(4);
  const mine = [...more, row("owner-3")];
  expect(lastOwnPrompt(mine, memo)?.id).toBe("owner-3");
});

test("a new author id scans again rather than keeping the last author's prompt", () => {
  const memo = scan();
  const rows: AcpmuxRow[] = [row("owner-1"), row("guest-2", { author: { id: "guest-1", name: "Sam" } })];
  expect(lastOwnPrompt(rows, memo)?.id).toBe("owner-1");
  expect(lastOwnPrompt(rows, memo, "guest-1")?.id).toBe("guest-2");
});

// Jump up's mark is idle detection (Leo, 2026-11-12: "when you have, like, at least one full screen
// of idleness, that's when it starts having that... instead of getting overwritten by some useless
// noise"): set where the reader's view was once a screen of new content came in below it, and moved
// only by the reader's own acts.
const VIEW = 600;
const mark5: ManualMark = { place: { rowId: "r5", offset: 0 }, at: 3, why: "idle" };
/// A transcript: each row's layout top, and the whole height.
const laid = (tops: Record<string, number>, totalHeight: number, lastPrompt?: string, now = 1) => ({
  topOf: (place: { rowId: string; offset: number }) =>
    tops[place.rowId] === undefined ? undefined : tops[place.rowId]! + place.offset,
  totalHeight,
  viewHeight: VIEW,
  lastPrompt,
  now,
});
const pinned = { read: { place: { rowId: "r5", offset: 0 }, below: 800 }, prompt: "p1", mark: mark5 };

test("idle while a full screen of new content arrives below the reader's place pins the mark there", () => {
  let state = readerScrolled({ prompt: "p1" }, { rowId: "r5", offset: 20 });
  state = settleIdle(state, laid({ r5: 1_000 }, 1_820, "p1"));
  expect(state.mark).toBeUndefined();
  expect(state.read?.below).toBe(800);
  // Less than a screen more: not yet.
  state = settleIdle(state, laid({ r5: 1_000 }, 2_410, "p1"));
  expect(state.mark).toBeUndefined();
  state = settleIdle(state, laid({ r5: 1_000 }, 2_420, "p1", 7));
  expect(state.mark).toEqual({ place: { rowId: "r5", offset: 20 }, at: 7, why: "idle" });
  // Pinned: more content, a later time, nothing moves it.
  const held = state;
  expect(settleIdle(held, laid({ r5: 1_000 }, 9_000, "p1", 99))).toBe(held);
});

test("a running turn's rows count, though they land above its live line, which stays the last row", () => {
  // Sent: the prompt's row comes with the turn's live line right after it.
  let state = settleIdle(readerSent({ prompt: "p1" }, undefined, 0), laid({ p2: 1_000, live: 1_100 }, 1_140, "p2"));
  expect(state.read?.place.rowId).toBe("p2");
  // The reply streams in above the live line: the line moves down with it, still last.
  state = settleIdle(state, laid({ p2: 1_000, a1: 1_100, live: 1_500 }, 1_540, "p2"));
  expect(state.mark).toBeUndefined();
  state = settleIdle(state, laid({ p2: 1_000, a1: 1_100, t1: 1_500, live: 1_700 }, 1_740, "p2"));
  expect(state.mark?.place.rowId).toBe("p2");
});

test("older pages landing above, rows folding and a reload's layout never pin the mark by themselves", () => {
  let state = readerScrolled({ prompt: null }, { rowId: "r5", offset: 0 });
  state = settleIdle(state, laid({ r5: 1_000 }, 1_800));
  // A page of history lands above, and rows above measure taller: the place and the total move together.
  state = settleIdle(state, laid({ r5: 5_000 }, 5_800));
  expect(state.mark).toBeUndefined();
  // A row below folds (or a turn's live line goes), then opens again: only content past the lowest
  // point counts as new.
  state = settleIdle(state, laid({ r5: 5_000 }, 5_300));
  state = settleIdle(state, laid({ r5: 5_000 }, 5_800));
  expect(state.mark).toBeUndefined();
  // A reload keeps the place, not the measure, so its own layout is measured afresh.
  const reloaded = keptIdle(state);
  expect(reloaded.read?.below).toBeUndefined();
  let again = settleIdle(reloaded, laid({ r5: 1_000 }, 3_000, "p1"));
  expect(again.mark).toBeUndefined();
  again = settleIdle(again, laid({ r5: 1_000 }, 3_000 + VIEW, "p1"));
  expect(again.mark?.place.rowId).toBe("r5");
});

test("a restart, reconnect, notice rows or the view's own moves never change a pinned mark", () => {
  // Reconnect: the same rows again. Notice and status rows: more height below. Neither is an act.
  expect(settleIdle(pinned, laid({ r5: 1_000 }, 1_800, "p1"))).toBe(pinned);
  expect(settleIdle(pinned, laid({ r5: 1_000, notice: 1_800 }, 9_900, "p1"))).toBe(pinned);
  // Its row not loaded (a rebuild, a page not in yet): it waits, unchanged.
  expect(settleIdle(pinned, laid({}, 400, "p1"))).toBe(pinned);
  // A restart or update reload keeps it whole and measures nothing new until the reader acts.
  const reloaded = keptIdle(pinned);
  expect(reloaded.mark).toEqual(mark5);
  const opened = settleIdle(reloaded, laid({ r5: 1_000 }, 9_000, "p1"));
  expect(opened.mark).toEqual(mark5);
  expect(opened.prompt).toBe("p1");
  expect(settleIdle(opened, laid({ r5: 1_000 }, 20_000, "p1"))).toBe(opened);
});

test("the reader's own acts replace it: a scroll by hand starts a new stretch, a send starts one at the prompt", () => {
  const scrolled = readerScrolled(pinned, { rowId: "r9", offset: 4 });
  expect(scrolled).toEqual({ read: { place: { rowId: "r9", offset: 4 } }, prompt: "p1" });
  // A send: the mark goes, and the stretch starts at the prompt's row once it comes.
  const sending = readerSent(pinned, { id: "p1", at: 0 }, 60_000);
  expect(sending.mark).toBeUndefined();
  const sent = settleIdle(sending, laid({ r5: 1_000, p2: 2_000 }, 2_100, "p2"));
  expect(sent.sent).toBeUndefined();
  expect(sent.read?.place).toEqual({ rowId: "p2", offset: 0 });
  // A screen of reply after it pins the mark at the prompt.
  const replied = settleIdle(sent, laid({ p2: 2_000, a1: 2_100 }, 2_700, "p2"));
  expect(replied.mark?.place.rowId).toBe("p2");
  // The prompt's row drawn in the send's own commit (already noted): the stretch starts there at once.
  const noted = { ...pinned, prompt: "p3" };
  expect(readerSent(noted, { id: "p3", at: 60_000 }, 60_200)).toEqual({
    read: { place: { rowId: "p3", offset: 0 } },
    prompt: "p3",
  });
});

test("a prompt that turns up without a send (a reconnect redraws a lost one) leaves the mark", () => {
  const redrawn = settleIdle(pinned, laid({ r5: 1_000, "local-p2": 2_000 }, 2_100, "local-p2"));
  expect(redrawn.mark).toEqual(mark5);
  expect(redrawn.read?.place.rowId).toBe("r5");
  expect(redrawn.prompt).toBe("local-p2");
});

test("on a chat's first load the newest prompt is noted, not a send; with nothing kept the stretch starts there", () => {
  const fresh = settleIdle({}, laid({ p1: 200, a1: 300 }, 900, "p1"));
  expect(fresh).toEqual({ read: { place: { rowId: "p1", offset: 0 }, below: 700 }, prompt: "p1" });
  const kept = settleIdle({ read: { place: { rowId: "r5", offset: 0 } } }, laid({ p1: 200, r5: 600 }, 900, "p1"));
  expect(kept.read?.place.rowId).toBe("r5");
  expect(kept.prompt).toBe("p1");
});

test("the stretch is kept per chat and read back; bad or missing storage keeps nothing", () => {
  const store = new Map<string, string>();
  const storage = {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => void store.set(key, value),
  };
  keepIdle(storage, "chat-a", { ...pinned, read: { place: { rowId: "r5", offset: 3 }, below: 10 } });
  keepIdle(storage, "chat-b", { read: { place: { rowId: "x", offset: 0 } } });
  expect(loadIdle(storage, "chat-a")).toEqual({ read: { place: { rowId: "r5", offset: 3 } }, mark: mark5 });
  expect(loadIdle(storage, "chat-b")).toEqual({ read: { place: { rowId: "x", offset: 0 } } });
  expect(loadIdle(storage, "chat-c")).toEqual({});
  keepIdle(storage, "chat-a", {});
  expect(loadIdle(storage, "chat-a")).toEqual({});
  store.set("cmux.acpmux.jumpUpIdle", "{nope");
  expect(loadIdle(storage, "chat-b")).toEqual({});
  expect(loadIdle(undefined, "chat-b")).toEqual({});
  const full = {
    getItem: () => null,
    setItem: () => {
      throw new Error("full");
    },
  };
  expect(() => keepIdle(full, "chat-a", { mark: mark5 })).not.toThrow();
});

test("the tracker keeps a chat's stretch after its steps settle, at once on a switch or keepNow, never its measure", () => {
  jest.useFakeTimers();
  const data = new Map<string, string>();
  const store = {
    getItem: (key: string) => data.get(key) ?? null,
    setItem: (key: string, value: string) => void data.set(key, value),
  };
  try {
    const tracker = new IdleTracker(() => store);
    tracker.open("a", true);
    tracker.scrolled({ rowId: "r1", offset: 0 });
    expect(loadIdle(store, "a").read).toBeUndefined();
    jest.advanceTimersByTime(IDLE_KEEP_MS);
    expect(loadIdle(store, "a").read?.place.rowId).toBe("r1");
    // A change no render read yet goes with a switch, at once.
    tracker.scrolled({ rowId: "r2", offset: 0 });
    tracker.open("b", true);
    expect(loadIdle(store, "a").read?.place.rowId).toBe("r2");
    expect(tracker.state).toEqual({});
    tracker.scrolled({ rowId: "b1", offset: 0 });
    tracker.keepNow();
    expect(loadIdle(store, "b").read?.place.rowId).toBe("b1");
    // Reopening reads back what was kept; a disabled tracker keeps and changes nothing.
    tracker.open("a", true);
    expect(tracker.state.read?.place.rowId).toBe("r2");
    const off = new IdleTracker(() => store);
    off.open("c", false);
    off.scrolled({ rowId: "c1", offset: 0 });
    off.keepNow();
    expect(loadIdle(store, "c")).toEqual({});
  } finally {
    jest.useRealTimers();
  }
});

/// A layout of `rows` (id, version, time, drawn height) for the measure that tells new content from
/// rows measuring or folding; the place row is first.
const drawn = (rows: [string, number, number, number][], lastPrompt?: string, now = 1) => {
  const tops: number[] = [];
  let total = 0;
  for (const [, , , height] of rows) {
    tops.push(total);
    total += height;
  }
  const list = rows.map(([id, version, at]) => ({ id, version, at }));
  const indexOf = (place: { rowId: string }) => list.findIndex((row) => row.id === place.rowId);
  return {
    topOf: (place: { rowId: string; offset: number }) => {
      const index = indexOf(place);
      return index >= 0 ? tops[index]! + place.offset : undefined;
    },
    totalHeight: total,
    viewHeight: VIEW,
    lastPrompt,
    now,
    rows: list,
    heightAt: (index: number) => rows[index]![3],
    indexOf,
  };
};

test("rows measuring taller on a reload, or a section folding and opening, are no new content", () => {
  let state: IdleMark = { read: { place: { rowId: "r5", offset: 0 } }, prompt: null };
  // A reload's estimates: then every row below measures to its drawn height, 600 px more in all.
  state = settleIdle(
    state,
    drawn([
      ["r5", 1, 50, 100],
      ["a1", 1, 51, 200],
      ["a2", 1, 52, 200],
    ]),
  );
  state = settleIdle(
    state,
    drawn([
      ["r5", 1, 50, 100],
      ["a1", 1, 51, 500],
      ["a2", 1, 52, 500],
    ]),
  );
  expect(state.mark).toBeUndefined();
  // A section folds away (its rows go) and opens 800 px tall again: its rows keep their times.
  state = settleIdle(
    state,
    drawn([
      ["r5", 1, 50, 100],
      ["a2", 1, 52, 500],
    ]),
  );
  state = settleIdle(
    state,
    drawn([
      ["r5", 1, 50, 100],
      ["a1", 1, 51, 500],
      ["x1", 1, 51, 800],
      ["a2", 1, 52, 500],
    ]),
  );
  expect(state.mark).toBeUndefined();
  // A row that came in since, a screen tall: new content.
  state = settleIdle(
    state,
    drawn(
      [
        ["r5", 1, 50, 100],
        ["a1", 1, 51, 500],
        ["a2", 1, 52, 500],
        ["n1", 1, 60, VIEW],
      ],
      undefined,
      9,
    ),
  );
  expect(state.mark).toEqual({ place: { rowId: "r5", offset: 0 }, at: 9, why: "idle" });
});

test("a reply streaming on (its version moving) counts its growth; a running turn's rows above its live line count", () => {
  let state: IdleMark = { read: { place: { rowId: "p1", offset: 0 } }, prompt: null };
  state = settleIdle(
    state,
    drawn([
      ["p1", 1, 10, 80],
      ["reply", 1, 11, 100],
      ["live", 1, 11, 40],
    ]),
  );
  state = settleIdle(
    state,
    drawn([
      ["p1", 1, 10, 80],
      ["reply", 2, 11, 100 + VIEW / 2],
      ["live", 1, 11, 40],
    ]),
  );
  expect(state.mark).toBeUndefined();
  state = settleIdle(
    state,
    drawn([
      ["p1", 1, 10, 80],
      ["reply", 2, 11, 100 + VIEW / 2],
      ["tool", 1, 12, VIEW / 2],
      ["live", 1, 11, 40],
    ]),
  );
  expect(state.mark?.place.rowId).toBe("p1");
});
