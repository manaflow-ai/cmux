import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

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
  // The composer's prompt is a Milkdown (ProseMirror) editor.
  Node: dom.window.Node,
  getSelection: dom.window.getSelection.bind(dom.window),
  MutationObserver: dom.window.MutationObserver,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { Composer } = await import("./Composer");
const { FileSearch } = await import("./FileSearch");
const { matchRuns, readFileSearch } = await import("./fileSearchModel");
const { mockFileSearch } = await import("./mockFiles");
const { MockAcpmuxSocket } = await import("./mock");
const { promptField, typeInto: typePrompt } = await import("./promptFieldTesting");

const doc = dom.window.document;
let root: ReturnType<typeof createRoot>;
beforeEach(() => {
  root = createRoot(doc.getElementById("root")!);
});
afterEach(async () => act(async () => root.unmount()));

/// Types into a field as its own typing would, through React's onChange (see composer.test.tsx).
function typeInto(node: HTMLInputElement | HTMLTextAreaElement, value: string) {
  node.value = value;
  const props = (node as unknown as Record<string, { onChange(event: { target: typeof node }): void }>)[
    Object.keys(node).find((key) => key.startsWith("__reactProps$"))!
  ]!;
  props.onChange({ target: node });
}
const field = () => doc.querySelector<HTMLInputElement>(".acpmux-file-search input")!;
const results = () =>
  [...doc.querySelectorAll(".acpmux-file-result")].map(
    (row) => `${row.textContent}${row.getAttribute("aria-selected") === "true" ? " >" : ""}`,
  );
const note = () => doc.querySelector(".acpmux-file-note")?.textContent;
const key = (name: string) =>
  act(async () => {
    doc.activeElement!.dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }),
    );
  });
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 5)));

test("a reply reads as its root, its paths and their in-range match indexes; anything else is no reply", () => {
  expect(
    readFileSearch({
      root: "~/code/cmux",
      results: [{ path: "a/b.ts", matches: [2, 3, 99, -1, 1.5] }, { path: "" }, null, { path: "c.md" }],
      truncated: true,
    }),
  ).toEqual({ root: "~/code/cmux", results: [{ path: "a/b.ts", matches: [2, 3] }, { path: "c.md" }], truncated: true });
  expect(readFileSearch({ results: [] })).toBeUndefined();
  expect(readFileSearch(null)).toBeUndefined();
});

test("a path splits into its folder and its name, each in matched and unmatched runs", () => {
  expect(matchRuns("Sources/Fleet/retry.ts", [14, 15, 16])).toEqual({
    dir: [{ text: "Sources/Fleet", matched: false }],
    name: [
      { text: "ret", matched: true },
      { text: "ry.ts", matched: false },
    ],
  });
  expect(matchRuns("README.md").dir).toEqual([]);
});

test("the mock daemon ranks a match in a file's name above one spread through its folders", () => {
  const { root: folder, results: found } = mockFileSearch("~/code/cmux", "retry", 50);
  expect(folder).toBe("~/code/cmux");
  expect(found[0]).toEqual({ path: "Sources/Fleet/retry.ts", matches: [14, 15, 16, 17, 18] });
  expect(mockFileSearch("~/code/cmux", "upld", 50).results.map((match) => match.path)).toEqual([
    "Sources/Fleet/upload.ts",
    "Sources/Fleet/upload.test.ts",
  ]);
  expect(mockFileSearch("~/code/cmux", "", 50).results).toEqual([]);
  expect(mockFileSearch("~/code/cmux", "s", 2)).toMatchObject({ truncated: true });
  expect(mockFileSearch("~/code/cmux", "s", 2).results.length).toBe(2);
});

