// A chat switch reads the new chat's folder's `git.status` again (header/worktreePillModel.ts). The
// pill already shows the folder's last answer from the first render, so an answer that says the same
// renders nothing again: it used to render the header tools once more before the switch's first frame
// (bench/settled-page.bench.ts, chat_switch). An answer that names another branch still shows.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act, createElement, useState } = await import("react");
const { createRoot } = await import("react-dom/client");
const { useWorktree } = await import("../src/agent-session/acpmux/header/worktreePillModel");

const root = createRoot(dom.window.document.getElementById("root")!);
afterAll(async () => {
  act(() => root.unmount());
  await teardownDom(saved, { window: dom.window, scope });
});

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

test("a switch back to a chat whose folder answers the same renders once; a new branch shows", async () => {
  const branches = new Map<string, string>([["/repo-a", "one"], ["/repo-b", "two"]]);
  const readStatus = (cwd: string) =>
    Promise.resolve({ branch: branches.get(cwd), base: "main", worktree: { main_root: "/repo" } });
  const renders: { folder: string; branch: string | undefined }[] = [];
  let show: (folder: string) => void = () => undefined;
  // The header takes the chat's folder as a prop, as ChatHeaderTools does.
  function Header({ folder }: { folder: string }) {
    const worktree = useWorktree(folder, readStatus);
    renders.push({ folder, branch: worktree?.branch });
    return null;
  }
  function Pane() {
    const [folder, setFolder] = useState("/repo-a");
    show = setFolder;
    return createElement(Header, { folder });
  }
  await act(async () => root.render(createElement(Pane)));
  await settle();
  expect(renders.at(-1)).toEqual({ folder: "/repo-a", branch: "one" });
  await act(async () => show("/repo-b"));
  await settle();
  expect(renders.at(-1)).toEqual({ folder: "/repo-b", branch: "two" });

  const before = renders.length;
  await act(async () => show("/repo-a"));
  await settle();
  expect(renders.slice(before)).toEqual([{ folder: "/repo-a", branch: "one" }]);

  branches.set("/repo-b", "three");
  await act(async () => show("/repo-b"));
  await settle();
  expect(renders.at(-1)).toEqual({ folder: "/repo-b", branch: "three" });
});
