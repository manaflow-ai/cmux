// Quote in Reply is a composer edit: it renders as a quiet blockquote, appends after an existing
// draft, keeps picked quotes ordered, and serializes back to Markdown for the agent.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { act, createRef } from "react";
import { JSDOM } from "jsdom";
import type { Root } from "react-dom/client";
import type { MarkdownFieldHandle } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "KeyboardEvent",
  "InputEvent",
  "FocusEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;
const handle = createRef<MarkdownFieldHandle>();

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    FocusEvent: window.FocusEvent,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  window.scrollBy = () => {};
  const box = () => new window.DOMRect(0, 0, 100, 20);
  Object.assign(window.Range.prototype, {
    getClientRects: () => Object.assign([box()], { item: () => box() }),
    getBoundingClientRect: box,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

async function render(markdown: string, onSubmit?: (value: string) => void) {
  const { createRoot } = await import("react-dom/client");
  const { MarkdownField } = await import("../src/agent-session/acpmux/MarkdownField");
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <MarkdownField ref={handle} value={markdown} onChange={() => {}} onSubmit={(value) => onSubmit?.(value)} />,
    ),
  );
  for (let turn = 0; turn < 200; turn++) {
    if (host.querySelector("[contenteditable]")) return;
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  }
  throw new Error("the composer editor never came up");
}

const content = () => host.querySelector<HTMLElement>("[contenteditable]")!;

test("Quote in Reply appends after the draft and leaves the caret in a plain paragraph", async () => {
  await render("Draft text");
  await act(async () => handle.current!.quoteReply("> Selected line\n\n"));
  expect([...content().children].map((node) => node.tagName)).toEqual(["P", "BLOCKQUOTE", "P"]);
  expect(content().querySelector("blockquote")?.textContent).toBe("Selected line");
  expect(content().textContent).not.toContain("> Selected line");
});

test("a quote-only saved value restores its separate typing paragraph", async () => {
  await render("");
  await act(async () => handle.current!.quoteReply("> Selected line"));
  const saved = handle.current!.value();
  act(() => root!.unmount());
  root = undefined;
  await render(saved);
  await act(async () => {
    handle.current!.setCaret(Number.MAX_SAFE_INTEGER);
    handle.current!.insertTyped("Reply outside");
  });
  expect(content().querySelector("blockquote")?.textContent).toBe("Selected line");
  expect(content().lastElementChild?.tagName).toBe("P");
  expect(content().lastElementChild?.textContent).toBe("Reply outside");
  expect(handle.current!.value()).toBe("> Selected line\n\nReply outside");
});

test("successive Quote in Reply inserts remain ordered after the draft", async () => {
  await render("Draft text");
  await act(async () => {
    handle.current!.quoteReply("> First\n\n");
    handle.current!.quoteReply("> Second\n\n");
  });
  expect([...content().querySelectorAll("blockquote")].map((node) => node.textContent)).toEqual(["First", "Second"]);
  expect(content().firstElementChild?.textContent).toBe("Draft text");
});

test("a focused selection never replaces the draft: the quote still appends at the bottom", async () => {
  await render("Keep this draft");
  await act(async () => {
    handle.current!.focus();
    handle.current!.setCaret(5);
    handle.current!.quoteReply("> Selected line");
  });
  expect([...content().children].map((node) => node.tagName)).toEqual(["P", "BLOCKQUOTE", "P"]);
  expect(content().firstElementChild?.textContent).toBe("Keep this draft");
  await act(async () => handle.current!.insertTyped("Reply "));
  expect(content().lastElementChild?.textContent).toBe("Reply ");
});

test("a second quote stays beside an earlier quote and reuses its reply paragraph", async () => {
  await render("Draft text\n\n> Earlier quote\n\n");
  await act(async () => handle.current!.quoteReply("> New quote"));
  expect(content().querySelector("blockquote blockquote")).toBeNull();
  expect([...content().querySelectorAll("blockquote")].map((node) => node.textContent)).toEqual([
    "Earlier quote",
    "New quote",
  ]);
  expect(content().lastElementChild?.tagName).toBe("P");
});

