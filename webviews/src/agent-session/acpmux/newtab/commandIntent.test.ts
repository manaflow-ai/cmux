import { expect, test } from "bun:test";
import { EMPTY_OMNIBAR } from "../omnibar";
import { commandLikeness } from "./commandIntent";
import { screenRows } from "./screenModel";

// The New Tab field reads a shell command without `!` (Lucas 2026-11-17): Run leads for a
// command, comes second for a maybe, and many lines are a prompt with fewer rows.
const agents = [
  { id: "claude", name: "Claude" },
  { id: "codex", name: "Codex" },
];
const ask = { harness: "claude", agent: "Claude" };
const kinds = (text: string) =>
  screenRows(text, { omnibar: EMPTY_OMNIBAR, ask, agents, folders: ["/Users/me/fun/cmux"], home: "/Users/me" })
    .map((row) => row.type)
    .filter((type) => type !== "search")
    .slice(0, 3);

test.each([
  ["ls", "command"],
  ["cd ~/fun", "command"],
  ["git status", "command"],
  ["npm run dev", "command"],
  ["./scripts/build.sh --fast", "command"],
  ["sudo brew upgrade", "command"],
  ["FOO=1 bun test", "command"],
  // A program whose name is an English word, alone: Ask leads, Run is second (David Beyer 2026-11-20).
  ["make", "maybe"],
  ["test", "maybe"],
  ["history", "maybe"],
  ["date", "maybe"],
  ["clear", "maybe"],
  ["code", "maybe"],
  ["make test", "maybe"],
  ["git is broken", "maybe"],
  ["open .", "command"],
  ["find . -name '*.ts'", "command"],
  ["git commit -m 'fix the build'", "command"],
  ["open the settings", "prose"],
  ["mytool --verbose", "maybe"],
  ["claude", "agent"],
  ["claude --resume", "command"],
  ["make the sidebar wider", "prose"],
  ["fix the build", "prose"],
  ["how do i rebase", "prose"],
  ["which file handles tabs?", "prose"],
  ["codex cmux", "prose"],
  ["codex ~/fun/cmux", "prose"],
  ["just fix the build", "prose"],
  ["go to the settings", "prose"],
  ["code a login form", "prose"],
  ["make the /api route faster", "prose"],
  ["which file handles /api?", "prose"],
  ["fix `foo` in bar.ts", "prose"],
  ["ls\nls", "prose"],
] as const)("%p reads as %p", (text, likeness) => {
  expect(commandLikeness(text, { agents: ["claude", "codex"] })).toBe(likeness);
});

test("a command line the host lists as recent is a command", () => {
  expect(commandLikeness("deploy staging", { recent: ["deploy staging"] })).toBe("command");
});

test("a command leads with Run, Ask second", () => {
  expect(kinds("ls")).toEqual(["run", "ask"]);
  expect(kinds("git status")).toEqual(["run", "ask"]);
});

test("a maybe keeps Ask first and Run second", () => {
  expect(kinds("make test")).toEqual(["ask", "run"]);
});

test("a lone word that names a program and a prompt keeps Ask first, Run second", () => {
  // David Beyer 2026-11-20: a word typed into New Tab ran as a shell command on Return.
  expect(kinds("test")).toEqual(["ask", "run"]);
  expect(kinds("history")).toEqual(["ask", "run"]);
});

test("an agent's folder start keeps Return over Run", () => {
  expect(kinds("codex ~/fun/cmux")[0]).toBe("launch");
  expect(kinds("codex ~/fun/cmux")).not.toContain("run");
});

test("a workspace named exactly the text keeps Return over Run", () => {
  const omnibar = { ...EMPTY_OMNIBAR, workspaces: [{ id: "w1", name: "git status" }] };
  const rows = screenRows("git status", { omnibar, ask, agents }).map((row) => row.type);
  expect(rows.slice(0, 3)).toEqual(["workspace", "run", "ask"]);
});

test("words for the agent get no Run row", () => {
  expect(kinds("make the sidebar wider")).not.toContain("run");
  expect(kinds("how do i rebase")).not.toContain("run");
});

test("an agent's bare name lists its start first, then Run", () => {
  expect(kinds("codex")).toEqual(["launch", "run", "ask"]);
  // A name that completes a site (claude.ai) keeps no start on top (screenModel's `top` rule): Run leads.
  expect(kinds("claude")).toEqual(["run", "open", "ask"]);
});

test("many lines are a prompt: Ask alone", () => {
  expect(screenRows("git status\nand then fix it", { omnibar: EMPTY_OMNIBAR, ask, agents })).toEqual([
    { type: "ask", text: "git status\nand then fix it", ...ask },
  ]);
});
