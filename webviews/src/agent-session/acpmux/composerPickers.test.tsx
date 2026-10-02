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
const { ComposerPickers, unrestricted } = await import("./ComposerPickers");

const doc = dom.window.document;
const snapshot = (summary: Partial<NonNullable<AcpmuxSnapshot["summary"]>> = {}, isWorking = false): AcpmuxSnapshot => ({
  type: "snapshot", protocolVersion: 1, rows: [], sessions: [], connection: "connected", isWorking, queue: [], canLoadOlder: false,
  catalog: [{ id: "codex", name: "Codex", models: [{ id: "astra", name: "6 Astra" }, { id: "sol", name: "6.1 Sol" }] }],
  summary: { sessionId: "s", harness: "codex", model: "astra", ...summary },
});
const effort = { id: "reasoning_effort", category: "thought_level", currentValue: "high", options: [{ value: "medium", name: "Medium" }, { value: "high", name: "High" }] };
const modes = { currentModeId: "ask", availableModes: [{ id: "ask", name: "Ask for approval", description: "Always ask" }, { id: "bypassPermissions", name: "Full access", description: "Unrestricted" }] };

/// Types into the prompt through React's change handler (see composer.test.tsx for why).
function typeInto(node: HTMLTextAreaElement, value: string) {
  node.value = value;
  node.setSelectionRange(value.length, value.length);
  const props = (node as unknown as Record<string, { onChange(event: { target: HTMLTextAreaElement }): void }>)[Object.keys(node).find((key) => key.startsWith("__reactProps$"))!]!;
  props.onChange({ target: node });
}

describe("acpmux composer pickers", () => {
  let root: ReturnType<typeof createRoot>;
  let calls: string[];
  const render = async (value: AcpmuxSnapshot) => act(async () => root.render(createElement(ComposerPickers, {
    snapshot: value,
    onModel: (id: string) => { calls.push(`model ${id}`); },
    onMode: (id: string) => { calls.push(`mode ${id}`); },
    onEffort: (config: string, id: string) => { calls.push(`effort ${config} ${id}`); },
  })));
  const button = (label: string) => doc.querySelector<HTMLButtonElement>(`[aria-label="${label}"].acpmux-picker-button`);
  const options = () => [...doc.querySelectorAll("[role=option]")].map((option) => `${option.textContent}${option.getAttribute("aria-checked") === "true" ? " *" : ""}`);
  const key = async (target: Element, name: string) => act(async () => { target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true })); });

  beforeEach(() => { calls = []; root = createRoot(doc.getElementById("root")!); });
  afterEach(async () => { await act(async () => root.unmount()); });

  test("the model button names the model and effort, and its menu lists both with the current ones checked", async () => {
    await render(snapshot({ configOptions: [effort] }));
    expect(button("Model")!.textContent).toBe("6 AstraHigh");
    expect(button("Mode")).toBeNull();
    await act(async () => button("Model")!.click());
    expect([...doc.querySelectorAll(".acpmux-menu-header")].map((header) => header.textContent)).toEqual(["Model", "Effort"]);
    expect(options()).toEqual(["6 Astra *", "6.1 Sol", "Medium", "High *"]);
    await act(async () => { doc.querySelectorAll("[role=option]")[1]!.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true })); });
    expect(calls).toEqual(["model sol"]);
    expect(doc.querySelector("[role=listbox]")).toBeNull();
  });

  test("arrows and Enter pick from the menu, and Escape closes it back to the button", async () => {
    await render(snapshot({ configOptions: [effort] }));
    const model = button("Model")!;
    await key(model, "ArrowDown");
    expect(model.getAttribute("aria-expanded")).toBe("true");
    expect(doc.getElementById(model.getAttribute("aria-activedescendant")!)!.textContent).toBe("6 Astra");
    await key(model, "ArrowUp");
    expect(doc.getElementById(model.getAttribute("aria-activedescendant")!)!.textContent).toBe("High");
    await key(model, "ArrowUp");
    await key(model, "Enter");
    expect(calls).toEqual(["effort reasoning_effort medium"]);
    await key(model, "ArrowDown");
    await key(model, "Escape");
    expect(doc.querySelector("[role=listbox]")).toBeNull();
    expect(doc.activeElement).toBe(model);
    expect(calls).toEqual(["effort reasoning_effort medium"]);
  });

  test("Space picks on keyup without the button's click reopening the menu, and a shrunk list keeps a row highlighted", async () => {
    await render(snapshot({ configOptions: [effort] }));
    const model = button("Model")!;
    await key(model, "ArrowDown");
    await key(model, "ArrowUp");
    // A live update drops the effort options while the highlight sits on the last one.
    await render(snapshot());
    expect(doc.getElementById(model.getAttribute("aria-activedescendant")!)!.textContent).toBe("6.1 Sol");
    await key(model, " ");
    expect(model.getAttribute("aria-expanded")).toBe("true");
    const up = new dom.window.KeyboardEvent("keyup", { key: " ", bubbles: true, cancelable: true });
    await act(async () => { model.dispatchEvent(up); });
    expect(up.defaultPrevented).toBe(true);
    expect(calls).toEqual(["model sol"]);
    expect(model.getAttribute("aria-expanded")).toBe("false");
  });

  test("the menu closes when the window loses focus", async () => {
    await render(snapshot());
    await act(async () => button("Model")!.click());
    await act(async () => { dom.window.dispatchEvent(new dom.window.Event("blur")); });
    expect(doc.querySelector("[role=listbox]")).toBeNull();
  });

  test("each section is a labelled group", async () => {
    await render(snapshot({ configOptions: [effort] }));
    await act(async () => button("Model")!.click());
    const groups = [...doc.querySelectorAll("[role=listbox] > [role=group]")];
    expect(groups.map((group) => doc.getElementById(group.getAttribute("aria-labelledby")!)!.textContent)).toEqual(["Model", "Effort"]);
  });

  test("a click outside closes the menu without picking", async () => {
    await render(snapshot());
    await act(async () => button("Model")!.click());
    expect(doc.querySelector("[role=listbox]")).not.toBeNull();
    await act(async () => { doc.body.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true })); });
    expect(doc.querySelector("[role=listbox]")).toBeNull();
    expect(calls).toEqual([]);
  });

  test("the mode chip shows the current mode, with descriptions in its menu and the warning color for full access", async () => {
    await render(snapshot({ modes }));
    expect(button("Mode")!.textContent).toBe("Ask for approval");
    expect(doc.querySelector(".acpmux-mode.acpmux-unrestricted")).toBeNull();
    await act(async () => button("Mode")!.click());
    expect([...doc.querySelectorAll(".acpmux-menu-description")].map((node) => node.textContent)).toEqual(["Always ask", "Unrestricted"]);
    expect(doc.querySelector(".acpmux-menu-item.acpmux-unrestricted")!.textContent).toBe("Full accessUnrestricted");
    await render(snapshot({ modes: { ...modes, currentModeId: "bypassPermissions" } }));
    expect(doc.querySelector(".acpmux-mode.acpmux-unrestricted")).not.toBeNull();
    expect(unrestricted("default")).toBe(false);
  });
});

