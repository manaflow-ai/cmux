// The flicker detector's batches reach the app on both hosts (flickerLog.ts). On the shared page host
// it started nowhere, so Leo's NIGHTLY ring file (2026-11-11, "the tool calls coming in are still
// kinda sluggish") held 369 lines and no page event: no `frames`, no `long-frame`.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { pageHostFlickerSend, resetFlickerLogForTests, startFlickerLog, type FlickerEvent } from "./flickerLog";
import { resetPageHostClientForTests } from "./pageHost";

const scope = globalThis as Record<string, unknown>;
const previousWebkit = scope.webkit;

function page(): Window {
  return new JSDOM("<!doctype html><body></body>", { url: "http://localhost/", pretendToBeVisual: true })
    .window as unknown as Window;
}

function event(win: Window, name: string): Event {
  return new (win as Window & typeof globalThis).Event(name);
}

/// Ends the page's flush window at once, as leaving the page does.
function leave(win: Window): void {
  win.dispatchEvent(event(win, "pagehide"));
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

afterEach(() => {
  resetFlickerLogForTests();
  resetPageHostClientForTests();
  if (previousWebkit === undefined) delete scope.webkit;
  else scope.webkit = previousWebkit;
});

test("on the shared page host each batch is the cmux.agent.diag.flicker op", async () => {
  const calls: { t: string; op?: string; params?: { events: FlickerEvent[] } }[] = [];
  scope.webkit = {
    messageHandlers: {
      cmuxPage: {
        async postMessage(message: { t: string; id: number; op?: string; params?: { events: FlickerEvent[] } }) {
          calls.push(message);
          return { t: "ok", id: message.id, value: null };
        },
      },
    },
  };
  const win = page();
  startFlickerLog(win, pageHostFlickerSend());
  leave(win);
  await settle();
  const sent = calls.filter((call) => call.t === "call");
  expect(sent.map((call) => call.op)).toEqual(["cmux.agent.diag.flicker"]);
  expect(sent[0]!.params!.events.map((event) => event.kind)).toEqual(["page-load"]);
  expect(typeof sent[0]!.params!.events[0]!.at).toBe("number");
});

test("a host that refuses or throws costs the page nothing", async () => {
  scope.webkit = {
    messageHandlers: {
      cmuxPage: {
        async postMessage(message: { id: number }) {
          return { t: "err", id: message.id, code: "cmux.protocol.unknown_op", message: "no such op" };
        },
      },
    },
  };
  const refused = page();
  startFlickerLog(refused, pageHostFlickerSend());
  expect(() => leave(refused)).not.toThrow();
  await settle();

  resetFlickerLogForTests();
  const throwing = page();
  startFlickerLog(throwing, () => {
    throw new Error("gone");
  });
  expect(() => leave(throwing)).not.toThrow();
});

test("the old host's WebKit handler still takes them, and the gallery's stand-in gets none", async () => {
  const posted: { method: string }[] = [];
  const old = page();
  (old as unknown as { webkit: unknown }).webkit = {
    messageHandlers: { agentSession: { postMessage: async (body: { method: string }) => posted.push(body) } },
  };
  startFlickerLog(old);
  leave(old);
  expect(posted.map((body) => body.method)).toEqual(["diag.flicker"]);

  resetFlickerLogForTests();
  const gallery = page();
  (gallery as unknown as { webkit: unknown }).webkit = {
    messageHandlers: {
      agentSession: { standIn: true, postMessage: async (body: { method: string }) => posted.push(body) },
    },
  };
  startFlickerLog(gallery);
  leave(gallery);
  expect(posted).toHaveLength(1);
});

test("events wait for their batch: nothing goes out before the second ends or the page leaves", async () => {
  const batches: FlickerEvent[][] = [];
  const win = page();
  startFlickerLog(win, (events) => batches.push(events));
  win.document.dispatchEvent(event(win, "visibilitychange"));
  expect(batches).toHaveLength(0);
  leave(win);
  expect(batches.map((batch) => batch.map((sent) => sent.kind))).toEqual([["page-load", "visibility"]]);
});
