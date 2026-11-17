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
  ["make", "command"],
  ["make test", "command"],
  ["open the settings", "maybe"],
  ["mytool --verbose", "maybe"],
  ["claude", "agent"],
  ["claude --resume", "command"],
  ["make the sidebar wider", "prose"],
  ["fix the build", "prose"],
  ["how do i rebase", "prose"],
  ["which file handles tabs?", "prose"],
  ["codex cmux", "prose"],
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
  expect(kinds("open the settings")).toEqual(["ask", "run"]);
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
