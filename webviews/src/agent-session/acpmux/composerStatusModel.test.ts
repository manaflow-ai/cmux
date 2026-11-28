// The composer status dot's data (composerStatusModel.ts) and its card's table (peekPin.ts over
// schemas/composer-status/peek-pin.json): every row of the table, what shows when, one item per kind
// worst first, and a words key this build does not know.
import { describe, expect, test } from "bun:test";
import {
  dedupe,
  hostRecoveryItem,
  nextWake,
  readComposerStatus,
  readStatusItem,
  shown,
  statusDueAt,
  statusWordsKey,
  worstLevel,
  type StatusItem,
} from "./composerStatusModel";
import { CONNECTION_QUIET_MS } from "../../ui/lasting";
import { readPeerLinkDetail } from "./linkState";
import { PEEK_PIN_TABLE, peekPin, peekPinOpen } from "./peekPin";

const item = (over: Partial<StatusItem>): StatusItem => ({
  kind: "machineLink",
  level: "info",
  words: "status.machineLink.reconnecting",
  ...over,
});

describe("peek-pin table", () => {
  test("every row is what the reducer does", () => {
    for (const row of PEEK_PIN_TABLE.transitions)
      expect(peekPin(row.from, row.on)).toEqual({ state: row.to, effects: row.effects });
  });

  test("rows name only the table's states, events and effects, once each", () => {
    const seen = new Set<string>();
    for (const row of PEEK_PIN_TABLE.transitions) {
      expect(PEEK_PIN_TABLE.states).toContain(row.from);
      expect(PEEK_PIN_TABLE.states).toContain(row.to);
      expect(PEEK_PIN_TABLE.events).toContain(row.on);
      for (const effect of row.effects) expect(PEEK_PIN_TABLE.effects).toContain(effect);
      expect(seen.has(`${row.from} ${row.on}`)).toBe(false);
      seen.add(`${row.from} ${row.on}`);
    }
  });

  test("a pair with no row stays and does nothing: pinned ignores hover", () => {
    for (const state of PEEK_PIN_TABLE.states)
      for (const event of PEEK_PIN_TABLE.events) {
        if (PEEK_PIN_TABLE.transitions.some((row) => row.from === state && row.on === event)) continue;
        expect(peekPin(state, event)).toEqual({ state, effects: [] });
      }
    expect(peekPin("pinned", "hoverIntent").state).toBe("pinned");
    expect(peekPin("pinned", "hoverEnd").state).toBe("pinned");
  });

  test("the rules: hover peeks, a click pins, a click on a pin holds off the peek until the pointer leaves", () => {
    expect(peekPin("closed", "hoverIntent").state).toBe("peek");
    expect(peekPin("peek", "clickDot").state).toBe("pinned");
    expect(peekPin("peek", "pressCard").state).toBe("pinned");
    expect(peekPin("closed", "clickDot").state).toBe("pinned");
    expect(peekPin("pinned", "clickDot").state).toBe("held");
    expect(peekPin("held", "hoverIntent").state).toBe("held");
    expect(peekPin("held", "pointerLeaveDot").state).toBe("closed");
    expect(peekPin("pinned", "escape").effects).toContain("focusDot");
    expect(peekPin("closed", "keyActivate").effects).toContain("focusCard");
    expect(["closed", "peek", "pinned", "held"].filter((s) => peekPinOpen(s as never))).toEqual(["peek", "pinned"]);
  });
});

