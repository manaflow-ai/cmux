import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { PermissionCard } = await import("./PermissionCard");
const { permissionKeys } = await import("./permissionKeys");
const { bareKey, isTextEntry } = await import("./keyTarget");
type AcpmuxPermission = import("./model").AcpmuxPermission;

const doc = dom.window.document;
let root: ReturnType<typeof createRoot>;
beforeEach(() => {
  root = createRoot(doc.getElementById("root")!);
});
afterEach(async () => act(async () => root.unmount()));

/// The options Claude Code and Codex send, in their order.
const ask: AcpmuxPermission = {
  permissionId: "p1",
  title: "Run git push?",
  pending: true,
  options: [
    { id: "allow_once", name: "Allow", allow: true },
    { id: "allow_always", name: "Always allow", allow: true },
    { id: "reject_once", name: "Deny", allow: false },
  ],
};

async function render(permission: AcpmuxPermission) {
  const answers: string[] = [];
  await act(async () =>
    root.render(createElement(PermissionCard, { permission, onAnswer: (id: string) => answers.push(id) })),
  );
  return answers;
}

const buttons = () => [...doc.querySelectorAll<HTMLButtonElement>(".acpmux-permission-buttons button")];

async function press(key: string, init: Partial<KeyboardEventInit> = {}, target: Element = buttons()[0]!) {
  if (target instanceof dom.window.HTMLElement) target.focus();
  await act(async () => {
    target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init }));
  });
}

test("y allows once, a always allows, n denies; leftovers take their position", () => {
  expect([...permissionKeys(ask.options)]).toEqual([
    ["allow_once", "y"],
    ["allow_always", "a"],
    ["reject_once", "n"],
  ]);
  // Ids an agent names its own way: the allow flag and "always" in the name decide.
  const custom = [
    { id: "proceed", name: "Yes", allow: true },
    { id: "proceed_session", name: "Yes, always for this session", allow: true },
    { id: "cancel", name: "No, and tell the agent", allow: false },
    { id: "never", name: "Always deny", allow: false },
  ];
  expect([...permissionKeys(custom)]).toEqual([
    ["proceed", "y"],
    ["proceed_session", "a"],
    ["cancel", "n"],
    ["never", "4"],
  ]);
});

test("each button shows its key", async () => {
  await render(ask);
  expect(buttons().map((button) => button.querySelector(".acpmux-keycap")?.textContent)).toEqual(["y", "a", "n"]);
  expect(buttons().map((button) => button.getAttribute("aria-keyshortcuts"))).toEqual(["y", "a", "n"]);
  // The keycap is decoration: the button's name stays the option's.
  expect(buttons()[2]!.querySelector(".acpmux-keycap")!.getAttribute("aria-hidden")).toBe("true");
});

test("a key answers the ask it is focused in", async () => {
  const answers = await render(ask);
  await press("n");
  await press("a");
  await press("y");
  // Digits pick by position too.
  await press("3");
  expect(answers).toEqual(["reject_once", "allow_always", "allow_once", "reject_once"]);
});

test("a key with a modifier, while composing, or for no option does nothing", async () => {
  const answers = await render(ask);
  await press("y", { metaKey: true });
  await press("y", { ctrlKey: true });
  await press("y", { altKey: true });
  await press("Y", { shiftKey: true });
  await press("y", { isComposing: true });
  await press("q");
  await press("7");
  expect(answers).toEqual([]);
});

test("one ask takes one answer from the keyboard: no key repeat, no second key", async () => {
  const answers = await render(ask);
  await press("y", { repeat: true });
  await press("n");
  await press("y");
  expect(answers).toEqual(["reject_once"]);
});

test("the ask is named by its title once", async () => {
  await render(ask);
  const group = doc.querySelector("fieldset")!;
  expect(group.getAttribute("aria-label")).toBeNull();
  expect(doc.getElementById(group.getAttribute("aria-labelledby")!)?.textContent).toBe("Run git push?");
});

test("an answered ask takes no keys", async () => {
  const answers = await render({ ...ask, pending: false });
  await press("y");
  expect(answers).toEqual([]);
  expect(buttons()[0]!.querySelector(".acpmux-keycap")).toBeNull();
});

test("typing never counts as a key", () => {
  const field = doc.createElement("input");
  const area = doc.createElement("textarea");
  const prompt = doc.createElement("div");
  prompt.setAttribute("contenteditable", "true");
  const inside = doc.createElement("span");
  prompt.append(inside);
  const button = doc.createElement("button");
  doc.body.append(field, area, prompt, button);
  expect([field, area, prompt, inside].map(isTextEntry)).toEqual([true, true, true, true]);
  expect(isTextEntry(button)).toBe(false);
  const keyOn = (target: Element) => {
    const event = new dom.window.KeyboardEvent("keydown", { key: "y", bubbles: true });
    let key: string | undefined;
    target.addEventListener("keydown", (seen) => (key = bareKey(seen as KeyboardEvent)), { once: true });
    target.dispatchEvent(event);
    return key;
  };
  expect(keyOn(inside)).toBeUndefined();
  expect(keyOn(button)).toBe("y");
});
