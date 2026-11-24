import { expect, test } from "bun:test";
import { newKinds, readHeaderControls, readLastKind, repeatKind, writeLastKind } from "./headerTrio";

const memory = () => {
  const items = new Map<string, string>();
  return {
    getItem: (key: string) => items.get(key) ?? null,
    setItem: (key: string, value: string) => void items.set(key, value),
  };
};

test("today's row unless the App picks the three controls", () => {
  expect(readHeaderControls("trio")).toBe("trio");
  expect(readHeaderControls("standard")).toBe("standard");
  expect(readHeaderControls("four")).toBeUndefined();
  expect(readHeaderControls(undefined)).toBeUndefined();
});

test("New lists every kind the chat can make, in order", () => {
  expect(newKinds({})).toEqual(["terminal", "browser", "sideChat", "newTab"]);
  // A side chat needs a turn to fork; a chat not started yet has no New Tab page beside it.
  expect(newKinds({ sideChat: false, newTab: false })).toEqual(["terminal", "browser"]);
});

test("the face makes the last kind again: a terminal stays one click", () => {
  expect(repeatKind("terminal", newKinds({}))).toBe("terminal");
  expect(repeatKind("browser", newKinds({}))).toBe("browser");
});

test("the first click opens the New Tab page, and a kind the chat cannot make falls back to it", () => {
  expect(repeatKind(undefined, newKinds({}))).toBe("newTab");
  expect(repeatKind("sideChat", newKinds({ sideChat: false }))).toBe("newTab");
  // With no New Tab page beside a chat not started yet, a terminal.
  expect(repeatKind(undefined, newKinds({ newTab: false }))).toBe("terminal");
});

test("the last kind is kept, and a value it does not know is ignored", () => {
  const storage = memory();
  expect(readLastKind(storage)).toBeUndefined();
  writeLastKind("browser", storage);
  expect(readLastKind(storage)).toBe("browser");
  storage.setItem("acpmux.header.newKind", "spaceship");
  expect(readLastKind(storage)).toBeUndefined();
});