test("the composer sends the quote as Markdown even though the editor hides the marker", async () => {
  let sent = "";
  await render("Draft text", (value) => (sent = value));
  await act(async () => handle.current!.quoteReply("> Selected line\n\n"));
  expect(content().querySelector("blockquote")).not.toBeNull();
  await act(async () => {
    content().dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
  expect(sent).toContain("Draft text\n\n> Selected line");
  expect(handle.current!.agentText(handle.current!.value())).toContain("> Selected line");
});

test("definition-like text preserves surrounding quote blocks and serialized soft lines", async () => {
  await render("Draft text");
  const selected = [
    "> # Heading",
    ">",
    "> - one",
    "> - two",
    ">",
    "> ```js",
    "> const value = 1",
    "> ```",
    ">",
    "> [ref]: https://example.com",
    ">",
    "> After",
    "",
  ].join("\n");
  await act(async () => handle.current!.quoteReply(selected));
  const quote = content().querySelector("blockquote")!;
  expect([...quote.children].map((node) => node.tagName)).toEqual(["H1", "UL", "PRE", "P", "P"]);
  expect(quote.textContent).toContain("[ref]: https://example.com");
  const serialized = handle.current!.agentText(handle.current!.value());
  expect(serialized).toContain("> [ref]: https://example.com");
  expect(serialized).not.toContain("\\\n");
  expect(content().lastElementChild?.tagName).toBe("P");
});

test("a literal definition stays between the selected list and its surrounding paragraphs", async () => {
  await render("Draft text");
  await act(async () =>
    handle.current!.quoteReply("> Before\n> \n> - one\n> - two\n> \n> [ref]: https://example.com\n> \n> After\n\n"),
  );
  const quote = content().querySelector("blockquote")!;
  expect([...quote.children].map((node) => node.tagName)).toEqual(["P", "UL", "P", "P"]);
  expect([...quote.children].map((node) => node.textContent)).toEqual([
    "Before",
    "onetwo",
    "[ref]: https://example.com",
    "After",
  ]);
  const serialized = handle.current!.agentText(handle.current!.value());
  expect(serialized).toContain("> Before");
  expect(serialized).toContain("> - one\n> - two");
  expect(serialized).toContain("> [ref]: https://example.com");
  expect(serialized).toContain("> After");
  expect(serialized).not.toContain("\\\n");
  expect(content().lastElementChild?.tagName).toBe("P");
});

for (const selected of [
  "[ref]: https://example.com",
  "Before the example\n\n[ref]: https://example.com\n\nAfter the example",
  '[ref]:\n  https://example.com\n  "Reference title"',
])
  test("selected definition-like text remains visible and survives send: " + selected, async () => {
    await render("Draft text");
    // The transcript/native menu prefixes the visible selection's lines, including text that was
    // shown literally in an escaped paragraph or a code block.
    const markdown =
      selected
        .split("\n")
        .map((line) => "> " + line)
        .join("\n") + "\n\n";
    await act(async () => handle.current!.quoteReply(markdown));
    const quote = content().querySelector("blockquote")!;
    expect(quote.innerHTML).not.toBe("");
    const visibleLines = handle
      .current!.plainText()
      .split(/\n+/)
      .map((line) => line.trim())
      .filter(Boolean);
    expect(visibleLines).toEqual(["Draft text", ...selected.split(/\n+/).map((line) => line.trim())]);
    expect(content().firstElementChild?.textContent).toBe("Draft text");
    const sent = handle.current!.agentText(handle.current!.value());
    expect(sent).toContain("[ref]:");
    expect(sent).toContain("https://example.com");
    await act(async () => handle.current!.insertTyped("Reply"));
    expect(content().lastElementChild?.textContent).toBe("Reply");
  });

test("a quote picked while the composer is unmounted appends after the draft once it returns", async () => {
  // App's path: `chat.quoteReply` with no composer (a Sandboxed receipt in its place), then Back.
  const { quoteIntoComposer, replayHeldForComposer } = await import("../src/agent-session/acpmux/composerRestore");
  const composer = { current: null as { restore(): void; quoteReply(markdown: string): void } | null };
  const heldBack = { current: undefined };
  const heldQuotes = { current: undefined as string[] | undefined };
  quoteIntoComposer(composer, heldQuotes, "> First\n\n");
  quoteIntoComposer(composer, heldQuotes, "> Second\n\n");

  const { createRoot } = await import("react-dom/client");
  const { MarkdownField } = await import("../src/agent-session/acpmux/MarkdownField");
  const mount = async () => {
    root = createRoot(host);
    await act(async () =>
      root!.render(<MarkdownField ref={handle} value="Draft text" onChange={() => {}} onSubmit={() => {}} />),
    );
    composer.current = { restore() {}, quoteReply: (markdown) => handle.current!.quoteReply(markdown) };
    replayHeldForComposer(composer.current, heldBack, heldQuotes);
    for (let turn = 0; turn < 200 && !host.querySelector("blockquote, [contenteditable] p"); turn++)
      await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    for (let turn = 0; turn < 5; turn++) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  };
  await mount();
  expect(content().firstElementChild?.textContent).toBe("Draft text");
  expect([...content().querySelectorAll("blockquote")].map((node) => node.textContent)).toEqual(["First", "Second"]);
  expect(content().lastElementChild?.tagName).toBe("P");

  // A second remount (the receipt again, then Back) replays nothing.
  act(() => root!.unmount());
  root = undefined;
  host.replaceChildren();
  composer.current = null;
  await mount();
  expect(content().querySelectorAll("blockquote")).toHaveLength(0);
});
