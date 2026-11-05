import { expect, test } from "bun:test";
import {
  createSessionInfoStore,
  SESSION_INFO_PANE_PREFIX,
} from "../src/agent-session/acpmux/session-info/sessionInfoState";

function memoryStorage(): Storage {
  const values = new Map<string, string>();
  return {
    get length() {
      return values.size;
    },
    key: (index) => [...values.keys()][index] ?? null,
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => void values.set(key, value),
    removeItem: (key) => void values.delete(key),
    clear: () => values.clear(),
  };
}

test("fresh sections start collapsed, including when storage is unavailable", () => {
  for (const storage of [memoryStorage(), undefined]) {
    const store = createSessionInfoStore(() => storage);
    store.bind("fresh");
    expect(Object.values(store.current().sections).every((open) => !open)).toBe(true);
    store.setSection("context", true);
    expect(store.current().sections.context).toBe(true);
  }
});

test("saved section choices win over defaults across tabs, chats and reloads", () => {
  const storage = memoryStorage();
  const first = createSessionInfoStore(() => storage);
  first.setTab("left");
  first.bind("chat");
  first.setSection("sources", true);
  first.setSection("context", false);
  first.setSection("app:notes#summary", true);

  const second = createSessionInfoStore(() => storage);
  second.setTab("right");
  second.bind("chat");
  second.setSection("sources", false);
  second.setSection("app:notes#summary", false);

  const reload = createSessionInfoStore(() => storage);
  reload.setTab("left");
  expect(reload.shownFor("chat").sections).toMatchObject({ sources: true, context: false, "app:notes#summary": true });
  reload.bind("chat");
  expect(reload.current().sections).toMatchObject({ sources: true, context: false, "app:notes#summary": true });
  reload.bind("another-chat");
  expect(reload.current().sections.sources).toBe(true);

  const fresh = createSessionInfoStore(() => storage);
  fresh.bind("new-chat");
  expect(fresh.current().sections).toMatchObject({ sources: false, "app:notes#summary": false });
});

test("legacy Context folds stay as saved and missing sections start collapsed", () => {
  const storage = memoryStorage();
  storage.setItem(
    SESSION_INFO_PANE_PREFIX + "legacy",
    JSON.stringify({
      open: true,
      sections: { context: false, changes: true },
    }),
  );
  const store = createSessionInfoStore(() => storage);
  store.bind("legacy");
  expect(store.current().sections).toMatchObject({ context: false, changes: true, tasks: false });
  expect(store.current().open).toBe(true);
});
