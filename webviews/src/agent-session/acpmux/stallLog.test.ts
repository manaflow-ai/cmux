// A chat whose live events stopped reaching the pane while it stayed connected (user, 2026-10-30,
// session claude-7: prompts on "Still sending" while acpmux had run them, replies missing). A release
// build shows no pane state, so when a send goes slow the pane asks acpmux for the first event after
// the one it holds: one that acpmux wrote a while ago and the pane never got is a stall, and the pane
// says so in the log (console.error reaches the error journal and the unified log in every build).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const had = { window: "window" in scope, document: "document" in scope };
const before = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (had[key]) scope[key] = before[key];
    else delete scope[key];
});

const settle = async (done: () => boolean, ms = 2_000) => {
  const deadline = performance.now() + ms;
  while (!done()) {
    if (performance.now() > deadline) return false;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  return true;
};

type Hooks = { answer: (method: string, params: any) => Promise<unknown> };

async function slowSend(acpmuxAhead: { ageMs: number } | undefined) {
  const { AcpmuxDirectClient, deliveryTiming } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const timing = { ...deliveryTiming };
  Object.assign(deliveryTiming, { slowMs: 20 });
  const errors: string[] = [];
  const error = console.error;
  console.error = (...args: unknown[]) => void errors.push(args.map(String).join(" "));
  let sessionId = "";
  class Stalled extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        if (method === "session/prompt") {
          sessionId = params.sessionId;
          return new Promise(() => undefined);
        }
        const result = (await answer(method, params)) as any;
        // acpmux holds events the pane never got (its stream stopped): the next one after the pane's.
        if (method === "_acpmux/events" && acpmuxAhead && params.limit === 1)
          return {
            events: [
              {
                seq: Number(params.afterSeq) + 7,
                sessionId: params.sessionId,
                at: Date.now() - acpmuxAhead.ageMs,
                dir: "in",
                kind: "agent_message_chunk",
                msg: {},
              },
            ],
            hasMore: true,
          };
        return result;
      };
    }
  }
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new Stalled() as unknown as WebSocket,
  );
  try {
    void client.send("anyone there").catch(() => undefined);
    await settle(() => errors.some((line) => line.includes("agent pane stall")), 500);
    return { errors, sessionId };
  } finally {
    console.error = error;
    Object.assign(deliveryTiming, timing);
    client.close?.();
  }
}

test("a slow send in a chat whose events stopped reaching the pane logs the stall with the session id", async () => {
  const { errors, sessionId } = await slowSend({ ageMs: 60_000 });
  const line = errors.find((entry) => entry.includes("agent pane stall"));
  expect(line).toBeDefined();
  expect(line).toContain(sessionId);
  expect(line).toMatch(/pane at seq \d+, acpmux at seq \d+/);
});

test("a slow send with nothing missing, or with an event only just written, logs no stall", async () => {
  expect((await slowSend(undefined)).errors.filter((entry) => entry.includes("agent pane stall"))).toEqual([]);
  expect((await slowSend({ ageMs: 100 })).errors.filter((entry) => entry.includes("agent pane stall"))).toEqual([]);
});
