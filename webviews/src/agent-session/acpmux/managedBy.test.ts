// Who manages a chat (managedBy.ts): the Chief for a chat whose `mux.parent` names a Chief, the
// starting chat for a sub-session or a chat another agent made, nobody for the person's own chat;
// and Take over is remembered per chat.
import { expect, test } from "bun:test";
import {
  chiefOf,
  DRIVING_WINDOW_MS,
  isTakenOver,
  managedBy,
  managerDrivingUntil,
  takeOverManaged,
  type PromptRow,
} from "./managedBy";
import type { IncomingMessage } from "./conversation/incomingMessage";
import { sessionEntry } from "./sessionList";

const entry = (sessionId: string, extra: Record<string, unknown> = {}) => sessionEntry({ sessionId, ...extra });

test("a Chief's subagent is managed by the Chief", () => {
  const sessions = [entry("kid", { tags: { "mux.parent": "optchat-chief:6b68ac4a", "optchat.subagent": "a31" } })];
  expect(sessions[0]!.chiefChild).toBe(true);
  expect(managedBy("kid", sessions)).toEqual({ kind: "chief" });
});

test("a bare optchat-chief parent counts; another app's mux.parent does not", () => {
  expect(entry("a", { tags: { "mux.parent": "optchat-chief" } }).chiefChild).toBe(true);
  expect(entry("b", { tags: { "mux.parent": "optchat-chiefly" } }).chiefChild).toBeUndefined();
  expect(entry("c", { tags: { "mux.parent": "lane-host" } }).chiefChild).toBeUndefined();
  expect(managedBy("c", [entry("c", { tags: { "mux.parent": "lane-host" } })])).toBeUndefined();
});

test("a sub-session is managed by the chat that started it, by that chat's title", () => {
  const sessions = [entry("coord", { title: "claude-sr2-coord" }), entry("lane", { startedBy: "coord" })];
  expect(managedBy("lane", sessions)).toMatchObject({ kind: "agent", name: "claude-sr2-coord", sessionId: "coord" });
});

test("a chat another agent made is managed by that agent's chat", () => {
  const sessions = [entry("p", { name: "planner" }), entry("c", { spawnedBy: "p" })];
  expect(managedBy("c", sessions)).toMatchObject({ kind: "agent", sessionId: "p" });
});

test("the person's own chat, a missing chat and an unlisted manager show nothing", () => {
  const sessions = [entry("mine"), entry("orphan", { startedBy: "gone" }), entry("self", { startedBy: "self" })];
  expect(managedBy("mine", sessions)).toBeUndefined();
  expect(managedBy("orphan", sessions)).toBeUndefined();
  expect(managedBy("self", sessions)).toBeUndefined();
  expect(managedBy("nope", sessions)).toBeUndefined();
  expect(managedBy(undefined, sessions)).toBeUndefined();
});

test("Take over is remembered for that chat only", () => {
  const data = new Map<string, string>();
  const storage = {
    getItem: (key: string) => data.get(key) ?? null,
    setItem: (key: string, value: string) => void data.set(key, value),
  } as unknown as Storage;
  expect(isTakenOver("kid", storage)).toBe(false);
  takeOverManaged("kid", storage);
  takeOverManaged("kid", storage);
  expect(isTakenOver("kid", storage)).toBe(true);
  expect(isTakenOver("other", storage)).toBe(false);
  expect(JSON.parse(data.get("cmux.acpmux.takenOver")!)).toEqual(["kid"]);
});

test("a corrupt store reads as nothing taken over", () => {
  const storage = { getItem: () => "{not json" } as unknown as Storage;
  expect(isTakenOver("kid", storage)).toBe(false);
});

// The line shows only while the manager drives the chat (Leo, 2026-11-03: "i feel like it's put out
// there too often"): its newest prompt is the manager's follow-up from the last ten minutes.
const now = Date.UTC(2026, 10, 3, 0, 5);
const ago = (minutes: number) => now - minutes * 60_000;
const coord = { kind: "agent", name: "claude-sr2-coord", sessionId: "coord", signs: ["claude-sr2-coord"] } as const;
const fromCoord = {
  kind: "message",
  message: { name: "claude-sr2-coord", sessionId: "coord", text: "go", raw: "go" },
} as const;
const person = (at: number): PromptRow => ({ kind: "user", at });
const coordSays = (at: number): PromptRow => ({ kind: "user", at, incoming: fromCoord });
const reply = (at: number): PromptRow => ({ kind: "assistant", at });
const shown = (
  manager: Parameters<typeof managerDrivingUntil>[0],
  rows: readonly PromptRow[],
  queued: readonly IncomingMessage[] = [],
) => {
  const until = managerDrivingUntil(manager, rows, queued);
  return until !== undefined && until > now;
};

