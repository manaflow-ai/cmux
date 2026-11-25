import { afterEach, expect, test } from "bun:test";
import { act, type ReactElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { headerBreadcrumb } from "./headerState";
import { ThreadTitle } from "./ThreadTitle";
import { settleReact } from "../../../../test/support/domTeardown";

// Header Path (agentPane.display.headerBreadcrumb, Taste Board #20): `repo / branch / title`, opt-in.

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of ["window", "document", "Node", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("the path names the repository a worktree belongs to, then the chat's branch", () => {
  expect(headerBreadcrumb({ cwd: "/Users/me/checkouts/cmux/lane--fix-login", branch: "lane/fix-login" })).toEqual([
    "cmux",
    "lane/fix-login",
  ]);
  // A branch read from the path stands in when the chat names none.
  expect(headerBreadcrumb({ cwd: "/Users/me/.cmux/worktrees/web/fix-nav" })).toEqual(["web", "fix-nav"]);
  // The worktree's path wins over the folder the chat was started in.
  expect(
    headerBreadcrumb({ cwd: "/Users/me/src/app", worktree: "/Users/me/src/app/.worktrees/picker", branch: "picker" }),
  ).toEqual(["app", "picker"]);
});

test("a plain folder is named by itself; no folder means no path", () => {
  expect(headerBreadcrumb({ cwd: "/Users/me/src/notes/", branch: "main" })).toEqual(["notes", "main"]);
  expect(headerBreadcrumb({ cwd: "/Users/me/src/notes" })).toEqual(["notes"]);
  expect(headerBreadcrumb({})).toEqual([]);
  expect(headerBreadcrumb({ cwd: "/", branch: "  " })).toEqual([]);
});

test("a chat's private folder is no path: the header draws the plain title (router-review F1 at 78eba1cf)", () => {
  const agentHome = "/Users/me/Library/Application Support/cmux/agent-home/ws-4f2a/chat-91";
  expect(headerBreadcrumb({ cwd: agentHome, branch: "main" })).toEqual([]);
  expect(headerBreadcrumb({ cwd: "/home/cmux/chats/c-3e9b1d", cloud: true })).toEqual([]);
  // Off a Cloud machine, `~/chats/api` is a project of the person's.
  expect(headerBreadcrumb({ cwd: "/home/me/chats/api" })).toEqual(["api"]);
});

test("off (no trail), the title draws exactly as before", async () => {
  // Rendered in a DOM, not to a string: the title reads an experiment switch (a store with no server snapshot).
  const container = installDom();
  root = createRoot(container);
  const markup = async (title: ReactElement): Promise<string> => {
    await act(async () => {
      root!.render(title);
    });
    return container.innerHTML;
  };
  const plain = await markup(<ThreadTitle title="A chat" />);
  expect(await markup(<ThreadTitle title="A chat" trail={[]} />)).toBe(plain);
  expect(await markup(<ThreadTitle title="A chat" trail={undefined} />)).toBe(plain);
  expect(plain).toBe('<span class="acpmux-thread-title">A chat</span>');
});

test("on, the header reads as one slash path and the title segment still renames", async () => {
  const container = installDom();
  root = createRoot(container);
  let renamed = 0;
  await act(async () => {
    root!.render(<ThreadTitle title="Fix login" trail={["cmux", "lane/fix-login"]} onRename={() => renamed++} />);
  });
  const path = container.querySelector<HTMLElement>(".acpmux-thread-crumbs")!;
  expect(path.textContent).toBe("cmux / lane/fix-login / Fix login");
  // No tooltip: the path's text shows (the tooltip cuts).
  expect(path.hasAttribute("title")).toBe(false);
  expect([...container.querySelectorAll(".acpmux-thread-crumb")].map((part) => part.textContent)).toEqual([
    "cmux",
    "lane/fix-login",
  ]);
  expect(container.querySelectorAll(".acpmux-thread-crumb-sep[aria-hidden='true']").length).toBe(2);
  const title = container.querySelector<HTMLElement>(".acpmux-thread-title")!;
  expect(title.textContent).toBe("Fix login");
  expect(title.hasAttribute("title")).toBe(false);
  // A double-click on a leading part does not rename; one on the title does.
  await act(async () => {
    container
      .querySelector(".acpmux-thread-crumb")!
      .dispatchEvent(new dom!.window.MouseEvent("dblclick", { bubbles: true }));
  });
  expect(renamed).toBe(0);
  await act(async () => {
    title.dispatchEvent(new dom!.window.MouseEvent("dblclick", { bubbles: true }));
  });
  expect(renamed).toBe(1);
});
