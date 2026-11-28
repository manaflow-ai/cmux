// A prompt sent while the chat's page still connects to acpmux (it loads, or acpmux restarts) leaves
// the composer at once, shows as a sent row, and goes, in its turn, once the page connects (Leo,
// 2026-11-17: "I CAN'T EVEN SEND A MESSAGE WHILE THE THING LOADS ... JUST MAKE IT LOOK LIKE IT'S SENT
// OR JUST SEND IT"). Before, the pane refused the send and the composer kept it until the person
// pressed Send again. Ported from #53413 (sendBeforeFiles "a send made while the chat still connects").
import { expect, test } from "bun:test";
import { emptySnapshot } from "../src/agent-session/acpmux/snapshotCache";
import { StartingSends, withStartingPrompt, type StartingSend } from "../src/agent-session/acpmux/startingSends";
import { acpmuxSendsReady, untilAcpmuxTakesSends } from "../src/agent-session/acpmux/sendWhenReady";

function rows(sends: StartingSends, snapshotRows: { id: string; kind: string }[] = []) {
  const snapshot = { ...emptySnapshot(), rows: snapshotRows } as ReturnType<typeof emptySnapshot>;
  return withStartingPrompt(snapshot, sends.rows as StartingSend[]).rows.map((row) => `${row.kind}:${row.text}`);
}

const settle = async () => {
  for (let i = 0; i < 20; i++) await Promise.resolve();
};

test("a send made while the chat still connects to acpmux is shown at once and goes once it connects", async () => {
  const page: { cmuxAcpmuxActions?: Record<string, unknown> } = {};
  const sends = new StartingSends(
    () => undefined,
    () => undefined,
    () => ({ chat: "chat", visit: 1 }),
  );
  const sent: string[] = [];
  const go = async (text: string) => {
    await untilAcpmuxTakesSends(page);
    sent.push(text);
  };
  const pressed = performance.now();
  sends.add("sent while loading", [], go, undefined, "loading-1", { asSent: true });
  sends.add("and another", [], go, undefined, "loading-2", { asSent: true });
  expect(performance.now() - pressed).toBeLessThan(50);
  // Both are the transcript's rows now, in the order they were sent, even in a chat with history.
  expect(rows(sends)).toEqual(["user:sent while loading", "user:and another"]);
  expect(rows(sends, [{ id: "old", kind: "user" }])).toEqual([
    "user:undefined",
    "user:sent while loading",
    "user:and another",
  ]);
  // Once the client draws a prompt's own row (the same id), the pane's stand-in for it goes.
  expect(rows(sends, [{ id: "local-loading-1", kind: "user" }])).toEqual(["user:undefined", "user:and another"]);
  await settle();
  expect(sent).toEqual([]);
  page.cmuxAcpmuxActions = { "chat.send": () => Promise.resolve() };
  acpmuxSendsReady();
  await settle();
  expect(sent).toEqual(["sent while loading", "and another"]);
  expect(sends.busy).toBe(false);
});

test("a send made once the page is connected goes at once", async () => {
  const page = { cmuxAcpmuxActions: { "chat.send": () => Promise.resolve() } };
  let went = false;
  await untilAcpmuxTakesSends(page).then(() => (went = true));
  expect(went).toBe(true);
});

test("a new chat's first prompt still draws only while the chat has no prompt of its own", () => {
  const sends = new StartingSends(
    () => undefined,
    () => undefined,
    () => ({ chat: undefined, visit: 1 }),
  );
  sends.add("first", [], () => new Promise(() => undefined), undefined, "first-1");
  expect(rows(sends)).toEqual(["user:first"]);
  expect(rows(sends, [{ id: "old", kind: "user" }])).toEqual(["user:undefined"]);
});
