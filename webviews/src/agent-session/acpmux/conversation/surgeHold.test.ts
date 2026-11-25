// l10n-allow-file: test fixtures.
// The held surge's one row (surgeHold.ts): the newest snapshot by seq, the panel's threads and search.
import { expect, test } from "bun:test";
import { heldNotice, heldThreads, newerSurge, searchThreads, surgeCounts, surgeOfEvent, surgeShows } from "./surgeHold";

test("a held inbox event carries the cumulative snapshot; an ordinary inbox event carries none", () => {
  const msg = { surgeHeld: true, surge: { held: 12, needYou: 2 }, threadId: "from:lane", promptId: "p1" };
  expect(surgeOfEvent("inbox", msg, 40, 1000)).toEqual({ held: 12, needYou: 2, seq: 40, at: 1000 });
  expect(surgeOfEvent("inbox", { ...msg, surgeHeld: undefined }, 40)).toBeUndefined();
  expect(surgeOfEvent("inbox", { surgeHeld: true }, 40)).toBeUndefined();
  expect(surgeOfEvent("inbox_triaged", { surge: { held: 3, needYou: 0 } }, 41)).toEqual({
    held: 3,
    needYou: 0,
    seq: 41,
  });
  expect(surgeOfEvent("inbox_read", { surge: { held: 3 } }, 42)).toBeUndefined();
});

test("counts are whole and never negative; a missing count is zero", () => {
  expect(surgeCounts({ held: 4.7 })).toEqual({ held: 4, needYou: 0 });
  expect(surgeCounts({ held: -1, needYou: "2" })).toBeUndefined();
  expect(surgeCounts(null)).toBeUndefined();
});

test("the row keeps the newest snapshot by seq, so an older page read later never moves it back", () => {
  const live = { held: 30, needYou: 3, seq: 90 };
  expect(newerSurge(live, { held: 5, needYou: 0, seq: 12 })).toBe(live);
  const triaged = { held: 0, needYou: 0, seq: 91 };
  expect(newerSurge(live, triaged)).toBe(triaged);
  expect(newerSurge(undefined, live)).toBe(live);
  expect(newerSurge(live, undefined)).toBe(live);
});

test("the row shows while something is held or needs the person, and hides at zero", () => {
  expect(surgeShows({ held: 0, needYou: 0, seq: 1 })).toBe(false);
  expect(surgeShows({ held: 1, needYou: 0, seq: 1 })).toBe(true);
  expect(surgeShows({ held: 0, needYou: 1, seq: 1 })).toBe(true);
  expect(surgeShows(undefined)).toBe(false);
});

const listing = {
  sessionId: "s",
  surge: { held: 3, needYou: 1 },
  threads: [
    {
      threadId: "from:ci-bot",
      label: "",
      from: ["ci-bot"],
      count: 9,
      newestAt: 300,
      newestPreview: "runner queue busy",
      class: "fyi",
      surgeHeld: true,
    },
    {
      threadId: "pr:48001",
      label: "#48001",
      from: ["lane-7"],
      count: 1,
      newestAt: 100,
      newestPreview: "can I land?",
      class: "blocker",
      surgeHeld: true,
      sender: { session: "abc", label: "lane-7" },
    },
    {
      threadId: "from:coord",
      label: "",
      from: ["coord"],
      count: 1,
      newestAt: 400,
      newestPreview: "not held",
      class: "fyi",
    },
  ],
};

test("a listing that marks held threads lists only those, the ones that need the person first", () => {
  const threads = heldThreads(listing);
  expect(threads.map((t) => t.threadId)).toEqual(["pr:48001", "from:ci-bot"]);
  expect(threads[0]).toMatchObject({
    blocker: true,
    fromSession: "abc",
    sender: { session: "abc", label: "lane-7" },
    count: 1,
  });
  expect(threads[1]).toMatchObject({ blocker: false, count: 9, preview: "runner queue busy" });
});

test("the daemon's needYou, not the urgent class, says which threads need the person", () => {
  // An agent's question to this chat's agent is urgent yet not the person's (Leo, 2026-11-23:
  // "not only do thees probably not need me").
  const rows = listing.threads.map((row) => ({ ...row, needYou: row.threadId === "from:ci-bot" }));
  const threads = heldThreads({ threads: rows });
  expect(threads.map((t) => [t.threadId, t.blocker])).toEqual([
    ["from:ci-bot", true],
    ["pr:48001", false],
  ]);
});

test("a listing that marks none lists every thread, newest first", () => {
  const unmarked = { threads: listing.threads.map(({ surgeHeld: _, ...rest }) => rest) };
  expect(heldThreads(unmarked).map((t) => t.threadId)).toEqual(["pr:48001", "from:coord", "from:ci-bot"]);
  expect(heldThreads(null)).toEqual([]);
  expect(heldThreads({ threads: [null, { label: "no id" }] })).toEqual([]);
});

test("search keeps threads holding every word in their label, senders or preview, case folded", () => {
  const threads = heldThreads(listing);
  expect(searchThreads(threads, "").length).toBe(2);
  expect(searchThreads(threads, "RUNNER busy").map((t) => t.threadId)).toEqual(["from:ci-bot"]);
  expect(searchThreads(threads, "48001").map((t) => t.threadId)).toEqual(["pr:48001"]);
  expect(searchThreads(threads, "lane-7 land").map((t) => t.threadId)).toEqual(["pr:48001"]);
  expect(searchThreads(threads, "nothing here")).toEqual([]);
});

test("the panel draws a page of threads at a time", () => {
  const many = heldThreads({
    threads: Array.from({ length: 45 }, (_, i) => ({ threadId: `t${i}`, newestAt: i, newestPreview: `m${i}` })),
  });
  expect(heldNotice(many, 20).threads.length).toBe(20);
  expect(heldNotice(many, 60).threads.length).toBe(45);
});