test("a chat its manager only dispatched shows no line, however recent the brief", () => {
  expect(shown(coord, [coordSays(ago(60)), reply(ago(59))])).toBe(false);
  expect(shown(coord, [coordSays(ago(1))])).toBe(false);
  expect(shown({ kind: "chief" }, [{ kind: "user", at: ago(1), from: "chief" } satisfies PromptRow])).toBe(false);
});

test("a manager's follow-up in the last ten minutes shows the line; past the window it goes", () => {
  const rows = [coordSays(ago(60)), reply(ago(59)), coordSays(ago(2)), reply(ago(1))];
  expect(managerDrivingUntil(coord, rows)).toBe(ago(2) + DRIVING_WINDOW_MS);
  expect(shown(coord, rows)).toBe(true);
  expect(shown(coord, [coordSays(ago(60)), coordSays(ago(25)), reply(ago(24))])).toBe(false);
  expect(DRIVING_WINDOW_MS).toBe(10 * 60_000);
});

test("the person's own newest prompt, or another agent's, hides the line", () => {
  expect(shown(coord, [coordSays(ago(30)), coordSays(ago(3)), person(ago(2))])).toBe(false);
  const other: PromptRow = {
    kind: "user",
    at: ago(1),
    incoming: { kind: "message", message: { name: "reviewer", sessionId: "rev", text: "", raw: "" } },
  };
  expect(shown(coord, [coordSays(ago(30)), other])).toBe(false);
});

test("bookkeeping rows are not prompts; a Chief's follow-up drives its chat", () => {
  const hidden: PromptRow = { kind: "user", at: ago(1), incoming: { kind: "hidden" } };
  expect(shown(coord, [coordSays(ago(30)), coordSays(ago(3)), hidden])).toBe(true);
  const chief = (at: number): PromptRow => ({ kind: "user", at, from: "chief" });
  expect(shown({ kind: "chief" }, [chief(ago(30)), chief(ago(4))])).toBe(true);
});

test("a manager's message waiting in the queue drives the chat now", () => {
  expect(shown(coord, [coordSays(ago(60))], [fromCoord.message])).toBe(true);
  // It stays while the message waits, however long: no window runs out under it.
  expect(managerDrivingUntil(coord, [coordSays(ago(60))], [fromCoord.message])).toBe(Infinity);
  expect(managerDrivingUntil(undefined, [coordSays(ago(30)), coordSays(ago(1))])).toBeUndefined();
});

test("a Chief's message is never taken for an agent manager's, even marked parent", () => {
  const chiefSays: PromptRow = {
    kind: "user",
    at: ago(1),
    incoming: {
      kind: "message",
      message: { name: "Chief", chief: "agent_mux", relation: "parent", text: "", raw: "" },
    },
  };
  expect(shown(coord, [coordSays(ago(30)), chiefSays])).toBe(false);
});

test("a sender named only by its chat's name still counts as the manager", () => {
  const named: PromptRow = {
    kind: "user",
    at: ago(1),
    incoming: { kind: "message", message: { name: "claude-sr2-coord", text: "", raw: "" } },
  };
  expect(shown(coord, [coordSays(ago(30)), named])).toBe(true);
});

test("a Chief's chat names the Chief from its turn session's tags, else the default Chief", () => {
  const turn = { sessionId: "turn", chiefTurn: { home: "optchat-chief:home", participant: "agent_scout" } };
  const chat = { sessionId: "chat", chiefChild: true as const, chiefHome: "optchat-chief:home" };
  expect(chiefOf("chat", [turn, chat])).toBe("agent_scout");
  expect(chiefOf("chat", [chat])).toBe("agent_mux");
  expect(chiefOf("chat", [{ sessionId: "chat" }])).toBeUndefined();
  expect(
    sessionEntry({
      sessionId: "turn",
      tags: { "mux.children": "optchat-chief:home", "cmux.chief.participant": "agent_scout" },
    }).chiefTurn,
  ).toEqual({ home: "optchat-chief:home", participant: "agent_scout" });
  expect(sessionEntry({ sessionId: "chat", tags: { "mux.parent": "optchat-chief:home" } }).chiefHome).toBe(
    "optchat-chief:home",
  );
});
