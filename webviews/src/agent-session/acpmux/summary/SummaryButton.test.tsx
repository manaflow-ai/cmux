import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxActivity, AcpmuxRow } from "../model";

const dom = new JSDOM("<!doctype html><div id=outside></div><div id=root></div>", {
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
const { SummaryButton } = await import("./SummaryButton");

const tool = (fields: Partial<NonNullable<AcpmuxActivity["tool"]>>): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: { id: fields.title ?? "t", title: "", status: "completed", ...fields },
});
const rows: AcpmuxRow[] = [
  { id: "user-1", version: 1, at: 1, kind: "user", text: "go" },
  {
    id: "activity-2",
    version: 1,
    at: 2,
    kind: "activity",
    items: [
      tool({
        id: "pr",
        kind: "execute",
        title: "gh pr create",
        command: 'gh pr create --title "Fix scroll"',
        output: "https://github.com/a/b/pull/9",
        exitCode: 0,
      }),
      tool({ id: "edit", kind: "edit", title: "Write", diffs: [{ path: "/repo/notes.md", newText: "hi\n" }] }),
      tool({ id: "agent", kind: "think", title: "Search the repo" }),
    ],
  },
];

async function render(opened: string[], shown: readonly AcpmuxRow[] = rows) {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const draw = (next: readonly AcpmuxRow[]) =>
    act(async () =>
      root.render(createElement(SummaryButton, { rows: next, onOpenOutput: (path) => opened.push(path) })),
    );
  await draw(shown);
  const button = container.querySelector<HTMLButtonElement>(".acpmux-summary-button")!;
  const popover = () => container.querySelector<HTMLDialogElement>(".acpmux-summary-popover");
  return { container, button, popover, draw, unmount: () => act(async () => root.unmount()) };
}
const titles = (popover: HTMLElement) =>
  [...popover.querySelectorAll(".acpmux-summary-title")].map((node) => node.textContent);

const key = (name: string) =>
  act(async () => {
    dom.window.document.activeElement!.dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true }),
    );
  });

test("the button opens the summary, focuses its first link, and Escape returns focus to the button", async () => {
  const { button, popover, unmount } = await render([]);
  expect(button.getAttribute("aria-expanded")).toBe("false");
  expect(popover()).toBeNull();
  await act(async () => button.click());
  expect(button.getAttribute("aria-expanded")).toBe("true");
  // The Codex app's three sections first, always; pull requests and wakeups after, when there are any.
  expect(titles(popover()!)).toEqual(["Outputs", "Subagents", "Sources", "Pull requests"]);
  const link = popover()!.querySelector<HTMLAnchorElement>("a.acpmux-summary-link")!;
  expect(link.href).toBe("https://github.com/a/b/pull/9");
  expect(link.textContent).toContain("Fix scroll");
  expect(dom.window.document.activeElement).toBe(popover()!.querySelector("button.acpmux-summary-link"));
  await key("Escape");
  expect(popover()).toBeNull();
  expect(dom.window.document.activeElement).toBe(button);
  await unmount();
});

test("an output opens the changes view at that file and closes the popover", async () => {
  const opened: string[] = [];
  const { button, popover, unmount } = await render(opened);
  await act(async () => button.click());
  await act(async () => popover()!.querySelector<HTMLButtonElement>("button.acpmux-summary-link")!.click());
  expect(opened).toEqual(["/repo/notes.md"]);
  expect(popover()).toBeNull();
  await unmount();
});

test("a press outside closes it, and a second press on the button toggles it shut", async () => {
  const { button, popover, unmount } = await render([]);
  await act(async () => button.click());
  await act(async () => {
    dom.window.document
      .getElementById("outside")!
      .dispatchEvent(new dom.window.Event("pointerdown", { bubbles: true }));
  });
  expect(popover()).toBeNull();
  await act(async () => button.click());
  await act(async () => button.click());
  expect(popover()).toBeNull();
  await unmount();
});

test("following a pull request link closes the summary", async () => {
  const { button, popover, unmount } = await render([]);
  await act(async () => button.click());
  const link = popover()!.querySelector<HTMLAnchorElement>("a.acpmux-summary-link")!;
  link.addEventListener("click", (event) => event.preventDefault());
  await act(async () => link.click());
  expect(popover()).toBeNull();
  await unmount();
});

test("an empty chat shows the three sections with None, not a sentence", async () => {
  const { button, popover, unmount } = await render([], rows.slice(0, 1));
  await act(async () => button.click());
  expect(titles(popover()!)).toEqual(["Outputs", "Subagents", "Sources"]);
  expect([...popover()!.querySelectorAll(".acpmux-summary-none")].map((node) => node.textContent)).toEqual([
    "None",
    "None",
    "None",
  ]);
  expect(popover()!.querySelector(".acpmux-summary-empty")).toBeNull();
  await unmount();
});

test("sections keep their place while the turn adds to them", async () => {
  const { button, popover, draw, unmount } = await render([], rows.slice(0, 1));
  await act(async () => button.click());
  const before = titles(popover()!);
  const activity = rows[1] as AcpmuxRow & { items: AcpmuxActivity[] };
  await draw([rows[0]!, { ...activity, items: activity.items.slice(1) }]);
  expect(titles(popover()!)).toEqual(before);
  expect(popover()!.querySelectorAll(".acpmux-summary-none")).toHaveLength(1);
  await unmount();
});

test("automation opens the summary by its label", async () => {
  const { openPicker } = await import("../pickerOpeners");
  const { popover, unmount } = await render([]);
  await act(async () => {
    expect(openPicker("Chat summary")).toBe(true);
  });
  expect(popover()).not.toBeNull();
  await unmount();
  expect(openPicker("Chat summary")).toBe(false);
});
