import { afterEach, beforeEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { useComposerLook, setPreviewComposerLook } from "../src/agent-session/acpmux/composerLook";
import { setComposerSettings } from "../src/agent-session/acpmux/composerSettings";
import { OnNewTab } from "../src/agent-session/acpmux/newTabComposer";

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
  setPreviewComposerLook();
  setComposerSettings({ composerLook: "auto" });
  if (storageDescriptor) Object.defineProperty(globalThis, "localStorage", storageDescriptor);
  else Reflect.deleteProperty(globalThis, "localStorage");
});

test("agent chat uses the standard composer with or without a legacy look preference", () => {
  expect(currentLook()).toBe("<span>claude</span>");
  expect(values.size).toBe(0);
  for (const look of ["claude", "codex", "retired-look"]) {
    values.set("cmux.composer.look", look);
    expect(currentLook()).toBe("<span>claude</span>");
    expect(values.get("cmux.composer.look")).toBe(look);
  }
});

test("New Tab keeps the standard composer in a gallery preview of the former layout", () => {
  setPreviewComposerLook("codex");
  expect(currentLook()).toBe("<span>codex</span>");
  expect(
    renderToStaticMarkup(
      <OnNewTab.Provider value={true}>
        <Look />
      </OnNewTab.Provider>,
    ),
  ).toBe("<span>claude</span>");
  expect(values.size).toBe(0);
});

// Settings' agentPane.composerLook: `auto` (the default) is the standard composer above, whatever
// the stored legacy look; only `studio` draws another, and New Tab stays standard.
test("the auto setting keeps the standard composer over a legacy look preference", () => {
  setComposerSettings({ composerLook: "auto" });
  values.set("cmux.composer.look", "codex");
  expect(currentLook()).toBe("<span>claude</span>");
});

test("the studio setting draws Studio's look in a chat, never on New Tab", () => {
  setComposerSettings({ composerLook: "studio" });
  expect(currentLook()).toBe("<span>studio</span>");
  expect(
    renderToStaticMarkup(
      <OnNewTab.Provider value={true}>
        <Look />
      </OnNewTab.Provider>,
    ),
  ).toBe("<span>claude</span>");
  setComposerSettings({ composerLook: "auto" });
  expect(currentLook()).toBe("<span>claude</span>");
});
