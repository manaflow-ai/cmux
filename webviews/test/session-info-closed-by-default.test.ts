// Session Info (the Inspector, inspector/inspectorState.ts) is closed until a person opens it
// (https://github.com/manaflow-ai/cmux/issues/29874): a first chat, with no choice made in any pane,
// does not show it. Once opened it stays the default for new chats, and once closed it stays off.
import { describe, expect, test } from "bun:test";
import { createInspectorStore } from "../src/agent-session/acpmux/inspector/inspectorState";

function memoryStorage(): Storage {
  const items = new Map<string, string>();
  return {
    get length() {
      return items.size;
    },
    clear: () => items.clear(),
    getItem: (key) => items.get(key) ?? null,
    key: (index) => [...items.keys()][index] ?? null,
    removeItem: (key) => void items.delete(key),
    setItem: (key, value) => void items.set(key, String(value)),
  };
}

describe("Session Info default", () => {
  test("a first chat with no choice made does not show it", () => {
    const storage = memoryStorage();
    const pane = createInspectorStore(() => storage);
    expect(pane.current().open).toBe(false);
    pane.bind("chat-1");
    expect(pane.current().open).toBe(false);
    expect(pane.shownFor("chat-2").open).toBe(false);
  });

  test("with no storage it starts closed too", () => {
    expect(createInspectorStore(() => undefined).current().open).toBe(false);
  });

  test("opened once, a new chat in another pane opens with it", () => {
    const storage = memoryStorage();
    const first = createInspectorStore(() => storage);
    first.bind("chat-1");
    first.setOpen(true);
    const second = createInspectorStore(() => storage);
    second.bind("chat-2");
    expect(second.current().open).toBe(true);
  });

  test("closed again, a new chat stays closed and the opened chat keeps its own state", () => {
    const storage = memoryStorage();
    const first = createInspectorStore(() => storage);
    first.bind("chat-1");
    first.setOpen(true);
    const second = createInspectorStore(() => storage);
    second.bind("chat-2");
    second.setOpen(false);
    const third = createInspectorStore(() => storage);
    third.bind("chat-3");
    expect(third.current().open).toBe(false);
    expect(third.shownFor("chat-1").open).toBe(true);
  });

  test("reset goes back to closed", () => {
    const storage = memoryStorage();
    const pane = createInspectorStore(() => storage);
    pane.setOpen(true);
    pane.reset();
    expect(pane.current().open).toBe(false);
  });
});
