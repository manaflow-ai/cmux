// l10n-allow-file: test fixture commands and output, not shipped UI.
// An opened command's Shell block draws the command in its code colors (shellHighlight.ts) over its
// output. The command is tokenized once per command string: output streaming under it, chunk by
// chunk, never re-renders or re-tokenizes it, nor a sibling step's command.
import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import * as highlight from "./shellHighlight";

const realTokens = highlight.shellTokens;
let calls = 0;
await mock.module("./shellHighlight", () => ({
  ...highlight,
  shellTokens: (command: string) => {
    calls += 1;
    return realTokens(command);
  },
}));
const { ShellBlock } = await import("./ShellBlock");

const { shellTokens, MAX_HIGHLIGHTED_COMMAND } = highlight;

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Node",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];

beforeEach(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "cmux-page://cmux.agent/" });
  // The sideways edge watch (sideways.ts) measures on the next frame.
  Object.assign(dom.window, {
    requestAnimationFrame: (run: FrameRequestCallback) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
  });
  for (const key of GLOBALS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Node: dom.window.Node,
    requestAnimationFrame: dom.window.requestAnimationFrame,
    cancelAnimationFrame: dom.window.cancelAnimationFrame,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  calls = 0;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const [key, value] of saved) scope[key] = value;
  dom?.window.close();
});

const roles = (command: string) =>
  shellTokens(command)
    .filter((token) => token.role)
    .map((token) => [token.role, token.text]);

test("a command's words take their roles, and every character stays in order", () => {
  const command = `cd ~/src && FOO=1 grep -nE "a|$HOME" src/*.ts 2>/dev/null | head -n 5 # first`;
  expect(roles(command)).toEqual([
    ["command", "cd"],
    ["operator", "&&"],
    ["variable", "FOO"],
    ["command", "grep"],
    ["flag", "-nE"],
    ["string", '"a|'],
    ["variable", "$HOME"],
    ["string", '"'],
    ["operator", "2>"],
    ["operator", "|"],
    ["command", "head"],
    ["flag", "-n"],
    ["number", "5"],
    ["comment", "# first"],
  ]);
  for (const text of [
    command,
    `for f in *.log; do wc -l "$f"; done`,
    `echo "$(git rev-parse --short HEAD)" > out.txt`,
    `cat <<'EOF' > notes.md\nline $one\n  two\nEOF\necho done`,
    `sudo -u root env X=1 make --jobs=8 'all'`,
    `echo "unterminated $(oops`,
    `x='a\\'b' \`date\` \${y:-z} $'tab\\t' $((1 + 2)) $ alone \\\n  next`,
  ])
    expect(
      shellTokens(text)
        .map((token) => token.text)
        .join(""),
    ).toBe(text);
  expect(roles(`for f in *.log; do wc -l "$f"; done`)).toEqual([
    ["keyword", "for"],
    ["operator", ";"],
    ["keyword", "do"],
    ["command", "wc"],
    ["flag", "-l"],
    ["string", '"'],
    ["variable", "$f"],
    ["string", '"'],
    ["operator", ";"],
    ["keyword", "done"],
  ]);
  expect(roles(`echo "$(git rev-parse HEAD)"`)).toEqual([
    ["command", "echo"],
    ["string", '"'],
    ["variable", "$("],
    ["command", "git"],
    ["variable", ")"],
    ["string", '"'],
  ]);
  expect(roles(`cat <<'EOF'\nbody $x\nEOF`)).toEqual([
    ["command", "cat"],
    ["operator", "<<'EOF'"],
    ["string", "body $x\n"],
    ["operator", "EOF"],
  ]);
  expect(roles("sudo make -j8")).toEqual([
    ["command", "sudo"],
    ["command", "make"],
    ["flag", "-j8"],
  ]);
});

