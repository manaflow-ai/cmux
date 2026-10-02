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
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { ComposerContext } = await import("./ComposerContext");

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;
const doc = dom.window.document;
// Newest first by updatedAt: cmux, then a cloud-only folder, then notes.
const sessions: AcpmuxSnapshot["sessions"] = [
  { sessionId: "a", cwd: "/Users/me/code/notes", updatedAt: 1 },
  { sessionId: "b", cwd: "/Users/me/code/cmux/", updatedAt: 3 },
  { sessionId: "c", cwd: "/workspace", host: "devbox", hostKind: "cloud", updatedAt: 2 },
  { sessionId: "d", cwd: "/Users/me/code/cmux", updatedAt: 2 },
];

let root: ReturnType<typeof createRoot>;
let picked: string[];
beforeEach(() => {
  root = createRoot(doc.getElementById("root")!);
  picked = [];
});
afterEach(async () => act(async () => root.unmount()));

const render = (summary: Partial<Summary> | undefined, list = sessions, choose = true) =>
  act(async () =>
    root.render(
      createElement(ComposerContext, {
        summary: summary && { sessionId: "s", ...summary },
        sessions: list,
        onProject: choose ? (cwd: string) => picked.push(cwd) : undefined,
      }),
    ),
  );
const pill = () => doc.querySelector<HTMLButtonElement>(".acpmux-project-button");
const search = () => doc.querySelector<HTMLInputElement>(".acpmux-project-search input");
const options = () =>
  [...doc.querySelectorAll("[role=option]")].map(
    (option) =>
      `${option.textContent}${option.getAttribute("aria-checked") === "true" ? " *" : ""}${option.getAttribute("aria-selected") === "true" ? " >" : ""}`,
  );
const key = (name: string) =>
  act(async () => {
    doc.activeElement!.dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }),
    );
  });
// As the field's own typing would: the value, then React's onChange (see composerPickers.test.tsx typeInto).
const type = (value: string) =>
  act(async () => {
    const node = search()!;
    node.value = value;
    const props = (node as unknown as Record<string, { onChange(event: { target: HTMLInputElement }): void }>)[
      Object.keys(node).find((name) => name.startsWith("__reactProps$"))!
    ]!;
    props.onChange({ target: node });
  });

test("the project pill lists this machine's projects newest first, with the current one checked and highlighted", async () => {
  await render({ cwd: "/Users/me/code/cmux" });
  expect(pill()!.textContent).toBe("cmux");
  expect(pill()!.getAttribute("aria-expanded")).toBe("false");
  await act(async () => pill()!.click());
  expect(pill()!.getAttribute("aria-expanded")).toBe("true");
  expect(doc.activeElement).toBe(search());
  // The cloud machine's /workspace is not a folder a local chat can open in.
  expect(options()).toEqual(["cmux * >", "notes"]);
  expect(search()!.getAttribute("aria-activedescendant")).toBe(doc.querySelector("[role=option]")!.id);
});

test("typing filters by name or path, Enter starts a chat in the highlighted project, and the current one starts nothing", async () => {
  await render({ cwd: "/Users/me/code/cmux" });
  await act(async () => pill()!.click());
  await type("note");
  expect(options()).toEqual(["notes >"]);
  await type("code");
  expect(options()).toEqual(["cmux * >", "notes"]);
  await type("zzz");
  expect(options()).toEqual([]);
  expect(doc.querySelector(".acpmux-project-empty")!.textContent).toBe("No matching projects");
  await type("");
  await key("ArrowDown");
  await key("Enter");
  expect(picked).toEqual(["/Users/me/code/notes"]);
  expect(doc.querySelector("[role=listbox]")).toBeNull();
  // The new chat's prompt takes the focus (Composer), so the pill does not hold it.
  expect(doc.activeElement).not.toBe(pill());
  // The project the chat is already in is not a new chat, and returns to the pill.
  await act(async () => pill()!.click());
  await key("Enter");
  expect(picked).toEqual(["/Users/me/code/notes"]);
  expect(doc.activeElement).toBe(pill());
});

test("the highlight stays on its project when a busy chat moves another folder to the top", async () => {
  await render({ cwd: "/Users/me/code/cmux" });
  await act(async () => pill()!.click());
  await key("ArrowDown");
  expect(options()).toEqual(["cmux *", "notes >"]);
  await render({ cwd: "/Users/me/code/cmux" }, [
    ...sessions,
    { sessionId: "e", cwd: "/Users/me/code/zed", updatedAt: 9 },
  ]);
  expect(options()).toEqual(["zed", "cmux *", "notes >"]);
  await key("Enter");
  expect(picked).toEqual(["/Users/me/code/notes"]);
});

test("from a cloud chat, the local project at the same path is another place to start a chat", async () => {
  await render({ cwd: "/Users/me/code/cmux", host: "devbox", hostKind: "cloud" });
  expect(pill()!.textContent).toBe("cmux");
  await act(async () => pill()!.click());
  expect(options()).toEqual(["cmux >", "notes"]);
  await key("Enter");
  expect(picked).toEqual(["/Users/me/code/cmux"]);
});

test("a click picks, and Escape or a click outside closes the menu", async () => {
  await render({ cwd: "/Users/me/code/cmux" });
  // The pill's mousedown keeps focus in the field, so a second click closes rather than reopens.
  await act(async () => pill()!.click());
  const down = new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true });
  await act(async () => {
    pill()!.dispatchEvent(down);
  });
  expect(down.defaultPrevented).toBe(true);
  await act(async () => pill()!.click());
  expect(doc.querySelector("[role=listbox]")).toBeNull();
  await act(async () => pill()!.click());
  await key("Escape");
  expect(doc.querySelector("[role=listbox]")).toBeNull();
  expect(doc.activeElement).toBe(pill());
  await act(async () => pill()!.click());
  await act(async () => {
    doc.body.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true }));
  });
  expect(doc.querySelector("[role=listbox]")).toBeNull();
  await act(async () => pill()!.click());
  await act(async () => {
    doc
      .querySelectorAll("[role=option]")[1]!
      .dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
  });
  expect(picked).toEqual(["/Users/me/code/notes"]);
});

test("a chat with no folder yet offers Choose project; without chats or a chooser the pill is plain", async () => {
  await render(undefined);
  expect(pill()!.textContent).toBe("Choose project");
  await render({ cwd: "/Users/me/code/cmux" }, []);
  expect(pill()).toBeNull();
  expect(doc.querySelector(".acpmux-context-chip")!.textContent).toBe("cmux");
  await render({ cwd: "/Users/me/code/cmux" }, sessions, false);
  expect(pill()).toBeNull();
  await render(undefined, []);
  expect(doc.querySelector(".acpmux-composer-context")).toBeNull();
});
