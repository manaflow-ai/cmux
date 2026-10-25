// Session Info (the Inspector, inspector/inspectorState.ts) is each chat pane's own (Leo,
// 2026-10-25: "basically the video shows the session rail opening and closing it opens and closes on
// the other side too when you do one... they should all be individual per pane"). Every chat pane is
// its own page on one origin, so they share localStorage: two stores over one storage stand for two
// panes, a new store over the same storage for a pane after a relaunch.
import { afterEach, beforeEach, expect, setSystemTime, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  createInspectorStore,
  INSPECTOR_PANES_KEY,
  INSPECTOR_WIDTH,
  PANES_KEPT,
} from "../src/agent-session/acpmux/inspector/inspectorState";

let dom: JSDOM;
const storage = () => dom.window.localStorage;
const pane = (sessionId: string) => {
  const store = createInspectorStore(storage);
  store.bind(sessionId);
  return store;
};

beforeEach(() => {
  dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
});
afterEach(() => {
  setSystemTime();
  dom.window.close();
});

test("a toggle, a drag or a fold in one pane leaves the other pane as it was", () => {
  const left = pane("chat-left");
  const right = pane("chat-right");
  let drawn = 0;
  right.subscribe(() => drawn++);
  expect(left.current().open).toBe(true);
  expect(right.current().open).toBe(true);

  left.setOpen(false);
  left.setWidth(480);
  left.setSection("context", true);
  // What the other page sees of the write: a storage event on its window.
  dom.window.dispatchEvent(new dom.window.StorageEvent("storage", { key: "cmux.agentPane.inspector.open" }));
  dom.window.dispatchEvent(new dom.window.StorageEvent("storage", { key: INSPECTOR_PANES_KEY }));

  expect(left.current()).toMatchObject({ open: false, width: 480, sections: { context: true } });
  expect(right.current()).toMatchObject({ open: true, width: INSPECTOR_WIDTH.fallback, sections: { context: false } });
  expect(drawn).toBe(0);
});

test("after a relaunch each pane shows its own state again", () => {
  pane("chat-left").setOpen(false);
  const right = pane("chat-right");
  right.setOpen(true);
  right.setWidth(400);

  const left = pane("chat-left");
  const rightAgain = pane("chat-right");
  expect(left.current().open).toBe(false);
  expect(rightAgain.current()).toMatchObject({ open: true, width: 400 });
});

test("a pane with no state of its own starts from the last choice, and the old shared key migrates", () => {
  // The single key every pane shared before: an old install's closed Inspector stays closed.
  storage().setItem("cmux.agentPane.inspector.open", "0");
  storage().setItem("cmux.agentPane.inspector.width", "420");
  expect(pane("chat-old").current()).toMatchObject({ open: false, width: 420 });

  pane("chat-a").setOpen(true);
  expect(pane("chat-new").current().open).toBe(true);
  // A pane's state from before it had a session (a new chat) is saved as its chat's.
  const fresh = createInspectorStore(storage);
  fresh.setOpen(false);
  fresh.bind("chat-born");
  expect(pane("chat-born").current().open).toBe(false);
});

test("the same chat in two panes: a toggle in one does not move the other", () => {
  const one = pane("chat-same");
  const two = pane("chat-same");
  one.setOpen(false);
  dom.window.dispatchEvent(new dom.window.StorageEvent("storage", { key: INSPECTOR_PANES_KEY }));
  expect(two.current().open).toBe(true);
});

test("storage keeps the newest panes of the last 30 days", () => {
  setSystemTime(new Date("2026-09-01T00:00:00Z"));
  pane("chat-stale").setOpen(false);
  setSystemTime(new Date("2026-10-25T00:00:00Z"));
  for (let index = 0; index < PANES_KEPT + 20; index++) {
    setSystemTime(new Date(Date.UTC(2026, 9, 25, 0, 0, index)));
    pane(`chat-${index}`).setOpen(index % 2 === 0);
  }
  const kept = JSON.parse(storage().getItem(INSPECTOR_PANES_KEY)!) as Record<string, unknown>;
  expect(Object.keys(kept).length).toBe(PANES_KEPT);
  expect(kept["chat-stale"]).toBeUndefined();
  expect(kept["chat-0"]).toBeUndefined();
  expect(kept[`chat-${PANES_KEPT + 19}`]).toBeDefined();
});
