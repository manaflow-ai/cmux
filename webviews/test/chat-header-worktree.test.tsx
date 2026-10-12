// A chat in a worktree (cx-lyqio.3b, Codex/Conductor style) shows its branch in the header: the
// header reads `git.status` for the chat's folder, and a linked worktree's status names the main
// checkout it belongs to and the base it started from. A plain checkout, a status that fails, or a
// reply for a folder the chat has left shows nothing.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let host: HTMLElement;
let root: Root | undefined;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const WORKTREE = "/Users/me/.cmux/worktrees/app/fix-login";
const worktreeStatus = {
  root: WORKTREE,
  branch: "cmux/fix-login",
  base: "main",
  detached: false,
  worktree: { main_root: "/Users/me/app" },
};
const plainStatus = { root: "/Users/me/app", branch: "main", base: "origin/main", detached: false };

const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
const pill = () => host.querySelector<HTMLElement>(".acpmux-header-worktree");

async function render(props: Record<string, unknown>): Promise<(next: Record<string, unknown>) => Promise<void>> {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  root ??= createRoot(host);
  const draw = async (next: Record<string, unknown>) => {
    await act(async () =>
      root!.render(
        <ChatHeaderTools onTerminal={() => {}} onBrowser={() => {}} summary={null} menu={() => []} {...next} />,
      ),
    );
    await settle();
  };
  await draw(props);
  return draw;
}

test("a worktree chat's header names its branch, the checkout it belongs to and its base", async () => {
  const asked: string[] = [];
  const draw = await render({
    folder: WORKTREE,
    readStatus: async () => {
      asked.push("git.status");
      return worktreeStatus;
    },
  });
  expect(asked).toEqual(["git.status"]);
  expect(pill()?.textContent).toBe("cmux/fix-login");
  expect(pill()?.getAttribute("title")).toBe("Worktree of /Users/me/app, branched from main");
  // Another chat in a plain checkout drops it.
  await draw({ folder: "/Users/me/app", readStatus: async () => plainStatus });
  expect(pill()).toBeNull();
  await draw({});
});

test("a plain checkout, a failed status or no folder shows no worktree", async () => {
  const draw = await render({ folder: "/Users/me/app", readStatus: async () => plainStatus });
  expect(pill()).toBeNull();
  await draw({
    folder: WORKTREE,
    readStatus: async () => {
      throw new Error("not a repository");
    },
  });
  expect(pill()).toBeNull();
  await draw({ readStatus: async () => worktreeStatus });
  expect(pill()).toBeNull();
  await draw({});
});

test("a reply for a folder the chat has left does not show", async () => {
  let release: (value: unknown) => void = () => {};
  const slow = new Promise((resolve) => (release = resolve));
  const draw = await render({ folder: WORKTREE, readStatus: () => slow });
  await draw({ folder: "/Users/me/app", readStatus: async () => plainStatus });
  await act(async () => release(worktreeStatus));
  await settle();
  expect(pill()).toBeNull();
  await draw({});
});
