// Studio's composer look (composerLook.ts `studio`): only Settings' agentPane.composerLook picks it,
// it lays the row inside the box as Codex's does, the dots offer it only while it is the look, and
// New Tab stays Claude's. The default (`auto`) and the dots' two looks are unchanged.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import {
  COMPOSER_LOOKS,
  lookRowInBox,
  registerComposerLookHost,
  setComposerLook,
  useComposerLook,
} from "../src/agent-session/acpmux/composerLook";
import { readComposerSettings, setComposerSettings } from "../src/agent-session/acpmux/composerSettings";
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
  registerComposerLookHost(undefined);
  setComposerSettings({ composerLook: "auto" });
  setComposerLook("codex");
  if (storageDescriptor) Object.defineProperty(globalThis, "localStorage", storageDescriptor);
  else Reflect.deleteProperty(globalThis, "localStorage");
});

test("the setting reads studio; anything else is still auto", () => {
  expect(readComposerSettings({ composerLook: "studio" }).composerLook).toBe("studio");
  for (const bad of ["Studio", "studio ", 3])
    expect(readComposerSettings({ composerLook: bad }).composerLook).toBe("auto");
});

test("the studio setting draws Studio's look over the stored one; New Tab stays Claude's", () => {
  values.set("cmux.composer.look", "claude");
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

test("Studio's row sits in the box as Codex's; Claude's stays under it", () => {
  expect(lookRowInBox("studio")).toBe(true);
  expect(lookRowInBox("codex")).toBe(true);
  expect(lookRowInBox("claude")).toBe(false);
});

test("the dots keep their two looks; a dot picked from Studio writes that look", () => {
  expect([...COMPOSER_LOOKS]).toEqual(["claude", "codex"]);
  const writes: string[] = [];
  registerComposerLookHost((look) => void writes.push(look));
  setComposerSettings({ composerLook: "studio" });
  setComposerLook("codex");
  expect(currentLook()).toBe("<span>codex</span>");
  expect(writes).toEqual(["codex"]);
});

test("a stored studio stays studio (a gallery stage or a written setting), never the default", () => {
  values.set("cmux.composer.look", "studio");
  expect(currentLook()).toBe("<span>studio</span>");
});