test("the palette asks as the query settles, bolds the matched characters, and Enter picks the highlight", async () => {
  const asked: string[] = [];
  const picked: string[] = [];
  let closed = 0;
  await act(async () =>
    root.render(
      createElement(FileSearch, {
        search: async (query: string) => {
          asked.push(query);
          return mockFileSearch("~/code/cmux", query, 50);
        },
        onPick: (path: string) => picked.push(path),
        onClose: () => closed++,
        debounceMs: 0,
      }),
    ),
  );
  expect(doc.activeElement).toBe(field());
  expect(note()).toBe("Type to search for files");
  await act(async () => typeInto(field(), "upld"));
  await settle();
  expect(asked).toEqual(["upld"]);
  expect(results()).toEqual(["upload.tsSources/Fleet >", "upload.test.tsSources/Fleet"]);
  expect([...doc.querySelectorAll(".acpmux-file-result")][0]!.querySelector("b")!.textContent).toBe("upl");
  expect(field().getAttribute("aria-activedescendant")).toBe(doc.querySelector(".acpmux-file-result")!.id);
  await key("ArrowDown");
  await key("Enter");
  expect(picked).toEqual(["Sources/Fleet/upload.test.ts"]);
  await act(async () => typeInto(field(), "zzz"));
  await settle();
  expect(note()).toBe("No matching files");
  await key("Escape");
  expect(closed).toBe(1);
});

test("only the newest query's answer lands, and a failed search says so", async () => {
  const pending: { query: string; resolve(value: unknown): void; reject(error: Error): void }[] = [];
  await act(async () =>
    root.render(
      createElement(FileSearch, {
        search: (query: string) =>
          new Promise((resolve, reject) => {
            pending.push({ query, resolve, reject });
          }),
        onPick: () => {},
        onClose: () => {},
        debounceMs: 0,
      }),
    ),
  );
  await act(async () => typeInto(field(), "re"));
  await settle();
  await act(async () => typeInto(field(), "retry"));
  await settle();
  expect(pending.map((entry) => entry.query)).toEqual(["re", "retry"]);
  expect(note()).toBe("Searching…");
  await act(async () => pending[1]!.resolve(mockFileSearch("~/code/cmux", "retry", 50)));
  // The slower, older answer arrives last and is dropped.
  await act(async () => pending[0]!.resolve(mockFileSearch("~/code/cmux", "re", 50)));
  expect(results()[0]).toBe("retry.tsSources/Fleet >");
  expect(results().length).toBe(1);
  await act(async () => typeInto(field(), "retr"));
  await settle();
  await act(async () => pending[2]!.reject(new Error("socket closed")));
  expect(note()).toBe("Couldn't search files");
  // The service's failure for a folder outside a repository says so.
  await act(async () => typeInto(field(), "ret"));
  await settle();
  await act(async () =>
    pending[3]!.reject(Object.assign(new Error("~/notes is not in a git repository"), { code: "validation.invalid" })),
  );
  expect(note()).toBe("This folder isn't in a git repository");
});

test("an input method's Enter and Escape stay with it; Enter mid-search picks the row on screen; Tab closes", async () => {
  const picked: string[] = [];
  let closed = 0;
  let hold: ((value: unknown) => void) | undefined;
  await act(async () =>
    root.render(
      createElement(FileSearch, {
        search: (query: string) =>
          query === "retry"
            ? Promise.resolve(mockFileSearch("~/code/cmux", query, 50))
            : new Promise((resolve) => {
                hold = resolve;
              }),
        onPick: (path: string) => picked.push(path),
        onClose: () => closed++,
        debounceMs: 0,
      }),
    ),
  );
  await act(async () => typeInto(field(), "retry"));
  await settle();
  const composing = (name: string) =>
    act(async () => {
      const event = new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true });
      Object.defineProperty(event, "isComposing", { value: true });
      field().dispatchEvent(event);
    });
  await composing("Enter");
  await composing("Escape");
  expect(picked).toEqual([]);
  expect(closed).toBe(0);
  // A newer query is out; the row on screen is still the one Enter picks.
  await act(async () => typeInto(field(), "retry."));
  await settle();
  expect(results()[0]).toBe("retry.tsSources/Fleet >");
  await key("Enter");
  expect(picked).toEqual(["Sources/Fleet/retry.ts"]);
  hold?.(mockFileSearch("~/code/cmux", "retry.", 50));
  // Tab closes without moving focus on: the palette hands it back to the prompt.
  const tab = new dom.window.KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true });
  await act(async () => {
    doc.activeElement!.dispatchEvent(tab);
  });
  expect(tab.defaultPrevented).toBe(true);
  expect(closed).toBe(1);
});

const snapshot = (): AcpmuxSnapshot => ({
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions: [],
  connection: "connected",
  isWorking: false,
  queue: [],
  catalog: [],
  canLoadOlder: false,
});

