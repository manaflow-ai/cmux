// The pane's Auto requests (direct.ts `setAutoSession`, `autoLeftover`): the methods and params
// plans/cmux-next/auto-mode/DESIGN.md names, the shown chat's `autoSession` taken from the answer,
// and an acpmux that predates Auto told apart from a host refusal (autoSession.ts `autoUnsupported`).
import { expect, test } from "bun:test";
import { autoUnsupported } from "../src/agent-session/acpmux/autoSession/autoSession";
import type { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { AcpmuxRpcError } from "../src/agent-session/acpmux/handoff/protocol";
import { directClientStub } from "./support/directClientStub";

type Sent = { method: string; params: unknown; deadline?: number };

function clientAnswering(
  answer: (method: string, params: any) => unknown,
  autoSession?: unknown,
): { client: AcpmuxDirectClient; sent: Sent[]; emitted: string[]; auto: () => unknown } {
  const sent: Sent[] = [];
  const emitted: string[] = [];
  const client = directClientStub({
    selectedSessionId: "s1",
    summary: { sessionId: "s1", ...(autoSession ? { autoSession } : {}) },
    request: async (method: string, params: unknown, deadline?: number) => {
      sent.push({ method, params, deadline });
      return answer(method, params);
    },
    emit: (why: string) => emitted.push(why),
  });
  const auto = () => (client as unknown as { summary?: { autoSession?: unknown } }).summary?.autoSession;
  return { client, sent, emitted, auto };
}

test("turning Auto on sends the chat and the choice, and the answer is the chat's state", async () => {
  const state = { auto: true, state: "local", here: true, keepInCloud: false };
  const { client, sent, emitted, auto } = clientAnswering(() => ({ autoSession: state }));
  await client.setAutoSession("s1", true);
  expect(sent.map(({ method, params }) => ({ method, params }))).toEqual([
    { method: "_acpmux/auto_session/set", params: { sessionId: "s1", auto: true } },
  ]);
  expect(auto()).toEqual(state);
  expect(emitted).toEqual(["session changed"]);
});

test("Keep in Cloud rides the same request", async () => {
  const { client, sent, auto } = clientAnswering((_method, params) => ({
    autoSession: { auto: true, state: "cloud", here: false, keepInCloud: params.keepInCloud },
  }));
  await client.setAutoSession("s1", true, true);
  expect(sent[0]!.params).toEqual({ sessionId: "s1", auto: true, keepInCloud: true });
  expect(auto()).toEqual({ auto: true, state: "cloud", here: false, keepInCloud: true });
});

test("an answer without the state leaves the chat as it was", async () => {
  const before = { auto: false, state: "local", here: true, keepInCloud: false };
  const { client, emitted, auto } = clientAnswering(() => ({}), before);
  await client.setAutoSession("s1", true);
  expect(auto()).toEqual(before);
  expect(emitted).toEqual([]);
});

test("a chat that is not the one shown is never changed", async () => {
  const { client, sent } = clientAnswering(() => ({}));
  await expect(client.setAutoSession("s2", true)).rejects.toThrow();
  await expect(client.autoLeftover("s2", "discard")).rejects.toThrow();
  expect(sent).toEqual([]);
});

test("an acpmux that predates Auto is told apart from the host refusing the request", async () => {
  const old = clientAnswering(() => {
    throw new AcpmuxRpcError({ code: -32601, message: "Method not found" });
  });
  const oldFailure = await old.client.setAutoSession("s1", true).catch((error: unknown) => error);
  expect(autoUnsupported(oldFailure)).toBe(true);
  const refused = clientAnswering(() => {
    throw new AcpmuxRpcError({
      code: -32601,
      message: "Refused by the cmux host",
      data: { origin: "native", method: "_acpmux/auto_session/set" },
    });
  });
  const hostFailure = await refused.client.setAutoSession("s1", true).catch((error: unknown) => error);
  expect(hostFailure).toBeInstanceOf(AcpmuxRpcError);
  expect(autoUnsupported(hostFailure)).toBe(false);
  // Auto cannot be turned off while the Cloud runs the chat (409 auto.held_in_cloud): a failure to say.
  const held = clientAnswering(() => {
    throw new AcpmuxRpcError({ code: 409, message: "held", data: { code: "auto.held_in_cloud" } });
  });
  expect(autoUnsupported(await held.client.setAutoSession("s1", false).catch((error: unknown) => error))).toBe(false);
});

test("Show answers the kept files and changes nothing", async () => {
  const before = { auto: true, state: "local", here: true, keepInCloud: false, leftover: { files: 2 } };
  const { client, sent, emitted, auto } = clientAnswering(() => ({ files: ["a.ts", { path: "b.ts" }] }), before);
  expect(await client.autoLeftover("s1", "show")).toEqual({ files: ["a.ts", "b.ts"] });
  expect(sent[0]).toMatchObject({
    method: "_acpmux/auto_session/leftover",
    params: { sessionId: "s1", action: "show" },
  });
  expect(auto()).toEqual(before);
  expect(emitted).toEqual([]);
});

test("Apply and Discard end the notice, from the answer or at once when it names no state", async () => {
  const before = { auto: true, state: "local", here: true, keepInCloud: false, leftover: { files: ["a.ts"] } };
  const settled = { auto: true, state: "local", here: true, keepInCloud: false };
  const applied = clientAnswering(() => ({}), before);
  expect(await applied.client.autoLeftover("s1", "apply")).toBeUndefined();
  expect(applied.sent[0]!.params).toEqual({ sessionId: "s1", action: "apply" });
  expect(applied.auto()).toEqual(settled);
  expect(applied.emitted).toEqual(["session changed"]);

  const discarded = clientAnswering(() => ({ autoSession: { ...settled, auto: false } }), before);
  await discarded.client.autoLeftover("s1", "discard");
  expect(discarded.sent[0]!.params).toEqual({ sessionId: "s1", action: "discard" });
  expect(discarded.auto()).toEqual({ ...settled, auto: false });
});
