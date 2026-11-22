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