test("random shell-ish text never throws and keeps every character", () => {
  const alphabet = ` \t\n\\'"\`$(){}|&;<>#=-0123abcXYZ_*?!@`;
  let seed = 7;
  const next = () => (seed = (seed * 1_103_515_245 + 12_345) % 2_147_483_648);
  for (let run = 0; run < 2_000; run++) {
    const text = Array.from({ length: next() % 60 }, () => alphabet[next() % alphabet.length]).join("");
    expect(
      shellTokens(text)
        .map((token) => token.text)
        .join(""),
    ).toBe(text);
  }
});

test("whitespace other than space, tab and newline never stalls the lexer", () => {
  // A CRLF command once looped forever: BREAK ends a word at "\r", but the lexer never stepped
  // over it, so opening the step hung the pane.
  for (const command of ["echo a\r\necho b", "a\rb", "x\fy", "ls\u00a0-la", "cat\vfile"]) {
    expect(
      shellTokens(command)
        .map((token) => token.text)
        .join(""),
    ).toBe(command);
  }
});

test("past its highlighted head, a long command draws plain", () => {
  const command = `echo ${"x".repeat(MAX_HIGHLIGHTED_COMMAND + 50)} "tail"`;
  const tokens = shellTokens(command);
  expect(tokens.map((token) => token.text).join("")).toBe(command);
  expect(tokens.at(-1)?.role).toBeUndefined();
  expect(tokens.at(-1)?.text.endsWith(`"tail"`)).toBe(true);
});

test("the command draws in its colors, one Find run, its prompt skipped", async () => {
  await act(async () =>
    root!.render(<ShellBlock command={`cd ~/wt/lane && rg -n "todo" src`} output={"src/a.ts:1:todo\n"} />),
  );
  const block = container.querySelector(".cv-shell__command")!;
  expect(block.textContent).toBe(`$ rg -n "todo" src`);
  expect(block.hasAttribute("data-find-join")).toBe(true);
  expect(block.querySelector(".cv-shell__prompt")?.hasAttribute("data-find-skip")).toBe(true);
  const command = block.querySelector('[data-role="command"]') as HTMLElement;
  expect(command.textContent).toBe("rg");
  expect(command.style.color).toContain("--agent-ansi-4");
  expect(container.querySelector('.cv-shell__command [data-role="string"]')?.textContent).toBe(`"todo"`);
  expect(container.querySelector(".cv-shell__output")?.textContent).toBe("src/a.ts:1:todo\n");
});

test("streaming output tokenizes the command once, and a sibling step's not at all", async () => {
  const lines = (n: number) => Array.from({ length: n }, (_, at) => `line ${at + 1}`).join("\n");
  const view = (n: number) => (
    <>
      <ShellBlock command={`bun test --watch | tee "$LOG"`} output={lines(n)} live />
      <ShellBlock command="git status --short" output={" M a.ts\n"} />
    </>
  );
  await act(async () => root!.render(view(1)));
  expect(calls).toBe(2);
  for (let n = 2; n <= 60; n++) await act(async () => root!.render(view(n)));
  expect(container.querySelector(".cv-shell__output")?.textContent).toBe(lines(60));
  expect(calls).toBe(2);
  // A new command is tokenized once.
  await act(async () =>
    root!.render(
      <>
        <ShellBlock command="bun test" output={lines(60)} />
        <ShellBlock command="git status --short" output={" M a.ts\n"} />
      </>,
    ),
  );
  expect(calls).toBe(3);
});

test("past eight lines the output is capped to scroll, with Show all to lift the cap", async () => {
  const output = Array.from({ length: 30 }, (_, at) => `case ${at + 1}`).join("\n");
  await act(async () => root!.render(<ShellBlock command="bun test" output={output} />));
  const body = container.querySelector(".cv-shell__body")!;
  expect(body.getAttribute("data-preview")).toBe("cut");
  // The count is the output's own lines; the command is its own block.
  const more = [...container.querySelectorAll("button")].find((button) => button.textContent === "Show all 30 lines");
  expect(Boolean(more)).toBe(true);
  // A command with no output yet draws no output box.
  await act(async () => root!.render(<ShellBlock command="sleep 5" live />));
  expect(container.querySelector(".cv-shell__body")?.textContent).toBe("");
});

