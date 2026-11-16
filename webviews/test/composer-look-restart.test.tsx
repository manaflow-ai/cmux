// The composer's look and the model chip's logo survive a restart (Leo, 2026-11-14: "if i picked
// the claude style composer it should remember it after restart instead of always only going to the
// codex mode"). The agent pages' storage ends with the launch (AgentPaneView.sharedDataStore,
// Chromium's off-the-record profile), so a restart here is: the page's storage empty again, the
// chat's keys forgotten, and the host's `display` event carrying what cmux-next.json kept, which is
// only what the page wrote through `pane.setDisplay`.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import {
  COMPOSER_LOOK_KEY,
  MODEL_CHIP_ICON_KEY,
  QUEUEING_KEY,
  registerChatDisplayHost,
  resetChatDisplayForTests,
  setChatDisplay,
} from "../src/agent-session/acpmux/chatDisplay";
import { setComposerLook, useComposerLook } from "../src/agent-session/acpmux/composerLook";
import { setModelChipIcon, useModelChipIcon } from "../src/agent-session/acpmux/modelChipIcon";
import { queueingOn, setQueueing } from "../src/agent-session/acpmux/queueing";

const storageDescriptor = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
/// cmux-next.json's chat keys: what the host keeps across launches.
let file: Record<string, unknown>;

function Look() {
  return <span>{useComposerLook()}</span>;
}
function ChipIcon() {
  return <span>{useModelChipIcon() ? "logo" : "no-logo"}</span>;
}
const shownLook = () => renderToStaticMarkup(<Look />);
const shownChipIcon = () => renderToStaticMarkup(<ChipIcon />);

/// A launch: the page's storage starts empty, and the host writes the page's picks to the file.
function launch() {
  const values = new Map<string, string>();
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: {
      getItem: (key: string) => values.get(key) ?? null,
      setItem: (key: string, value: string) => void values.set(key, value),
      removeItem: (key: string) => void values.delete(key),
    },
  });
  resetChatDisplayForTests();
  registerChatDisplayHost((key, value) => {
    if (value === null) delete file[key];
    else file[key] = value;
    for (const wrote of writes.splice(0)) wrote();
  });
}

/// The host's first `display` push after the page loads: what the file holds.
const hostSendsDisplay = () => setChatDisplay({ ...file });

/// Waiters for the host's next write: the page writes a pick once its debounce passed
/// (chatDisplay.ts WRITE_DELAY_MS). Code that never writes the pick never settles, and the test fails.
const writes: (() => void)[] = [];
const writesSettle = () => new Promise<void>((resolve) => writes.push(resolve));

beforeEach(() => {
  file = {};
});

afterEach(() => {
  resetChatDisplayForTests();
  if (storageDescriptor) Object.defineProperty(globalThis, "localStorage", storageDescriptor);
  else Reflect.deleteProperty(globalThis, "localStorage");
});

test("a Claude composer picked before a restart is the look after it", async () => {
  launch();
  hostSendsDisplay();
  expect(shownLook()).toBe("<span>codex</span>");
  setComposerLook("claude");
  expect(shownLook()).toBe("<span>claude</span>");
  await writesSettle();
  expect(file[COMPOSER_LOOK_KEY]).toBe("claude");

  // Restart: the page's storage is gone; the host sends what the file kept.
  launch();
  hostSendsDisplay();
  expect(shownLook()).toBe("<span>claude</span>");

  // And back to Codex is kept as explicitly.
  setComposerLook("codex");
  await writesSettle();
  launch();
  hostSendsDisplay();
  expect(file[COMPOSER_LOOK_KEY]).toBe("codex");
  expect(shownLook()).toBe("<span>codex</span>");
});

test("the host's look wins over this launch's copy once it comes, and the copy holds until then", async () => {
  launch();
  localStorage.setItem("cmux.composer.look", "claude");
  // A page opened after a pick in this launch draws it before the host's value comes.
  expect(shownLook()).toBe("<span>claude</span>");
  file[COMPOSER_LOOK_KEY] = "codex";
  hostSendsDisplay();
  expect(shownLook()).toBe("<span>codex</span>");
  // Settings or another pane changes the file: every composer follows.
  setChatDisplay({ [COMPOSER_LOOK_KEY]: "claude" });
  expect(shownLook()).toBe("<span>claude</span>");
});

test("a model chip logo turned off before a restart stays off after it", async () => {
  launch();
  hostSendsDisplay();
  expect(shownChipIcon()).toBe("<span>logo</span>");
  setModelChipIcon(false);
  expect(shownChipIcon()).toBe("<span>no-logo</span>");
  await writesSettle();
  expect(file[MODEL_CHIP_ICON_KEY]).toBe(false);

  launch();
  hostSendsDisplay();
  expect(shownChipIcon()).toBe("<span>no-logo</span>");

  // On is the default: turning it back on removes the key.
  setModelChipIcon(true);
  await writesSettle();
  expect(MODEL_CHIP_ICON_KEY in file).toBe(false);
  launch();
  hostSendsDisplay();
  expect(shownChipIcon()).toBe("<span>logo</span>");
});

test("queueing turned off before a restart stays off after it", async () => {
  launch();
  hostSendsDisplay();
  expect(queueingOn()).toBe(true);
  setQueueing(false);
  expect(queueingOn()).toBe(false);
  await writesSettle();
  expect(file[QUEUEING_KEY]).toBe(false);

  launch();
  hostSendsDisplay();
  expect(queueingOn()).toBe(false);
  setQueueing(true);
  await writesSettle();
  expect(QUEUEING_KEY in file).toBe(false);
});
