// l10n-allow-file: test fixture chat names and steps, not shipped UI.
// Steer queue (steerQueue/model.ts, log.ts): which chats it lists and in what order, and the
// person's record of where they stepped in.
import { describe, expect, test } from "bun:test";
import { readSteerLog, recordSteer, STEER_LOG_KEY, STEER_LOG_LIMIT } from "../src/agent-session/acpmux/steerQueue/log";
import {
  nextFocus,
  STALLED_MS,
  STEER_QUEUE_LIMIT,
  steerQueue,
  steerReason,
} from "../src/agent-session/acpmux/steerQueue/model";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";

const NOW = 1_800_000_000_000;
const ago = (minutes: number) => NOW - minutes * 60_000;
const chat = (sessionId: string, fields: Partial<AcpmuxSessionEntry> = {}): AcpmuxSessionEntry => ({
  sessionId,
  title: sessionId,
  harness: "claude",
  updatedAt: ago(1),
  ...fields,
});

describe("steerReason", () => {
  test("an ask, a failure, a quiet turn, a running turn and an unread finish", () => {
    expect(steerReason(chat("a", { pendingPermissions: 1, indicator: "input" }), NOW)).toBe("ask");
    expect(steerReason(chat("a", { waitingOn: { on: "question", prompt: "Which tag?" } }), NOW)).toBe("ask");
    expect(steerReason(chat("f", { indicator: "failed" }), NOW)).toBe("failed");
    expect(steerReason(chat("r", { indicator: "working", updatedAt: ago(1) }), NOW)).toBe("running");
    expect(steerReason(chat("s", { indicator: "working", activityAt: NOW - STALLED_MS, updatedAt: ago(0) }), NOW)).toBe(
      "stalled",
    );
    expect(steerReason(chat("d", { indicator: "done", unread: true }), NOW)).toBe("review");
  });

  test("a lost machine is a failure, never an ask nobody can answer", () => {
    expect(steerReason(chat("l", { indicator: "lost", pendingPermissions: 1 }), NOW)).toBe("failed");
  });

  test("a local chat acpmux says is running is not an ask, whatever its dot last said", () => {
    expect(steerReason(chat("x", { indicator: "input", status: "running" }), NOW)).toBe("running");
    expect(steerReason(chat("x", { indicator: "input", peer: "build-box", status: "running" }), NOW)).toBe("ask");
    expect(steerReason(chat("x", { indicator: "input" }), NOW)).toBe("ask");
  });

  test("an idle chat already read needs nothing", () => {
    expect(steerReason(chat("i", { indicator: "done" }), NOW)).toBeUndefined();
    expect(steerReason(chat("i", { status: "idle" }), NOW)).toBeUndefined();
  });
});