test("+ then Search files mentions the picked file at the caret, and Escape returns to the prompt", async () => {
  const render = (searchFiles?: (query: string) => Promise<unknown>) =>
    act(async () =>
      root.render(
        createElement(Composer, {
          snapshot: snapshot(),
          chips: () => null,
          onSend: () => {},
          onStop: () => {},
          searchFiles,
        }),
      ),
    );
  const plus = () => doc.querySelector<HTMLButtonElement>('[aria-label="Add"]')!;
  const items = () => [...doc.querySelectorAll("[role=option]")].map((option) => option.textContent);
  await render();
  await act(async () => plus().click());
  expect(items()).not.toContain("Search files");
  await act(async () => plus().click());
  await render(async (query) => mockFileSearch("~/code/cmux", query, 50));
  await settle();
  const prompt = promptField(doc);
  await act(async () => typePrompt(prompt, "Look at"));
  await act(async () => plus().click());
  expect(items()).toContain("Search files");
  await act(async () => {
    [...doc.querySelectorAll("[role=option]")]
      .find((option) => option.textContent === "Search files")!
      .dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
  });
  expect(doc.activeElement).toBe(field());
  await act(async () => typeInto(field(), "retry"));
  await act(async () => new Promise((resolve) => setTimeout(resolve, 120)));
  await key("Enter");
  expect(doc.querySelector(".acpmux-file-search")).toBeNull();
  expect(prompt.value).toBe("Look at @Sources/Fleet/retry.ts ");
  // Escape closes the palette and puts the caret back in the prompt.
  await act(async () => plus().click());
  await act(async () => {
    [...doc.querySelectorAll("[role=option]")]
      .find((option) => option.textContent === "Search files")!
      .dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
  });
  await key("Escape");
  expect(doc.querySelector(".acpmux-file-search")).toBeNull();
  expect(doc.activeElement).toBe(prompt.element);
  // Another chat's folder closes an open palette, so its rows can't be picked into this draft.
  await act(async () => plus().click());
  await act(async () => {
    [...doc.querySelectorAll("[role=option]")]
      .find((option) => option.textContent === "Search files")!
      .dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
  });
  expect(doc.querySelector(".acpmux-file-search")).not.toBeNull();
  await render(async (query) => mockFileSearch("~/code/acpmux", query, 50));
  expect(doc.querySelector(".acpmux-file-search")).toBeNull();
});

test("a picked path with a space is quoted, so the agent reads the whole mention", async () => {
  await act(async () =>
    root.render(
      createElement(Composer, {
        snapshot: snapshot(),
        chips: () => null,
        onSend: () => {},
        onStop: () => {},
        searchFiles: async () => ({ root: "~/notes", results: [{ path: "docs/My Notes.md" }] }),
      }),
    ),
  );
  await settle();
  await act(async () => doc.querySelector<HTMLButtonElement>('[aria-label="Add"]')!.click());
  await act(async () => {
    [...doc.querySelectorAll("[role=option]")]
      .find((option) => option.textContent === "Search files")!
      .dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
  });
  await act(async () => typeInto(field(), "notes"));
  await act(async () => new Promise((resolve) => setTimeout(resolve, 120)));
  await key("Enter");
  expect(promptField(doc).value).toBe('@"docs/My Notes.md" ');
});

test("the mock daemon answers file.search for a folder, empty for no query, and fails outside a repository", async () => {
  const socket = new MockAcpmuxSocket();
  const answer = (
    socket as unknown as { answer(method: string, params: Record<string, unknown>): Promise<unknown> }
  ).answer.bind(socket);
  expect(await answer("file.search", { path: "~/code/billing-service", query: "hook", limit: 10 })).toEqual({
    root: "~/code/billing-service",
    results: [{ path: "stripe/webhooks.go", matches: [10, 11, 12, 13] }],
    truncated: false,
  });
  expect(await answer("file.search", { path: "~/code/billing-service", query: "" })).toEqual({
    root: "~/code/billing-service",
    results: [],
  });
  const outside = await answer("file.search", { path: "~/Downloads", query: "x" }).catch((error: unknown) => error);
  expect(outside).toMatchObject({ code: "validation.invalid", message: "~/Downloads is not in a git repository" });
  socket.close();
});
