import { expect, test } from "bun:test";
import {
  createInspectorOrderStore,
  DEFAULT_INSPECTOR_ORDER,
  INSPECTOR_ORDER_KEY,
  moveSection,
} from "../src/agent-session/acpmux/inspector/sectionOrder";

function memory(raw: string | null = null) {
  const entries = new Map<string, string>(raw === null ? [] : [[INSPECTOR_ORDER_KEY, raw]]);
  return {
    getItem: (key: string) => entries.get(key) ?? null,
    setItem: (key: string, value: string) => entries.set(key, value),
  };
}

test("Changes above Context survives a relaunch and is shared by a new pane", () => {
  const storage = memory();
  const first = createInspectorOrderStore(() => storage);
  first.set(moveSection(first.current(), "changes", "context"));
  expect(first.current().slice(0, 3)).toEqual(["environment", "changes", "context"]);
  expect(createInspectorOrderStore(() => storage).current()).toEqual(first.current());
  expect(storage.getItem("cmux.agentPane.inspector.sections")).toBeNull();
});

test("old or malformed storage keeps known order and appends missing sections", () => {
  for (const raw of ["oops", "{}", "null"]) {
    expect(createInspectorOrderStore(() => memory(raw)).current()).toEqual(DEFAULT_INSPECTOR_ORDER);
  }
  const storage = memory(JSON.stringify(["changes", "unknown", "changes", "context"]));
  expect(
    createInspectorOrderStore(() => storage)
      .current()
      .join(","),
  ).toBe("changes,context,environment,connectors,sources,outputs,subagents,tasks");
});

test.each([false, true])("storage failure (readable=%s) keeps memory, stable snapshots and unsubscribe", (readable) => {
  const unavailable = () => {
    throw new Error("storage unavailable");
  };
  const store = createInspectorOrderStore(() => ({
    getItem: readable ? () => null : unavailable,
    setItem: unavailable,
  }));
  const original = store.current();
  let notices = 0;
  const unsubscribe = store.subscribe(() => notices++);
  store.set(moveSection(original, "changes", "context"));
  const changed = store.current();
  expect(changed).toBe(store.current());
  expect(changed).not.toEqual(original);
  store.set(changed);
  expect(notices).toBe(1);
  unsubscribe();
  const again = store.subscribe(() => {});
  expect(store.current()).toBe(changed);
  again();
  store.set(original);
  expect(notices).toBe(1);
});

test("moves before and after without mutating the input; dropping on itself is stable", () => {
  const original = Object.freeze([...DEFAULT_INSPECTOR_ORDER]);
  expect(moveSection(original, "context", "changes", true).slice(0, 4).join(",")).toBe(
    "environment,connectors,changes,context",
  );
  expect(original).toEqual(DEFAULT_INSPECTOR_ORDER);
  expect(moveSection(original, "changes", "changes")).toBe(original);
});
