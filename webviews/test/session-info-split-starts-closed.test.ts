// A chat opened in a split beside another chat (a subagent's pane, a chat its agent started) starts
// with Session Info closed and keeps its own state (Leo, 2026-11-03: "it's often fine to just not have
// it open by default on the right like it doesn't need to inherit that" and "if they want it open
// they can just do it on the right split one"). Each pane is its own store over one storage.
import { expect, test } from "bun:test";
import { createSessionInfoStore, sessionInfoPaneKey } from "../src/agent-session/acpmux/session-info/sessionInfoState";

function memoryStorage(): Storage {
  const map = new Map<string, string>();
  return {
    get length() {
      return map.size;
    },
    key: (index: number) => [...map.keys()][index] ?? null,
    getItem: (key: string) => map.get(key) ?? null,
    setItem: (key: string, value: string) => void map.set(key, String(value)),
    removeItem: (key: string) => void map.delete(key),
    clear: () => map.clear(),
  };
}

test("a split pane's key is its own; a plain pane's is the chat's", () => {
  expect(sessionInfoPaneKey("chat-1")).toBe("chat-1");
  expect(sessionInfoPaneKey("chat-1", true)).toBe("split:chat-1");
  expect(sessionInfoPaneKey(undefined, true)).toBeUndefined();
});

test("a chat opened in a split starts with Session Info closed; the parent keeps its own open", () => {
  const storage = memoryStorage();
  const parent = createSessionInfoStore(() => storage);
  parent.bind("chat-1");
  parent.setOpen(true);
  expect(parent.current().open).toBe(true);

  // The subagent's pane shows the parent's session, opened as a split.
  const child = createSessionInfoStore(() => storage);
  const key = sessionInfoPaneKey("chat-1", true);
  // Its first frame (before the bind) already reads closed, and the same object each read.
  expect(child.shownFor(key).open).toBe(false);
  expect(child.shownFor(key)).toBe(child.shownFor(key));
  child.bind(key);
  expect(child.current().open).toBe(false);

  // A chat its agent started, opened beside it, starts closed too.
  const started = createSessionInfoStore(() => storage);
  started.bind(sessionInfoPaneKey("chat-2", true));
  expect(started.current().open).toBe(false);

  // The parent still shows it open, and a relaunched parent pane too.
  expect(parent.current().open).toBe(true);
  const relaunched = createSessionInfoStore(() => storage);
  relaunched.bind("chat-1");
  expect(relaunched.current().open).toBe(true);
});

test("opening it in the split pane sticks for that pane and never reaches the parent", () => {
  const storage = memoryStorage();
  const parent = createSessionInfoStore(() => storage);
  parent.bind("chat-1");
  parent.setOpen(false);

  const child = createSessionInfoStore(() => storage);
  child.bind(sessionInfoPaneKey("chat-1", true));
  child.setOpen(true);

  const childAgain = createSessionInfoStore(() => storage);
  childAgain.bind(sessionInfoPaneKey("chat-1", true));
  expect(childAgain.current().open).toBe(true);

  const parentAgain = createSessionInfoStore(() => storage);
  parentAgain.bind("chat-1");
  expect(parentAgain.current().open).toBe(false);
});
