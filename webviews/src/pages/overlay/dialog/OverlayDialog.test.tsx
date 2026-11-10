// The overlay page's dialog: presses and edits go to the host with every value, Return and Escape
// press the spec's default and cancel buttons, and a safe-default dialog draws its destructive
// choices as a quiet row with its check boxes last.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { layoutBox, OverlayDialog } from "./OverlayDialog";
import type { DialogState, DialogValue } from "./types";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "KeyboardEvent",
  "ResizeObserver",
  "MutationObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];

function installDom() {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const w = dom.window as unknown as Record<string, unknown>;
  for (const key of GLOBALS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    KeyboardEvent: dom.window.KeyboardEvent,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: w.requestAnimationFrame,
    cancelAnimationFrame: w.cancelAnimationFrame,
    ResizeObserver: class {
      observe() {}
      disconnect() {}
    },
    IS_REACT_ACT_ENVIRONMENT: true,
  });
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

const quit: DialogState = {
  id: 7,
  title: "Quit cmux?",
  lines: ["2 terminals are running."],
  fields: [
    { kind: "check", id: "dontAsk", title: "Don't ask again" },
    { kind: "text", id: "note", label: "Note", secure: false },
  ],
  buttons: [
    { id: "end", title: "End Everything", role: "destructive" },
    { id: "cancel", title: "Cancel", role: "cancel" },
    { id: "keep", title: "Keep Sessions", role: "default" },
  ],
  keys: { return: "keep", escape: "cancel", command: {} },
  layout: "safeDefault",
  values: { dontAsk: false, note: "" },
  focus: null,
};

async function render(dialog: DialogState) {
  installDom();
  const presses: { button: string; values: Record<string, DialogValue> }[] = [];
  const edits: Record<string, DialogValue>[] = [];
  const layouts: unknown[] = [];
  root = createRoot(dom!.window.document.getElementById("root")!);
  await act(async () => {
    root!.render(
      <OverlayDialog
        dialog={dialog}
        onPress={(button, values) => presses.push({ button, values })}
        onEdit={(values) => edits.push(values)}
        onLayout={(card) => layouts.push(card)}
      />,
    );
  });
  // The dialog portals into the body.
  return { host: dom!.window.document.body, presses, edits, layouts };
}

function key(target: Element, init: KeyboardEventInit) {
  act(() => {
    target.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { bubbles: true, ...init }));
  });
}

test("a click presses its button with every value", async () => {
  const { host, presses } = await render(quit);
  act(() => (host.querySelector('[data-button="keep"]') as HTMLButtonElement).click());
  expect(presses).toEqual([{ button: "keep", values: { dontAsk: false, note: "" } }]);
});

test("Return presses the default and Escape the cancel button, from inside a field", async () => {
  const { host, presses } = await render(quit);
  const field = host.querySelector('[data-field="note"]')!;
  key(field, { key: "Enter" });
  key(field, { key: "Escape" });
  expect(presses.map((press) => press.button)).toEqual(["keep", "cancel"]);
});

test("the first text field takes the keyboard, never a button", async () => {
  const { host } = await render(quit);
  // The dialog moves the focus in after it opens, a few frames on.
  const field = host.querySelector('[data-field="note"]');
  for (let frame = 0; frame < 30 && dom!.window.document.activeElement !== field; frame++) {
    await act(async () => {
      await new Promise((resolve) => dom!.window.requestAnimationFrame(resolve));
    });
  }
  expect(dom!.window.document.activeElement).toBe(host.querySelector('[data-field="note"]'));
});

test("a safe-default dialog draws its destructive choice quiet, under the main row, and its check box last", async () => {
  const { host } = await render(quit);
  const card = host.querySelector(".overlay-dialog")!;
  const main = [...card.querySelectorAll(".overlay-dialog-buttons button")].map((node) =>
    node.getAttribute("data-button"),
  );
  const quiet = [...card.querySelectorAll(".overlay-dialog-quiet button")].map((node) =>
    node.getAttribute("data-button"),
  );
  expect(main).toEqual(["cancel", "keep"]);
  expect(quiet).toEqual(["end"]);
  expect(card.lastElementChild?.querySelector('[data-field="dontAsk"]')).not.toBeNull();
  expect(card.querySelector(".overlay-dialog-keyhint")).toBeNull();
});