describe("acpmux composer send button", () => {
  let root: ReturnType<typeof createRoot>;
  let sent: string[];
  let stops: number;
  const textarea = () => doc.querySelector("textarea")!;
  const send = () => doc.querySelector(".acpmux-send")!;
  const render = async (value: AcpmuxSnapshot) => act(async () => root.render(createElement(Composer, { snapshot: value, chips: () => null, onSend: (text: string) => { sent.push(text); }, onStop: () => { stops += 1; } })));
  const key = async (name: string, init: KeyboardEventInit = {}) => act(async () => { textarea().dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true, ...init })); });

  beforeEach(() => { sent = []; stops = 0; root = createRoot(doc.getElementById("root")!); });
  afterEach(async () => { await act(async () => root.unmount()); });

  test("Enter sends the prompt, Shift+Enter and an input method's Enter do not", async () => {
    await render(snapshot());
    await act(async () => typeInto(textarea(), "hello"));
    await key("Enter", { shiftKey: true });
    await key("Enter", { isComposing: true });
    expect(sent).toEqual([]);
    await key("Enter");
    expect(sent).toEqual(["hello"]);
    expect(textarea().value).toBe("");
    await key("Enter");
    expect(sent).toEqual(["hello"]);
  });

  test("Send is ready only with a prompt, and becomes Stop while a turn runs with an empty prompt", async () => {
    await render(snapshot());
    expect(send().getAttribute("aria-label")).toBe("Send");
    expect(send().classList.contains("acpmux-send-ready")).toBe(false);
    await act(async () => typeInto(textarea(), "next"));
    expect(send().classList.contains("acpmux-send-ready")).toBe(true);
    await render(snapshot({}, true));
    // A prompt typed during a turn still sends (the agent queues it).
    expect(send().getAttribute("aria-label")).toBe("Send");
    await act(async () => typeInto(textarea(), ""));
    expect(send().getAttribute("aria-label")).toBe("Stop");
    await act(async () => (send() as HTMLButtonElement).click());
    expect(stops).toBe(1);
  });

  test("Stop ignores a click that lands right after a send, such as a double-click's second", async () => {
    await render(snapshot());
    await act(async () => typeInto(textarea(), "go"));
    await act(async () => { doc.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })); });
    await render(snapshot({}, true));
    expect(send().getAttribute("aria-label")).toBe("Stop");
    await act(async () => (send() as HTMLButtonElement).click());
    expect(sent).toEqual(["go"]);
    expect(stops).toBe(0);
  });
});
