import { afterEach, beforeEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { resetChatDisplayForTests } from "../src/agent-session/acpmux/chatDisplay";
import { setComposerLook, useComposerLook } from "../src/agent-session/acpmux/composerLook";

import { OnNewTab } from "../src/agent-session/acpmux/newTabComposer";

const storageDescriptor = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
let values: Map<string, string>;

function Look() {
  return <span>{useComposerLook()}</span>;
}

const currentLook = () => renderToStaticMarkup(<Look />);

// These read this launch's copy, before the host's `display` value comes (composer-look-restart.test.tsx
// covers the host's value): each test starts as a new page.
beforeEach(() => {
  resetChatDisplayForTests();
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
  resetChatDisplayForTests();
  if (storageDescriptor) Object.defineProperty(globalThis, "localStorage", storageDescriptor);
  else Reflect.deleteProperty(globalThis, "localStorage");
});

test("a composer with no saved choice uses Claude without writing a preference", () => {
  // Leo, 2026-11-18: "plus, we wanted to have the claude style by default..."
  expect(currentLook()).toBe("<span>claude</span>");
  expect(values.size).toBe(0);
});

test("both explicit saved looks survive the default changing", () => {
  for (const look of ["claude", "codex"] as const) {
    values.set("cmux.composer.look", look);
    expect(currentLook()).toBe(`<span>${look}</span>`);
    expect(values.get("cmux.composer.look")).toBe(look);
  }
});

test("an unknown stored look uses Claude and an explicit choice still persists", () => {
  values.set("cmux.composer.look", "retired-look");
  expect(currentLook()).toBe("<span>claude</span>");
  setComposerLook("codex");
  expect(currentLook()).toBe("<span>codex</span>");
  expect(values.get("cmux.composer.look")).toBe("codex");
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

test("New Tab ignores saved and unknown chat looks without rewriting storage", () => {
  for (const saved of [null, "claude", "codex", "retired-look"]) {
    if (saved) values.set("cmux.composer.look", saved);
    else values.delete("cmux.composer.look");
    expect(
      renderToStaticMarkup(
        <OnNewTab.Provider value={true}>
          <Look />
        </OnNewTab.Provider>,
      ),
    ).toBe("<span>claude</span>");
    expect(values.get("cmux.composer.look") ?? null).toBe(saved);
  }
});