test("an edit sends every value, and the press after it carries the edit", async () => {
  const { host, presses, edits } = await render(quit);
  act(() => (host.querySelector('[data-field="dontAsk"]') as HTMLInputElement).click());
  expect(edits.at(-1)).toEqual({ dontAsk: true, note: "" });
  act(() => (host.querySelector('[data-button="keep"]') as HTMLButtonElement).click());
  expect(presses.at(-1)?.values).toEqual({ dontAsk: true, note: "" });
});

test("a standard dialog shows each button's key and tells the host its card", async () => {
  const { host, layouts } = await render({
    ...quit,
    layout: "standard",
    buttons: [
      { id: "cancel", title: "Cancel", role: "cancel", hint: "⎋", hintLabel: "Escape" },
      { id: "keep", title: "Keep", role: "default", hint: "↩", hintLabel: "Return" },
    ],
  });
  const hints = [...host.querySelectorAll(".overlay-dialog-keyhint")].map((node) => node.textContent);
  expect(hints).toEqual(["⎋", "↩"]);
  expect(host.querySelector('[data-button="keep"]')?.getAttribute("aria-keyshortcuts")).toBe("Return");
  expect(layouts.length).toBeGreaterThan(0);
});

test("shown again after a tab switch, the focus goes back to the first text field", async () => {
  const { host } = await render(quit);
  const field = host.querySelector('[data-field="note"]') as HTMLInputElement;
  const keep = host.querySelector('[data-button="keep"]') as HTMLButtonElement;
  act(() => keep.focus());
  expect(dom!.window.document.activeElement).toBe(keep);
  await act(async () => {
    root!.render(
      <OverlayDialog dialog={{ ...quit, shown: 2 }} onPress={() => {}} onEdit={() => {}} onLayout={() => {}} />,
    );
  });
  expect(dom!.window.document.activeElement).toBe(field);
});

