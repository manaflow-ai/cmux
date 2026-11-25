// The hover card of a reference to another chat says what is useful about it: its state, what it
// is doing now, where it runs, its pull request and when it last changed. Leo, 2026-11-05, on
// Claude desktop's card (a status pill, the project and "now"): "the metadata.... ehh..".
import { expect, test } from "bun:test";
import { sessionEntry } from "../sessionList";
import { SessionHoverStore, hoverInfo } from "./sessionHover";

const AT = Date.UTC(2026, 10, 5, 8, 0);

test("a running chat's card says what its turn does now, its place and its last change", () => {
  const info = hoverInfo(
    sessionEntry({
      sessionId: "s-run",
      title: "Fix the flaky sidebar test",
      cwd: "/Users/you/Projects/cmux",
      branch: "flaky-sidebar",
      status: "running",
      updatedAt: AT,
      lane: { state: "working" },
      turn: { planStep: "Run the sidebar tests", activity: "bun test sidebar" },
    }),
  );
  expect(info.doing).toBe("Run the sidebar tests · bun test sidebar");
  expect(info.waiting).toBeUndefined();
  expect(info.preview).toBeUndefined();
  expect(info.meta?.[0]).toBe("cmux");
  expect(info.changedAt).toBe(AT);
});

test("a chat waiting on the person says what for; a finished one its latest reply", () => {
  const waiting = hoverInfo(
    sessionEntry({ sessionId: "s-wait", title: "Rename keys", waitingOn: "permission", preview: "ignored" }),
  );
  expect(waiting.waiting).toEqual({ on: "permission" });
  expect(waiting.preview).toBeUndefined();
  const done = hoverInfo(sessionEntry({ sessionId: "s-done", title: "Notes", preview: "\n  Shipped #22164.  \n" }));
  expect(done.doing).toBeUndefined();
  expect(done.preview).toBe("Shipped #22164.");
});

test("a chat's card changes only when what it says changes", () => {
  const store = new SessionHoverStore();
  const entry = sessionEntry({ sessionId: "s-1", title: "One", updatedAt: AT });
  store.set([entry]);
  const first = store.get("s-1");
  store.set([sessionEntry({ sessionId: "s-1", title: "One", updatedAt: AT })]);
  expect(store.get("s-1")).toBe(first);
  store.set([
    sessionEntry({
      sessionId: "s-1",
      title: "One",
      updatedAt: AT,
      lane: { state: "working" },
      turn: { activity: "Read App.tsx" },
    }),
  ]);
  expect(store.get("s-1")).not.toBe(first);
  expect(store.get("s-1")?.doing).toBe("Read App.tsx");
});

test("a hidden page's store lets its cards go, makes them again on a read or a show, and tells readers of a list it missed", () => {
  const store = new SessionHoverStore();
  let told = 0;
  store.subscribe(() => (told += 1));
  const first = [sessionEntry({ sessionId: "s-a", title: "A" }), sessionEntry({ sessionId: "s-b", title: "B" })];
  store.set(first);
  expect(told).toBe(1);
  store.release();
  // Released, a read makes the cards again and tells no one (it reads now).
  expect(store.get("s-a")?.title).toBe("A");
  expect(told).toBe(1);
  store.release();
  // A list set while released waits; shown again, the cards are its, and readers hear once.
  store.set([sessionEntry({ sessionId: "s-a", title: "A renamed" })]);
  expect(told).toBe(1);
  store.restore();
  expect(told).toBe(2);
  expect(store.get("s-a")?.title).toBe("A renamed");
  expect(store.get("s-b")).toBeUndefined();
  // Shown with nothing missed: no one is told.
  store.release();
  store.restore();
  expect(told).toBe(2);
  expect(store.get("s-a")?.title).toBe("A renamed");
});

test("chats listed after the others add their own cards, and an agent link still opens the first chat it names", () => {
  const entry = (id: string, agent: string, fields: Record<string, unknown> = {}) =>
    sessionEntry({ sessionId: id, title: id, harness: "claude", agentSessionId: agent, status: "idle", ...fields });
  const list = Array.from({ length: 50 }, (_, at) => entry(`s${at}`, `a${at % 40}`));
  const store = new SessionHoverStore();
  let told = 0;
  store.subscribe(() => told++);
  store.set(list);
  const card = store.get("s1");
  const longer = [...list, entry("new", "a3"), entry("other", "fresh", { peer: "gpu", host: "gpu" })];
  store.set(longer);
  const fresh = new SessionHoverStore();
  fresh.set(longer);
  expect(told).toBe(2);
  expect(store.get("s1")).toBe(card);
  for (const id of ["new", "other", "s3", "s49"]) {
    expect(store.get(id)).toEqual(fresh.get(id));
    expect(store.host(id)).toBe(fresh.host(id));
  }
  expect(store.byAgent("claude", "a3")).toBe("s3");
  expect(store.byAgentSession("fresh")).toBe("other");
  // A chat already listed, listed again after the others, reads the list whole.
  const twice = [...longer, entry("s2", "a2", { title: "again" })];
  store.set(twice);
  fresh.set(twice);
  expect(store.get("s2")).toEqual(fresh.get("s2"));
});
