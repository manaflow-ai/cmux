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
type ComposerAttachment = import("./attachments").ComposerAttachment;

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
  let sentAttachments: ComposerAttachment[][];
  const textarea = () => dom.window.document.querySelector("textarea")!;
  const rows = () => [...dom.window.document.querySelectorAll(".acpmux-slash-row")].map((row) => row.querySelector(".acpmux-slash-name")!.textContent);
  const active = () => dom.window.document.querySelector(".acpmux-slash-active .acpmux-slash-name")?.textContent;
  const menu = () => dom.window.document.querySelector(".acpmux-slash-menu");
  const type = async (value: string) => act(async () => typeInto(textarea(), value));
  /// jsdom fires `select` a task after the caret moves; let it land inside act.
  const settle = async () => act(() => new Promise((resolve) => setTimeout(resolve, 0)));
  const key = async (name: string, isComposing = false) => act(async () => { textarea().dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, isComposing, bubbles: true, cancelable: true })); });
  const render = async (value: AcpmuxSnapshot) => act(async () => root.render(createElement(Composer, { snapshot: value, chips: () => null, onSend: (text: string, attachments: ComposerAttachment[]) => { sent.push(text); sentAttachments.push(attachments); }, onSteer: () => {}, onStop: () => {} })));

  beforeEach(() => { sent = []; sentAttachments = []; root = createRoot(dom.window.document.getElementById("root")!); });
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
    await key("Enter");
    expect(textarea().value).toBe("/zzz");
  });

  test("submitting sends the trimmed prompt and clears the box", async () => {
    await render(snapshot(commands));
    await type("  /review main  ");
    await act(async () => { dom.window.document.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })); });
    expect(sent).toEqual(["/review main"]);
    expect(textarea().value).toBe("");
  });
});

describe("acpmux composer attachments", () => {
  let root: ReturnType<typeof createRoot>;
  let sent: { text: string; attachments: ComposerAttachment[] }[];
  const document = dom.window.document;
  const chips = () => [...document.querySelectorAll(".acpmux-attachment")].map((chip) => chip.getAttribute("title"));
  const note = () => document.querySelector(".acpmux-attachment-note")?.textContent;
  /// File reads resolve on later tasks; let them land inside act.
  const settle = async () => act(() => new Promise((resolve) => setTimeout(resolve, 5)));
  /// jsdom has no DataTransfer, so an event carries a stand-in with the fields the composer reads.
  const transfer = (files: File[]) => ({ files, types: files.length ? ["Files"] : ["text/plain"] });
  const paste = async (files: File[]) => {
    const event = new dom.window.Event("paste", { bubbles: true, cancelable: true });
    Object.defineProperty(event, "clipboardData", { value: transfer(files) });
    await act(async () => { document.querySelector("textarea")!.dispatchEvent(event); });
    await settle();
    return event;
  };
  const drag = async (type: string, files: File[]) => {
    const event = new dom.window.Event(type, { bubbles: true, cancelable: true });
    Object.defineProperty(event, "dataTransfer", { value: transfer(files) });
    await act(async () => { document.body.dispatchEvent(event); });
    await settle();
    return event;
  };
  const render = async (image?: boolean) => act(async () => root.render(createElement(Composer, {
    snapshot: { ...snapshot(), summary: { sessionId: "s", promptCapabilities: image === undefined ? undefined : { image } } },
    chips: () => null,
    onSend: (text: string, attachments: ComposerAttachment[]) => { sent.push({ text, attachments }); },
    onSteer: () => {},
    onStop: () => {},
  })));
  const submit = async () => act(async () => { document.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })); });
  const png = () => new File([new Uint8Array([0x89, 0x50, 0x4e, 0x47])], "shot.png", { type: "image/png" });

  beforeEach(() => { sent = []; root = createRoot(document.getElementById("root")!); });
  afterEach(async () => { await act(async () => root.unmount()); });

  test("pasted files wait as chips, a chip can be removed, and send carries the rest", async () => {
    await render();
    const event = await paste([png(), new File(["hello\n"], "notes.md")]);
    expect(event.defaultPrevented).toBe(true);
    expect(chips()).toEqual(["shot.png", "notes.md"]);
    expect(document.querySelector<HTMLImageElement>(".acpmux-attachment-image img")!.src).toBe("data:image/png;base64,iVBORw==");
    await act(async () => { document.querySelector<HTMLButtonElement>('[aria-label="Remove notes.md"]')!.click(); });
    expect(chips()).toEqual(["shot.png"]);
    await submit();
    expect(sent.map((entry) => [entry.text, entry.attachments.map((attachment) => attachment.name)])).toEqual([["", ["shot.png"]]]);
    expect(chips()).toEqual([]);
  });

  test("pasting text alone is left to the textarea", async () => {
    await render();
    expect((await paste([])).defaultPrevented).toBe(false);
    expect(document.querySelector(".acpmux-attachments")).toBeNull();
  });

  test("a file dropped anywhere on the pane attaches instead of opening, with a hint while it hovers", async () => {
    await render();
    const over = await drag("dragover", [png()]);
    expect(over.defaultPrevented).toBe(true);
    expect(note()).toBe("Drop images or text files to attach");
    const drop = await drag("drop", [png()]);
    expect(drop.defaultPrevented).toBe(true);
    expect(chips()).toEqual(["shot.png"]);
    expect(note()).toBeUndefined();
    expect((await drag("dragover", [])).defaultPrevented).toBe(false);
  });

  test("refused files say why, and the note clears on send", async () => {
    await render(false);
    await paste([png()]);
    expect(note()).toBe("This agent does not take images");
    await paste([new File([new Uint8Array([0, 1])], "a.bin")]);
    expect(note()).toBe("a.bin is not an image or a text file");
    await act(async () => typeInto(document.querySelector("textarea")!, "hi"));
    await submit();
    expect(sent.map((entry) => entry.text)).toEqual(["hi"]);
    expect(document.querySelector(".acpmux-attachments")).toBeNull();
  });
});

describe("acpmux composer steering", () => {
  let root: ReturnType<typeof createRoot>;
  let calls: string[];
  const document = dom.window.document;
  const steer = () => document.querySelector<HTMLButtonElement>(".acpmux-steer");
  const render = async (isWorking: boolean) => act(async () => root.render(createElement(Composer, {
    snapshot: { ...snapshot(), isWorking },
    chips: () => null,
    onSend: (text: string) => { calls.push(`send ${text}`); },
    onSteer: (text: string) => { calls.push(`steer ${text}`); },
    onStop: () => {},
  })));

  beforeEach(() => { calls = []; root = createRoot(document.getElementById("root")!); });
  afterEach(async () => { await act(async () => root.unmount()); });

  test("Steer shows only while a turn runs, and only with something to send", async () => {
    await render(false);
    expect(steer()).toBeNull();
    await render(true);
    expect(steer()!.disabled).toBe(true);
    await act(async () => typeInto(document.querySelector("textarea")!, "use the other API"));
    expect(steer()!.disabled).toBe(false);
  });

  test("Steer hands the prompt to onSteer and clears the box, while Send still queues", async () => {
    await render(true);
    await act(async () => typeInto(document.querySelector("textarea")!, " stop and use v2 "));
    await act(async () => { steer()!.click(); });
    expect(calls).toEqual(["steer stop and use v2"]);
    expect(document.querySelector("textarea")!.value).toBe("");
    await act(async () => typeInto(document.querySelector("textarea")!, "then add tests"));
    await act(async () => { document.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })); });
    expect(calls).toEqual(["steer stop and use v2", "send then add tests"]);
  });
});
