// Tool rows say what a call did (Leo 2026-10-13, transcript row design): a shell call reads as a
// human summary ("Fetched feat-cmux-next and diffed HEAD~1"), its command and short folder show once
// opened, an MCP call and an agent call get their own glyphs, and no row shows a raw tool id. Before,
// a command row read "Ran cd ~/wt/lanes/… && git fetch -q … | cut" and an agent call with no title
// was labeled with its id ("toolu_01Kjhq…").
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

const FETCH = "cd ~/wt/lanes/cg-next-reds && git fetch -q origin feat-cmux-next && git diff HEAD~1 --stat | cut -c1-80";

test("a shell call reads as what it did, and opens to its command in its folder", async () => {
  await render([
    {
      kind: "tool",
      text: "Run",
      tool: { id: "t1", title: "Run", kind: "execute", status: "completed", command: FETCH, output: " a | 2 +-\n" },
    },
  ]);
  const row = host.querySelector<HTMLButtonElement>(".cv-tool")!;
  expect(row.querySelector(".cv-tool__text")?.textContent).toBe("Fetched feat-cmux-next and diffed HEAD~1");
  expect(row.querySelector(".cv-tool__icon")?.getAttribute("data-kind")).toBe("shell");
  await act(async () => row.click());
  expect(host.querySelector(".cv-shell__folder")?.textContent).toBe("cg-next-reds");
  expect(host.querySelector(".cv-shell__command")?.textContent).toBe(
    "$ git fetch -q origin feat-cmux-next && git diff HEAD~1 --stat | cut -c1-80",
  );
});

test("an agent call is named by its task, never by its tool id", async () => {
  // Claude Code's Task call as mergeToolItem builds it from an update with no title.
  const { mergeToolItem } = await import("../src/agent-session/acpmux/direct");
  const item = mergeToolItem(
    undefined,
    {
      kind: "think",
      status: "in_progress",
      rawInput: { description: "Review the bonsplit pin", prompt: "…", subagent_type: "general-purpose" },
      _meta: { claude: { tool: "Task" } },
    },
    "toolu_01KjhqWnD9XcR3mT2",
    "",
    1,
  );
  await render([item]);
  expect(host.querySelector(".cv-tool__text")?.textContent).toBe("Review the bonsplit pin");
  expect(host.querySelector(".cv-tool__icon")?.getAttribute("data-kind")).toBe("agent");
  expect(host.textContent).not.toContain("toolu_");
});

test("an MCP call gets the MCP glyph and a readable name", async () => {
  await render([
    {
      kind: "tool",
      text: "mcp__github__get_issue",
      tool: { id: "t3", title: "mcp__github__get_issue", status: "completed", inputSummary: '{"issue":20194}' },
    },
  ]);
  expect(host.querySelector(".cv-tool__icon")?.getAttribute("data-kind")).toBe("mcp");
  expect(host.querySelector(".cv-tool__text")?.textContent).toBe("github: get issue");
});

test("consecutive shell calls stay one 'Ran 4 commands' row", async () => {
  const command = (id: string, line: string) => ({
    kind: "tool",
    text: "Run",
    tool: { id, title: "Run", kind: "execute", status: "completed", command: line },
  });
  await render([
    command("a", "git status"),
    command("b", "git log -1"),
    command("c", "ls src"),
    command("d", "bun test test/a.test.ts"),
  ]);
  const rows = host.querySelectorAll(".cv-tools > .cv-tool");
  expect(rows.length).toBe(1);
  expect(rows[0]!.querySelector(".cv-tool__text")?.textContent).toBe("Ran 4 commands");
});

test("a summary never claims what the command did not do", async () => {
  // Review of #20456: a pipe into xargs or sh, a redirect, a background `&` or an option's value
  // made the row read as something the command did not do. Such a command reads as itself.
  const { commandSummary } = await import("../src/agent-session/acpmux/conversation/commandSummary");
  const { translate } = await import("../src/agent-session/acpmux/i18n");
  const t = translate as never;
  for (const command of [
    "ls | xargs rm -rf",
    "grep -rl foo . | xargs sed -i s/foo/bar/",
    "cat install.sh | sh",
    "cat a.txt > b.txt",
    "ls > files.txt",
    "git diff > patch.diff && git status",
    "sleep 1 & rm -rf build; git status",
    "grep -A 3 TODO x.ts",
    "rg -t ts useState",
    "tail -n 50",
    // Review of the redesign: an escaped quote, a `||` whose right side may not run, a dry run,
    // and a reader told to write a file.
    'git status "\\"" ; rm -rf /',
    "git diff --quiet || git commit -am x",
    "git push --dry-run",
    "git push -n origin main",
    "git log | sort -o out.txt",
    "git log | uniq in.txt out.txt",
  ])
    expect([command, commandSummary(command, t)]).toEqual([command, undefined]);
  // Two different reads stay two; only a repeat of the same step folds.
  expect(commandSummary("cat a.ts && cat b.ts", t)).toBe("Read a.ts and read b.ts");
  expect(commandSummary("git status | head -20 && tail -n 5 log.txt", t)).toBe("Checked git status and read log.txt");
});

test("a cd that names no folder keeps its prefix on the command", async () => {
  // Review of the redesign: `cd .. && rm -rf build` showed only `rm -rf build`, with no folder chip.
  const { commandFolder } = await import("../src/agent-session/acpmux/conversation/commandSummary");
  for (const command of ["cd .. && rm -rf build", "cd ~ && ls", "cd - ; ls"])
    expect(commandFolder(command)).toEqual({ rest: command });
  expect(commandFolder("cd ~/wt/lanes/x && ls")).toEqual({ folder: "x", rest: "ls" });
});

test("a joined summary keeps a file name's case in every language", async () => {
  const { commandSummary } = await import("../src/agent-session/acpmux/conversation/commandSummary");
  const { translate, setPaneLanguage } = await import("../src/agent-session/acpmux/i18n");
  setPaneLanguage("de");
  try {
    expect(commandSummary("git status && cat Makefile", translate as never)).toContain("Makefile");
  } finally {
    setPaneLanguage("en");
  }
});

test("Find in Chat matches a row's words only where it counts them", async () => {
  // Find counts a thought's text and a shell call's command, so the words the row adds around
  // them ("Thought for 4s", "Fetched …") are skipped when it paints matches.
  const { appendThought } = await import("../src/agent-session/acpmux/direct");
  await render([
    ...appendThought([], "Thought about it", 1),
    {
      kind: "tool",
      text: "Run",
      tool: { id: "t9", title: "Run", kind: "execute", status: "completed", command: FETCH },
    },
  ]);
  expect(host.querySelector(".cv-thought__label")?.closest("[data-find-skip]")).not.toBeNull();
  expect(host.querySelector(".cv-tool__text")?.closest("[data-find-skip]")).not.toBeNull();
});

test("Find counts a command as its rows draw it, without the leading cd", async () => {
  // Review of the redesign: the Shell block and a group's command line drop `cd <folder> &&`, so a
  // match there would be counted but never drawn.
  const { findMatches } = await import("../src/agent-session/acpmux/conversation/chatFind");
  const row = {
    id: "activity-find",
    kind: "activity",
    version: 1,
    at: 1,
    items: [
      {
        kind: "tool",
        text: "Run",
        tool: { id: "t10", title: "Run", kind: "execute", status: "completed", command: "cd ~/wt/lanes/x && ls build" },
      },
    ],
  };
  expect(findMatches([row as never], "lanes")).toEqual([]);
  expect(findMatches([row as never], "build")).toHaveLength(1);
});