test("a host update keeps the text the person typed, secure or not, and each edit gives it to the host", async () => {
  const login: DialogState = {
    ...quit,
    layout: "standard",
    fields: [
      { kind: "text", id: "user", label: "User", secure: false },
      { kind: "text", id: "password", label: "Password", secure: true },
    ],
    values: { user: "", password: "" },
  };
  const { host, presses, edits } = await render(login);
  const user = host.querySelector('[data-field="user"]') as HTMLInputElement;
  const field = host.querySelector('[data-field="password"]') as HTMLInputElement;
  const setter = Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!;
  act(() => {
    setter.call(user, "leo");
    user.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  act(() => {
    setter.call(field, "hunter2");
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  // The host answers its own keys and automation's presses with what it has (review 7 of #37296).
  expect(edits.at(-1)).toEqual({ user: "leo", password: "hunter2" });
  // A key the host answered moves the focus: a new state, with the host's own (empty) values.
  await act(async () => {
    root!.render(
      <OverlayDialog
        dialog={{ ...login, values: { user: "", password: "" }, focus: { serial: 1, backward: false } }}
        onPress={(button, values) => presses.push({ button, values })}
        onEdit={(values) => edits.push(values)}
        onLayout={() => {}}
      />,
    );
  });
  // Review 32 of #37296 (F1): the ordinary field kept its text too.
  expect(user.value).toBe("leo");
  expect(field.value).toBe("hunter2");
  act(() => (host.querySelector('[data-button="keep"]') as HTMLButtonElement).click());
  expect(presses.at(-1)?.values).toEqual({ user: "leo", password: "hunter2" });
});

test("buttons that do not fit on one line stack, and stay on one line when they fit (#29984)", async () => {
  installDom();
  const proto = dom!.window.HTMLElement.prototype;
  // jsdom lays nothing out: each button reports its width, the row its own.
  let buttonWidth = 150;
  Object.defineProperty(proto, "clientWidth", { configurable: true, get: () => 400 });
  const rect = proto.getBoundingClientRect;
  proto.getBoundingClientRect = function (this: HTMLElement) {
    if (!this.classList.contains("overlay-dialog-button")) return rect.call(this);
    return { x: 0, y: 0, top: 0, left: 0, right: buttonWidth, bottom: 26, width: buttonWidth, height: 26, toJSON() {} };
  };
  const quitChoice: DialogState = {
    ...quit,
    layout: "standard",
    fields: [],
    values: {},
    buttons: [
      { id: "cancel", title: "Cancel", role: "cancel" },
      { id: "end", title: "End Everything", role: "destructive" },
      { id: "layout", title: "End Sessions, Keep Layout", role: "normal" },
      { id: "keep", title: "Keep Sessions", role: "default" },
    ],
  };
  const mount = async (dialog: DialogState) => {
    root ??= createRoot(dom!.window.document.getElementById("root")!);
    await act(async () => {
      root!.render(<OverlayDialog dialog={dialog} onPress={() => {}} onEdit={() => {}} onLayout={() => {}} />);
    });
    return dom!.window.document.body.querySelector<HTMLElement>(".overlay-dialog-buttons")!;
  };
  expect((await mount(quitChoice)).dataset.stacked).not.toBeUndefined();
  // Two that fit stay on one line.
  buttonWidth = 150;
  expect((await mount({ ...quitChoice, buttons: quitChoice.buttons.slice(2) })).dataset.stacked).toBeUndefined();
});

// Review 25 of #37296 (F3): the buttons were measured drawn, at the entrance's opening scale, against the
// row's layout width, so a row that does not fit measured as fitting while the card scaled in.
test("buttons that do not fit stack while the card is drawn at its opening scale", async () => {
  installDom();
  const proto = dom!.window.HTMLElement.prototype;
  const scale = 0.97;
  const isRow = (node: HTMLElement) => node.classList.contains("overlay-dialog-buttons");
  Object.defineProperty(proto, "clientWidth", { configurable: true, get: () => 400 });
  Object.defineProperty(proto, "offsetWidth", {
    configurable: true,
    get(this: HTMLElement) {
      return isRow(this) ? 400 : 0;
    },
  });
  const rect = proto.getBoundingClientRect;
  proto.getBoundingClientRect = function (this: HTMLElement) {
    // Two buttons of 200 and an 8 px gap need 408 of the row's 400; drawn, they are 194 each.
    const width = isRow(this) ? 400 * scale : this.classList.contains("overlay-dialog-button") ? 200 * scale : 0;
    if (width === 0) return rect.call(this);
    return { x: 0, y: 0, top: 0, left: 0, right: width, bottom: 26, width, height: 26, toJSON() {} };
  };
  const style = scope.getComputedStyle as (node: Element) => CSSStyleDeclaration;
  scope.getComputedStyle = (node: Element) => {
    const computed = style(node);
    if (!(node instanceof dom!.window.HTMLElement) || !isRow(node)) return computed;
    return new Proxy(computed, { get: (target, key) => (key === "columnGap" ? "8px" : Reflect.get(target, key)) });
  };
  root ??= createRoot(dom!.window.document.getElementById("root")!);
  const dialog: DialogState = {
    ...quit,
    layout: "standard",
    fields: [],
    values: {},
    buttons: [
      { id: "cancel", title: "Cancel", role: "cancel" },
      { id: "keep", title: "Keep Sessions", role: "default" },
    ],
  };
  await act(async () => {
    root!.render(<OverlayDialog dialog={dialog} onPress={() => {}} onEdit={() => {}} onLayout={() => {}} />);
  });
  const row = dom!.window.document.body.querySelector<HTMLElement>(".overlay-dialog-buttons")!;
  expect(row.dataset.stacked).not.toBeUndefined();
});

test("a value the host sets wins over the secure text the person typed", async () => {
  const login: DialogState = {
    ...quit,
    layout: "standard",
    fields: [{ kind: "text", id: "password", label: "Password", secure: true }],
    values: { password: "" },
  };
  const { host, presses } = await render(login);
  const field = host.querySelector('[data-field="password"]') as HTMLInputElement;
  act(() => {
    const setter = Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(field, "hunter2");
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  // Automation's setValue clears the field: the host bumps its values serial.
  await act(async () => {
    root!.render(
      <OverlayDialog
        dialog={{ ...login, values: { password: "swordfish" }, valuesSerial: 1 }}
        onPress={(button, values) => presses.push({ button, values })}
        onEdit={() => {}}
        onLayout={() => {}}
      />,
    );
  });
  expect(field.value).toBe("swordfish");
  act(() => (host.querySelector('[data-button="keep"]') as HTMLButtonElement).click());
  expect(presses.at(-1)?.values).toEqual({ password: "swordfish" });
});

test("the card tells the host a frame after it drew, once per dialog", async () => {
  installDom();
  let painted = 0;
  root = createRoot(dom!.window.document.getElementById("root")!);
  await act(async () => {
    root!.render(
      <OverlayDialog
        dialog={quit}
        onPress={() => {}}
        onEdit={() => {}}
        onLayout={() => {}}
        onPainted={() => painted++}
      />,
    );
  });
  expect(painted).toBe(0);
  for (let frame = 0; frame < 10 && painted === 0; frame++) {
    await act(async () => {
      await new Promise((resolve) => dom!.window.requestAnimationFrame(resolve));
    });
  }
  expect(painted).toBe(1);
});

// Review 24 of #37296 (F2): the card reported its drawn rect, which the entrance's opening scale shrinks,
// and a ResizeObserver never hears the scale end, so the glass kept the opening size. The card reports its
// layout box, which no transform changes.
test("the card reports its layout box, not its scaled drawn rect", () => {
  const document = new JSDOM("<!doctype html><body></body>").window.document;
  const card = document.createElement("div");
  card.style.transform = "scale(0.97)";
  document.body.append(card);
  Object.defineProperties(card, {
    offsetLeft: { value: 120 },
    offsetTop: { value: 80 },
    offsetWidth: { value: 380 },
    offsetHeight: { value: 180 },
    offsetParent: { value: null },
  });
  card.getBoundingClientRect = () => ({ left: 125, top: 83, width: 368, height: 174 }) as DOMRect;
  expect(layoutBox(card)).toEqual({ x: 120, y: 80, w: 380, h: 180 });
});

test("a long message's lines sit in one block that scrolls at a bounded height, above the buttons", async () => {
  const lines = Array.from({ length: 40 }, (_, index) => `• Workspace ${index}: setup: bun install`);
  const { host } = await render({ ...quit, lines });
  const block = host.querySelector(".overlay-dialog-lines")!;
  expect(block.querySelectorAll(".overlay-dialog-line").length).toBe(40);
  expect(block.compareDocumentPosition(host.querySelector(".overlay-dialog-buttons")!)).toBe(
    dom!.window.Node.DOCUMENT_POSITION_FOLLOWING,
  );
  const css = await Bun.file(new URL("./dialog.css", import.meta.url)).text();
  const rule = css.slice(css.indexOf(".overlay-dialog-lines {"));
  expect(rule.slice(0, rule.indexOf("}"))).toMatch(/max-height:[^;]+;[\s\S]*overflow-y: auto;/);
});

// Lawrence 2026-11-07, a Leave site? dialog over Gmail: "weird roundness", "weird border". A dialog with
// no text field gives its card the keyboard (so Return and Escape reach it), and the pages' keyboard ring
// (desktop.css, 1.5 px at 48% of the text color) then drew a dark second edge around the clear card, at
// the page's corner, not the native glass's. The card is a container, as an open popover is: it takes
// the focus and draws no ring around itself; its buttons keep theirs.
test("a dialog with no text field gives its card the keyboard, and the card draws no focus ring", async () => {
  const leave: DialogState = {
    id: 8,
    title: "Leave site?",
    lines: ["Changes that you made may not be saved."],
    fields: [],
    buttons: [
      { id: "cancel", title: "Cancel", role: "cancel" },
      { id: "ok", title: "Leave", role: "default" },
    ],
    keys: { return: "ok", escape: "cancel", command: {} },
    layout: "standard",
    values: {},
    focus: null,
  };
  const { host } = await render(leave);
  const card = host.querySelector(".overlay-dialog") as HTMLElement;
  for (let frame = 0; frame < 30 && dom!.window.document.activeElement !== card; frame++) {
    await act(async () => {
      await new Promise((resolve) => dom!.window.requestAnimationFrame(resolve));
    });
  }
  const focused = dom!.window.document.activeElement as HTMLElement;
  expect(focused === card).toBe(true);
  expect(focused.getAttribute("data-focus-ring")).toBe("none");
  // Its buttons keep the keyboard ring.
  expect(host.querySelector('[data-button="ok"]')!.hasAttribute("data-focus-ring")).toBe(false);
});

// cmux issue 26412: a Credential Vault Allow is click-only. The host leaves it out of the key map; the card
// gives it no focus and takes only a pointer click, never one a key made on a focused button.
const approval: DialogState = {
  id: 11,
  title: "Allow a command to use PROD_DB?",
  lines: [],
  fields: [{ kind: "text", id: "value", label: "Value", secure: true }],
  buttons: [
    { id: "cancel", title: "Cancel", role: "cancel" },
    { id: "allow", title: "Allow", role: "default", clickOnly: true },
  ],
  keys: { escape: "cancel", command: {} },
  layout: "standard",
  values: { value: "" },
  focus: null,
  focusesField: false,
};

test("a click-only button takes a pointer click but no keyboard click, focus or Tab stop", async () => {
  const { host, presses } = await render(approval);
  const allow = host.querySelector('[data-button="allow"]') as HTMLButtonElement;
  expect(allow.tabIndex).toBe(-1);
  // A click Space or Return made on a focused button has no pointer press (detail 0).
  act(() => {
    allow.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true, detail: 0 }));
  });
  expect(presses).toEqual([]);
  act(() => {
    allow.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true, detail: 1 }));
  });
  expect(presses.map((press) => press.button)).toEqual(["allow"]);
  // Pressing the mouse on it does not move the focus to it.
  const down = new dom!.window.MouseEvent("mousedown", { bubbles: true, cancelable: true, detail: 1 });
  act(() => {
    allow.dispatchEvent(down);
  });
  expect(down.defaultPrevented).toBe(true);
});

test("Tab never reaches a click-only button", async () => {
  const { host } = await render({ ...approval, focusesField: true });
  const field = host.querySelector('[data-field="value"]') as HTMLInputElement;
  const cancel = host.querySelector('[data-button="cancel"]') as HTMLButtonElement;
  act(() => field.focus());
  key(field, { key: "Tab" });
  expect(dom!.window.document.activeElement).toBe(cancel);
  key(cancel, { key: "Tab" });
  expect(dom!.window.document.activeElement).toBe(field);
});

test("a dialog that does not focus its field starts on the card", async () => {
  const { host } = await render(approval);
  const card = host.querySelector(".overlay-dialog");
  for (let frame = 0; frame < 30 && dom!.window.document.activeElement !== card; frame++) {
    await act(async () => {
      await new Promise((resolve) => dom!.window.requestAnimationFrame(resolve));
    });
  }
  expect(dom!.window.document.activeElement).toBe(card);
  expect(dom!.window.document.activeElement).not.toBe(host.querySelector('[data-field="value"]'));
});
