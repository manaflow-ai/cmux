import { afterEach, beforeEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { setComposerLook, useComposerLook } from "../src/agent-session/acpmux/composerLook";

const storageDescriptor = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
let values: Map<string, string>;

function Look() {
  return <span>{useComposerLook()}</span>;
}

const currentLook = () => renderToStaticMarkup(<Look />);

beforeEach(() => {
  values = new Map();
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: {
      getItem: (key: string) => values.get(key) ?? null,
      setItem: (key: string, value: string) => values.set(key, value),
    },
  });
});

afterEach(() => {
  setComposerLook("codex");
  if (storageDescriptor) Object.defineProperty(globalThis, "localStorage", storageDescriptor);
  else Reflect.deleteProperty(globalThis, "localStorage");
});

test("a composer with no saved choice uses Codex without writing a preference", () => {
  expect(currentLook()).toBe("<span>codex</span>");
  expect(values.size).toBe(0);
});

test("both explicit saved looks survive the default changing", () => {
  for (const look of ["claude", "codex"] as const) {
    values.set("cmux.composer.look", look);
    expect(currentLook()).toBe(`<span>${look}</span>`);
    expect(values.get("cmux.composer.look")).toBe(look);
  }
});

test("an unknown stored look uses Codex and an explicit choice still persists", () => {
  values.set("cmux.composer.look", "retired-look");
  expect(currentLook()).toBe("<span>codex</span>");
  setComposerLook("claude");
  expect(currentLook()).toBe("<span>claude</span>");
  expect(values.get("cmux.composer.look")).toBe("claude");
});

test("a look selection remains usable when preference storage is unavailable", () => {
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    get: () => {
      throw new Error("Storage unavailable");
    },
  });
  setComposerLook("claude");
  expect(currentLook()).toBe("<span>claude</span>");
  setComposerLook("codex");
  expect(currentLook()).toBe("<span>codex</span>");
});