describe("items", () => {
  test("shown keeps items with no showAt or one past, and the one timer wakes at the earliest still to come", () => {
    const items = [item({ showAt: 100 }), item({ kind: "stuck", showAt: 300 }), item({ kind: "queuePaused" })];
    expect(shown(items, 50).map((each) => each.kind)).toEqual(["queuePaused"]);
    expect(shown(items, 100).map((each) => each.kind)).toEqual(["machineLink", "queuePaused"]);
    expect(
      nextWake(
        items.map((each) => each.showAt),
        50,
      ),
    ).toBe(100);
    expect(
      nextWake(
        items.map((each) => each.showAt),
        100,
      ),
    ).toBe(300);
    expect(
      nextWake(
        items.map((each) => each.showAt),
        300,
      ),
    ).toBeUndefined();
  });

  test("a link coming back that the daemon sent with no showAt still waits the quiet bound", () => {
    const back = item({ since: 1_000 });
    expect(statusDueAt(back)).toBe(1_000 + CONNECTION_QUIET_MS);
    expect(shown([back], 1_000 + CONNECTION_QUIET_MS - 1)).toEqual([]);
    expect(shown([back], 1_000 + CONNECTION_QUIET_MS)).toEqual([back]);
    expect(statusDueAt(item({ level: "attention", since: 1_000 }))).toBeUndefined();
  });

  test("dedupe keeps one per kind, worst level first, then the oldest", () => {
    const items = [
      item({ level: "info", since: 1 }),
      item({ level: "attention", since: 5 }),
      item({ level: "attention", since: 3 }),
      item({ kind: "stuck", level: "problem", words: "status.stuck.auth", since: 9 }),
      item({ kind: "queuePaused", level: "attention", words: "status.queuePaused.paused", since: 2 }),
    ];
    const kept = dedupe(items);
    expect(kept.map((each) => [each.kind, each.level, each.since])).toEqual([
      ["stuck", "problem", 9],
      ["queuePaused", "attention", 2],
      ["machineLink", "attention", 3],
    ]);
    expect(worstLevel(kept)).toBe("problem");
    expect(worstLevel([])).toBeUndefined();
  });

  test("a words key this build does not know is dropped: it neither draws nor tints", () => {
    expect(statusWordsKey(item({ words: "status.machineLink.someday" }))).toBeUndefined();
    expect(statusWordsKey(item({ words: "toString" }))).toBeUndefined();
    expect(statusWordsKey(item({ words: "status.queuePaused.paused" }))).toBe("status.queuePaused.paused");
    expect(dedupe([item({ level: "problem", words: "status.machineLink.someday" })])).toEqual([]);
  });

  test("the wire's null reads as absent; an unknown kind is not an item", () => {
    expect(
      readStatusItem({ kind: "stuck", level: "problem", words: "status.stuck.auth", since: null, action: null }),
    ).toEqual({
      kind: "stuck",
      level: "problem",
      words: "status.stuck.auth",
    });
    expect(readStatusItem({ kind: "weather", level: "info", words: "x" })).toBeUndefined();
    expect(readComposerStatus(null)).toBeUndefined();
    expect(
      readComposerStatus({ items: [{ kind: "nope" }], facts: [{ kind: "context", fraction: 0.5, live: false }] }),
    ).toEqual({
      items: [],
      facts: [{ kind: "context", fraction: 0.5, live: false }],
    });
    // atRest is read only as true; anything else is absent.
    expect(
      readComposerStatus({
        items: [],
        facts: [
          { kind: "machine", text: "m", live: false, atRest: true },
          { kind: "folder", text: "/x", live: false, atRest: "yes" },
        ],
      })?.facts,
    ).toEqual([
      { kind: "machine", text: "m", live: false, atRest: true },
      { kind: "folder", text: "/x", live: false },
    ]);
  });

  test("a link coming back on its own is never read, even from an older acpmux", () => {
    for (const words of [
      "status.machineLink.connecting",
      "status.machineLink.reconnecting",
      "status.machineLink.degraded",
      "status.machineLink.restarting",
      "status.agentService.reconnecting",
    ])
      expect(readStatusItem({ kind: "machineLink", level: "info", words, since: 1 })).toBeUndefined();
    expect(readStatusItem({ kind: "machineLink", level: "attention", words: "status.machineLink.offline" })?.words).toBe(
      "status.machineLink.offline",
    );
  });

  test("a peer link's status rides along with its link, absent from an older daemon", () => {
    const status = { kind: "machineLink", level: "attention", words: "status.machineLink.offline", subject: "m" };
    expect(readPeerLinkDetail({ link: "offline", status })?.status).toEqual(status as StatusItem);
    expect(readPeerLinkDetail({ link: "connected", status: null })).toEqual({ link: "connected" });
  });

  test("the pane's own reconnect says nothing; only a restore acpmux reports does", () => {
    expect(hostRecoveryItem({ linkDown: false }, 1_000).item).toBeUndefined();
    expect(hostRecoveryItem({ linkDown: true }, 1_000)).toEqual({});
    expect(hostRecoveryItem({ linkDown: true }, 10_000_000)).toEqual({});
    expect(hostRecoveryItem({ linkDown: true, failureShown: true }, 1_000).item).toBeUndefined();
    const restoring = hostRecoveryItem({ linkDown: true, restoring: { waitedMs: 4_000, at: 10_000 } }, 10_000).item;
    expect(restoring?.words).toBe("status.restoringSessions.restoring");
    expect(restoring?.since).toBe(6_000);
    expect(hostRecoveryItem(undefined, 0)).toEqual({});
  });
});
