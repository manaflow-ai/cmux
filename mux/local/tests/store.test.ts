import { expect, test } from "bun:test";
import { LocalStore } from "../src/store.ts";

test("conversations keep messages in order and list newest first", () => {
  const store = new LocalStore(":memory:");
  const a = store.create("a", []);
  const b = store.create("b", []);
  store.append(a.id, "u", [{ type: "text", text: "one" }]);
  store.append(a.id, "m", [{ type: "text", text: "two" }]);
  store.append(b.id, "u", [{ type: "text", text: "three" }]);
  expect(store.get(a.id)?.messages.map((m) => (m.parts[0] as { text: string }).text)).toEqual([
    "one",
    "two",
  ]);
  expect(store.list().map((c) => c.id)).toEqual([b.id, a.id]);
  expect(store.list()[0].preview).toBe("three");
  expect(store.get("missing")).toBeUndefined();
  const c = store.create("c", []);
  expect(store.list()[0].id).toBe(c.id);
});
