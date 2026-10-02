import { afterAll, afterEach, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

const dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, virtualConsole: new VirtualConsole() });
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]));
Object.assign(globals, { window: dom.window, document: dom.window.document, navigator: dom.window.navigator, HTMLElement: dom.window.HTMLElement, IS_REACT_ACT_ENVIRONMENT: true });
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { Composer } = await import("./Composer");

/// Types into the prompt. React decides when react-dom loads whether the page has
/// input events, and a test file that loads it before any DOM exists (the
/// router tests do) leaves it without them, so call the change handler directly.
function typeInto(node: HTMLTextAreaElement, value: string) {
  node.value = value;
  node.setSelectionRange(value.length, value.length);
  const props = (node as unknown as Record<string, { onChange(event: { target: HTMLTextAreaElement }): void }>)[Object.keys(node).find((key) => key.startsWith("__reactProps$"))!]!;
  props.onChange({ target: node });
}

const snapshot = (commands?: AcpmuxSnapshot["commands"]): AcpmuxSnapshot => ({ type: "snapshot", protocolVersion: 1, rows: [], sessions: [], connection: "connected", isWorking: false, queue: [], catalog: [], canLoadOlder: false, commands });
const commands = [
  { name: "compact", description: "Summarize the conversation" },
  { name: "review", description: "Review changes", hint: "branch or PR" },
  { name: "pr-comments", description: "Read PR comments" },
];

describe("acpmux composer slash menu", () => {
  let root: ReturnType<typeof createRoot>;
  let sent: string[];
  const textarea = () => dom.window.document.querySelector("textarea")!;
  const rows = () => [...dom.window.document.querySelectorAll(".acpmux-slash-row")].map((row) => row.querySelector(".acpmux-slash-name")!.textContent);
  const active = () => dom.window.document.querySelector(".acpmux-slash-active .acpmux-slash-name")?.textContent;
  const menu = () => dom.window.document.querySelector(".acpmux-slash-menu");
  const type = async (value: string) => act(async () => typeInto(textarea(), value));
  /// jsdom fires `select` a task after the caret moves; let it land inside act.
  const settle = async () => act(() => new Promise((resolve) => setTimeout(resolve, 0)));
  const key = async (name: string, isComposing = false) => act(async () => { textarea().dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, isComposing, bubbles: true, cancelable: true })); });
  const render = async (value: AcpmuxSnapshot) => act(async () => root.render(createElement(Composer, { snapshot: value, chips: () => null, onSend: (text: string) => { sent.push(text); }, onStop: () => {} })));

  beforeEach(() => { sent = []; root = createRoot(dom.window.document.getElementById("root")!); });
  afterEach(async () => { await act(async () => root.unmount()); });

  test("a leading slash lists the agent's commands and narrows as the word grows", async () => {
    await render(snapshot(commands));
    expect(menu()).toBeNull();
    await type("/");
    expect(rows()).toEqual(["/compact", "/review", "/pr-comments"]);
    await type("/com");
    expect(rows()).toEqual(["/compact", "/pr-comments"]);
    expect([...dom.window.document.querySelectorAll(".acpmux-slash-row mark")].map((mark) => mark.textContent)).toEqual(["com", "com"]);
    await type("/review ");
    expect(menu()).toBeNull();
    await type("say /com");
    expect(menu()).toBeNull();
  });

  test("arrows move the selection and Enter writes the command without sending", async () => {
    await render(snapshot(commands));
    await type("/");
    expect(active()).toBe("/compact");
    await key("ArrowDown");
    expect(active()).toBe("/review");
    await key("ArrowUp");
    await key("ArrowUp");
    expect(active()).toBe("/pr-comments");
    await key("ArrowDown");
    await key("ArrowDown");
    await key("Enter");
    expect(textarea().value).toBe("/review ");
    await settle();
    expect(textarea().selectionStart).toBe(8);
    expect(menu()).toBeNull();
    expect(sent).toEqual([]);
  });

  test("pressing a row picks it and Escape closes the menu until the prompt changes", async () => {
    await render(snapshot(commands));
    await type("/pr");
    await act(async () => { dom.window.document.querySelector(".acpmux-slash-row")!.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true })); });
    await settle();
    expect(textarea().value).toBe("/pr-comments ");
    await type("/c");
    await key("Escape");
    expect(menu()).toBeNull();
    await type("/co");
    expect(menu()).not.toBeNull();
  });

  test("keys go to the input method while it composes", async () => {
    await render(snapshot(commands));
    await type("/に");
    await type("/");
    await key("ArrowDown", true);
    expect(active()).toBe("/compact");
    await key("Escape", true);
    expect(menu()).not.toBeNull();
    await key("Enter", true);
    expect(textarea().value).toBe("/");
  });

  test("a live update that shrinks the list keeps a row selected", async () => {
    await render(snapshot(commands));
    await type("/");
    await key("ArrowUp");
    expect(active()).toBe("/pr-comments");
    await render(snapshot(commands.slice(0, 2)));
    expect(active()).toBe("/review");
    expect(textarea().getAttribute("aria-activedescendant")).toBe("acpmux-slash-1");
    await key("Enter");
    expect(textarea().value).toBe("/review ");
    expect(textarea().getAttribute("aria-controls")).toBeNull();
  });

  test("an agent with no commands, or no match, says so", async () => {
    await render(snapshot());
    await type("/");
    expect(menu()?.textContent).toBe("No commands");
    await render(snapshot(commands));
    await type("/zzz");
    expect(menu()?.textContent).toBe("No matching commands");
    // Nothing to pick: Enter sends what was typed, as it would a pasted path.
    await key("Enter");
    expect(sent).toEqual(["/zzz"]);
    expect(textarea().value).toBe("");
  });

  test("Enter on a command typed in full sends it unless it takes arguments", async () => {
    await render(snapshot(commands));
    await type("/compact");
    await settle();
    await key("Enter");
    expect(sent).toEqual(["/compact"]);
    await type("/review");
    await settle();
    await key("Enter");
    expect(sent).toEqual(["/compact"]);
    expect(textarea().value).toBe("/review ");
  });

  test("submitting sends the trimmed prompt and clears the box", async () => {
    await render(snapshot(commands));
    await type("  /review main  ");
    await act(async () => { dom.window.document.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })); });
    expect(sent).toEqual(["/review main"]);
    expect(textarea().value).toBe("");
  });
});
