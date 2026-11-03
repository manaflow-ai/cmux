// Who manages a chat (managedBy.ts): the Chief for a chat whose `mux.parent` names a Chief, the
// starting chat for a sub-session or a chat another agent made, nobody for the person's own chat;
// and Take over is remembered per chat.
import { expect, test } from "bun:test";
import { DRIVING_WINDOW_MS, isTakenOver, managedBy, managerDrivingUntil, takeOverManaged } from "./managedBy";
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
const fromCoord = { kind: "message", message: { name: "claude-sr2-coord", sessionId: "coord", text: "go", raw: "go" } } as const;
const person = (at: number) => ({ kind: "user", at });
const coordSays = (at: number) => ({ kind: "user", at, incoming: fromCoord });
const reply = (at: number) => ({ kind: "assistant", at });
const shown = (manager: Parameters<typeof managerDrivingUntil>[0], rows: Parameters<typeof managerDrivingUntil>[1], queued = []) => {
  const until = managerDrivingUntil(manager, rows, queued, now);
  return until !== undefined && until > now;
};

test("a chat its manager only dispatched shows no line, however recent the brief", () => {
  expect(shown(coord, [coordSays(ago(60)), reply(ago(59))])).toBe(false);
  expect(shown(coord, [coordSays(ago(1))])).toBe(false);
  expect(shown({ kind: "chief" }, [{ kind: "user", at: ago(1), from: "chief" }])).toBe(false);
});

test("a manager's follow-up in the last ten minutes shows the line; past the window it goes", () => {
  const rows = [coordSays(ago(60)), reply(ago(59)), coordSays(ago(2)), reply(ago(1))];
  expect(managerDrivingUntil(coord, rows, [], now)).toBe(ago(2) + DRIVING_WINDOW_MS);
  expect(shown(coord, rows)).toBe(true);
  expect(shown(coord, [coordSays(ago(60)), coordSays(ago(25)), reply(ago(24))])).toBe(false);
  expect(DRIVING_WINDOW_MS).toBe(10 * 60_000);
});

test("the person's own newest prompt, or another agent's, hides the line", () => {
  expect(shown(coord, [coordSays(ago(30)), coordSays(ago(3)), person(ago(2))])).toBe(false);
  const other = { kind: "user", at: ago(1), incoming: { kind: "message", message: { name: "reviewer", sessionId: "rev", text: "", raw: "" } } };
  expect(shown(coord, [coordSays(ago(30)), other])).toBe(false);
});

test("bookkeeping rows are not prompts; a Chief's follow-up drives its chat", () => {
  const hidden = { kind: "user", at: ago(1), incoming: { kind: "hidden" } };
  expect(shown(coord, [coordSays(ago(30)), coordSays(ago(3)), hidden])).toBe(true);
  expect(shown({ kind: "chief" }, [{ kind: "user", at: ago(30), from: "chief" }, { kind: "user", at: ago(4), from: "chief" }])).toBe(true);
});

test("a manager's message waiting in the queue drives the chat now", () => {
  expect(shown(coord, [coordSays(ago(60))], [fromCoord.message] as never)).toBe(true);
  expect(managerDrivingUntil(undefined, [coordSays(ago(30)), coordSays(ago(1))], [], now)).toBeUndefined();
});

test("a sender named only by its chat's name still counts as the manager", () => {
  const named = { kind: "user", at: ago(1), incoming: { kind: "message", message: { name: "claude-sr2-coord", text: "", raw: "" } } };
  expect(shown(coord, [coordSays(ago(30)), named])).toBe(true);
});
