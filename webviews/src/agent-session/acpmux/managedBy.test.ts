// Who manages a chat (managedBy.ts): the Chief for a chat whose `mux.parent` names a Chief, the
// starting chat for a sub-session or a chat another agent made, nobody for the person's own chat;
// and Take over is remembered per chat.
import { expect, test } from "bun:test";
import { isTakenOver, managedBy, takeOverManaged } from "./managedBy";
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
  expect(managedBy("lane", sessions)).toEqual({ kind: "agent", name: "claude-sr2-coord", sessionId: "coord" });
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