test("while it runs, a reflow that grows the output keeps the newest line in view", async () => {
  const observers: { run: (entries: { target: Element }[]) => void; targets: Element[] }[] = [];
  Object.assign(dom!.window, {
    ResizeObserver: class {
      entry: { run: (entries: { target: Element }[]) => void; targets: Element[] };
      constructor(run: (entries: { target: Element }[]) => void) {
        this.entry = { run, targets: [] };
        observers.push(this.entry);
      }
      observe(target: Element) {
        this.entry.targets.push(target);
      }
      unobserve(target: Element) {
        this.entry.targets = this.entry.targets.filter((watched) => watched !== target);
      }
      disconnect() {
        this.entry.targets = [];
      }
    },
  });
  let height = 400;
  const output = Array.from({ length: 30 }, (_, at) => `case ${at + 1}`).join("\n");
  await act(async () => root!.render(<ShellBlock command="bun test" output={output} live />));
  const body = container.querySelector<HTMLElement>(".cv-shell__body")!;
  Object.defineProperty(body, "clientHeight", { configurable: true, get: () => 100 });
  Object.defineProperty(body, "scrollHeight", { configurable: true, get: () => height });
  let top = 300;
  Object.defineProperty(body, "scrollTop", {
    configurable: true,
    get: () => top,
    set: (value: number) => {
      top = value;
    },
  });
  // The mono font loads and the lines grow taller: no scroll event, only a resize of the output.
  height = 520;
  const lines = container.querySelector(".cv-shell__output")!;
  const watching = observers.filter((entry) => entry.targets.includes(lines));
  expect(watching.length).toBeGreaterThan(0);
  for (const entry of watching) entry.run([{ target: lines }]);
  expect(body.scrollTop).toBe(520);
});

test("one reflow watch per running block, on the output it shows, let go when the command ends", async () => {
  const observers: { targets: Element[] }[] = [];
  Object.assign(dom!.window, {
    ResizeObserver: class {
      entry = { targets: [] as Element[] };
      constructor() {
        observers.push(this.entry);
      }
      observe(target: Element) {
        if (!this.entry.targets.includes(target)) this.entry.targets.push(target);
      }
      unobserve(target: Element) {
        this.entry.targets = this.entry.targets.filter((watched) => watched !== target);
      }
      disconnect() {
        this.entry.targets = [];
      }
    },
  });
  const lines = (n: number) => Array.from({ length: n }, (_, at) => `case ${at + 1}`).join("\n");
  // Elements, compared by identity (a DOM node does not print).
  const watches = (entry: { targets: Element[] }, ...elements: Element[]) =>
    entry.targets.length === elements.length && entry.targets.every((target, at) => target === elements[at]);
  // The same output, first finished, then running: the one observer that start makes is the
  // follow watch (the sideways and fade watches observe the box too, and already did).
  await act(async () => root!.render(<ShellBlock command="bun test" output={lines(30)} />));
  const before = observers.length;
  await act(async () => root!.render(<ShellBlock command="bun test" output={lines(30)} live />));
  const follow = observers.slice(before);
  expect(follow.length).toBe(1);
  const body = container.querySelector(".cv-shell__body")!;
  const first = container.querySelector(".cv-shell__output")!;
  expect(watches(follow[0]!, body, first)).toBe(true);
  // Streaming keeps that one observer on the box and the output it shows.
  for (let n = 31; n <= 50; n++)
    await act(async () => root!.render(<ShellBlock command="bun test" output={lines(n)} live />));
  expect(watches(follow[0]!, body, first)).toBe(true);
  // The command ends: the follow watch lets go of the box and the output.
  await act(async () => root!.render(<ShellBlock command="bun test" output={lines(50)} />));
  expect(follow[0]!.targets.length).toBe(0);
});