describe("steerQueue", () => {
  const sessions = [
    chat("review-old", { indicator: "done", unread: true, updatedAt: ago(30), preview: "Done with the strings." }),
    chat("running", { indicator: "working", updatedAt: ago(1), doing: "Running bun test" }),
    chat("review-new", { indicator: "done", unread: true, updatedAt: ago(2) }),
    chat("ask-new", { pendingPermissions: 1, updatedAt: ago(1), doing: "Run lint" }),
    chat("stalled", { indicator: "working", updatedAt: ago(9), doing: "Waiting for CI" }),
    chat("ask-old", { waitingOn: { on: "question", prompt: "Which tag?" }, updatedAt: ago(12) }),
    chat("failed", { indicator: "failed", laneError: "The agent exited", updatedAt: ago(3) }),
    chat("idle", { indicator: "done" }),
  ];

  test("asks first, then failures, quiet turns, unread finishes and running turns", () => {
    expect(steerQueue({ sessions, now: NOW }).map((item) => item.sessionId)).toEqual([
      // The longest wait first among asks; the newest first among finished chats.
      "ask-old",
      "ask-new",
      "failed",
      "stalled",
      "review-new",
      "review-old",
      "running",
    ]);
  });

  test("each row says what the chat waits on, failed with or is doing", () => {
    const byId = new Map(steerQueue({ sessions, now: NOW }).map((item) => [item.sessionId, item]));
    expect(byId.get("ask-old")?.line).toBe("Which tag?");
    expect(byId.get("failed")?.line).toBe("The agent exited");
    expect(byId.get("stalled")?.line).toBe("Waiting for CI");
    expect(byId.get("review-old")?.line).toBe("Done with the strings.");
    expect(byId.get("running")?.running).toBe(true);
    expect(byId.get("stalled")?.running).toBe(true);
    expect(byId.get("ask-old")?.running).toBe(false);
  });

  test("archived, side and folded child chats stay off; a child that asks lists on its own", () => {
    const listed = steerQueue({
      now: NOW,
      sessions: [
        chat("parent", { indicator: "working" }),
        chat("child", { indicator: "working", spawnedBy: "parent" }),
        chat("asking-child", { pendingPermissions: 1, spawnedBy: "parent" }),
        chat("archived", { indicator: "working", archived: true }),
        chat("side", { indicator: "working", side: true }),
        chat("unsent", { indicator: "working", unsent: true }),
      ],
    }).map((item) => item.sessionId);
    expect(listed).toEqual(["asking-child", "parent"]);
  });

  test("it draws at most nine chats however many acpmux lists", () => {
    const many = Array.from({ length: 400 }, (_, index) => chat(`c${index}`, { indicator: "working" }));
    expect(steerQueue({ sessions: many, now: NOW })).toHaveLength(STEER_QUEUE_LIMIT);
  });

  test("a row carries the person's latest step into its chat", () => {
    const log = [
      { sessionId: "running", act: "steer" as const, text: "first", at: ago(5) },
      { sessionId: "running", act: "redirect" as const, text: "second", at: ago(2) },
    ];
    const item = steerQueue({ sessions, now: NOW, log }).find((entry) => entry.sessionId === "running");
    expect(item?.last).toEqual(log[1]);
  });

  test("a cloud chat names its machine; a local one does not", () => {
    const items = steerQueue({
      now: NOW,
      sessions: [
        chat("cloud", { indicator: "working", hostKind: "cloud", host: "hearty-beige-elk" }),
        chat("local", { indicator: "working", hostKind: "local", host: "This Mac" }),
      ],
    });
    expect(items.find((item) => item.sessionId === "cloud")?.host).toBe("hearty-beige-elk");
    expect(items.find((item) => item.sessionId === "local")?.host).toBeUndefined();
  });
});

test("after a step the focus goes on down the list, or back from the last row", () => {
  expect(nextFocus(3, 0)).toBe(1);
  expect(nextFocus(3, 2)).toBe(1);
  expect(nextFocus(1, 0)).toBe(0);
});

describe("steer log", () => {
  const memory = () => {
    const store = new Map<string, string>();
    return {
      getItem: (key: string) => store.get(key) ?? null,
      setItem: (key: string, value: string) => void store.set(key, value),
    };
  };

  test("a step is saved and read back; a bad record reads as none", () => {
    const storage = memory();
    const log = recordSteer([], { sessionId: "s", act: "steer", text: "Check dark mode", at: 1 }, storage);
    expect(readSteerLog(storage)).toEqual(log);
    storage.setItem(STEER_LOG_KEY, "{not json");
    expect(readSteerLog(storage)).toEqual([]);
    storage.setItem(STEER_LOG_KEY, JSON.stringify([{ sessionId: "s", act: "explode", at: 1 }]));
    expect(readSteerLog(storage)).toEqual([]);
  });

  test("the record keeps only the newest steps and a short copy of each line", () => {
    const storage = memory();
    let log = recordSteer([], { sessionId: "s", act: "steer", text: "x".repeat(1000), at: 0 }, storage);
    expect(log[0]?.text).toHaveLength(280);
    for (let at = 1; at <= STEER_LOG_LIMIT + 10; at += 1)
      log = recordSteer(log, { sessionId: "s", act: "stop", at }, storage);
    expect(log).toHaveLength(STEER_LOG_LIMIT);
    expect(log[0]?.at).toBe(11);
  });
});
