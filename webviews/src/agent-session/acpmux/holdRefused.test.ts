// After Leo's NIGHTLY restarted (2026-11-16 21:09Z), every chat drawn from the row store asked
// `_acpmux/attach {hold: true}` and the cmux host refused it as `transport.intent_invalid`: its
// params rule (AcpmuxPaneMethods+Params.swift, cmux-agent-pane-policy policy.json) did not know
// `hold`, so the chat said "Something went wrong, so that didn't go through." with Retry above the
// composer. Leo: "it said something went wrong with a retry button just above the composer (weird,
// unnecessary, idk what the root cause was)".
//
// Two holds here. The class: every attach the page builds passes the host's params rule, so a new
// attach param cannot ship on the page without the host taking it (as `settled` did, cmux#42185).
// The fallback: a host that still refuses the hold (a page newer than its app) gets the plain attach,
// and the chat opens on v1 with no error.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";
import { plainAttach } from "./attachParams";
import { HOLD_KINDS, holdAttach, holdAttachRefused } from "./rows/holdKinds";
import { resetChatRowsReceiver } from "./rows/receiver";

type Policy = { known_params: Record<string, { params: string[] }> };
const policy = JSON.parse(
  readFileSync(path.resolve(import.meta.dir, "../../../../cmux-tui/crates/cmux-agent-pane-policy/policy.json"), "utf8"),
) as Policy;

test("every attach the page builds passes the host's params rule", () => {
  const known = new Set(policy.known_params["_acpmux/attach"]!.params);
  const shapes = [
    holdAttach("s", true, HOLD_KINDS)!,
    ...[true, false].flatMap((settled) =>
      [true, false].map((local) => plainAttach("s", { settled, visible: true, local, maxBytes: 131_072 })),
    ),
  ];
  for (const params of shapes) expect(Object.keys(params).filter((key) => !known.has(key))).toEqual([]);
});

test("a refused hold is told apart from any other failure", () => {
  expect(holdAttachRefused({ code: "transport.intent_invalid" })).toBe(true);
  expect(holdAttachRefused({ code: "transport.session_not_in_pane" })).toBe(false);
  expect(holdAttachRefused(new Error("socket closed"))).toBe(false);
  expect(holdAttachRefused(null)).toBe(false);
});

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const had = { window: "window" in scope, document: "document" in scope };
const before = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
  scope.cmuxAcpmuxMockCapabilities = ["attach-hold-v1"];
});
afterAll(async () => {
  delete scope.cmuxAcpmuxMockCapabilities;
  (await import("./native")).setNativeHost(undefined);
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (had[key]) scope[key] = before[key];
    else delete scope[key];
});

const settle = async (done: () => boolean) => {
  // timeout: a mock daemon and host answer in microtasks; past 2 s a wait names what it waited on, not a hang.
  const deadline = performance.now() + 2_000;
  while (!done()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${done.toString()}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
};

type Hooks = { answer: (method: string, params: any) => Promise<unknown> };

test("a host that refuses the hold: the chat leaves the store and opens on the plain attach", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { mockSessions } = await import("./mockFixture");
  const { setNativeHost } = await import("./native");
  const { resetChatRowsState } = await import("./rows/chatSource");
  resetChatRowsState();
  const a = mockSessions[0]!.sessionId;
  const asked: { to: string; method: string; params: any }[] = [];
  setNativeHost(async (method, params) => {
    asked.push({ to: "host", method, params });
    return method === "chat.rows.open" ? { sid: params.sid } : null;
  });
  // The host's refusal of a frame its params rule does not take (AcpmuxPaneMethods.refusal).
  class OldHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        asked.push({ to: "daemon", method, params });
        if (method === "_acpmux/attach" && "hold" in params)
          throw Object.assign(new Error("Refused by the cmux host"), { code: "transport.intent_invalid" });
        return answer(method, params);
      };
    }
  }
  let rows = 0;
  const client = await AcpmuxDirectClient.connect(
    { ...mockHost, sessionId: a },
    (snapshot) => {
      rows = snapshot.rows.length;
    },
    undefined,
    () => new OldHost() as unknown as WebSocket,
  );
  try {
    const attaches = () => asked.filter((ask) => ask.method === "_acpmux/attach" && ask.params.sessionId === a);
    await settle(() => attaches().length >= 2 && rows > 0);
    const [hold, plain] = attaches();
    expect(hold!.params.hold).toBe(true);
    // The plain attach follows at once: a page, not the hold.
    expect("hold" in plain!.params).toBe(false);
    expect(plain!.params.kinds).toContain("transcript");
    // The chat left the store: its open is closed, and it is v1 until another chat is chosen.
    const sid = asked.find((ask) => ask.method === "chat.rows.open" && ask.params.chat === a)?.params.sid;
    expect(asked.some((ask) => ask.method === "chat.rows.close" && ask.params.sid === sid)).toBe(true);
    expect((client as any).chatRows.holds(a)).toBe(false);
  } finally {
    client.close?.();
    resetChatRowsReceiver();
  }
});
