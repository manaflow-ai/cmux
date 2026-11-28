import { expect, test } from "bun:test";
import { classifyNewTabInput } from "../newTabIntent";
import { EMPTY_OMNIBAR } from "../omnibar";
import { slashNames, usesCommand } from "../slashCommands";
import { commandRows, isAddress, screenRows } from "./screenModel";

// A picked skill (`/emil-ask-emil`) offered `file:///emil-ask-emil` on top, and Return opened that
// file tab (Lucas 2026-11-26). A draft that uses a skill or command offers only its Ask rows.
const names = slashNames([
  { name: "emil-ask-emil", description: "", source: "skill" },
  { name: "$emil-color", description: "", source: "skill" },
  { name: "cmux:cmux-chat", description: "", source: "skill" },
  { name: "model", description: "", source: "cmux" },
]);

test.each([
  "/emil-ask-emil",
  "/emil-ask-emil ",
  "/emil-ask-emil\nnow",
  "/emil-color",
  "/$emil-color",
  "/cmux:cmux-chat",
  "/model",
])("%p is the agent's command, not a file at the disk's root", (text) => {
  expect(classifyNewTabInput(text, { home: "/Users/me", commands: names.leading }).kind).toBe("prompt");
  expect(isAddress(text, "/Users/me", names.leading)).toBe(false);
});

test.each(["/tmp", "/Users/me/notes.md", "/emil-ask-emil/notes.md", "~/emil-ask-emil"])(
  "%p stays a file with the agent's commands known",
  (text) => {
    expect(isAddress(text, "/Users/me", names.leading)).toBe(true);
  },
);

// A URL or path pasted with its wrap breaks stays an address, a line of it named like a skill too: the
// field offers Open for it (NewTabScreen ``usingCommand``).
test.each(["https://example.com/path\n/emil-color/docs", "/Users/me\n/emil-color/docs"])(
  "%p stays an address",
  (text) => {
    expect(isAddress(text, "/Users/me", names.leading)).toBe(true);
  },
);

test("with no command list a bare `/name` is still a file (the Swift table's rule)", () => {
  expect(isAddress("/emil-ask-emil", "/Users/me")).toBe(true);
});

test.each([
  ["/emil-ask-emil", true],
  ["/emil-ask-emil fix the header", true],
  ["use /emil-ask-emil now", true],
  ["use /emil-color now", true],
  ["/model opus", true],
  // A command that is no skill counts only as the first word, as the field draws it.
  ["set /model opus", false],
  // Code is never read.
  ["`/emil-ask-emil`", false],
  ["/tmp", false],
  ["fix the build", false],
] as const)("%p uses a command: %p", (text, uses) => {
  expect(usesCommand(text, names)).toBe(uses);
});

test("no command list uses no command", () => {
  expect(usesCommand("/emil-ask-emil", slashNames([]))).toBe(false);
});

test("a draft that uses a skill keeps only its Ask rows", () => {
  const rows = screenRows("/emil-ask-emil fix the header", {
    omnibar: { ...EMPTY_OMNIBAR, workspaces: [{ id: "ws", name: "emil" }] },
    create: ["terminal", "browser", "chat"],
    ask: { harness: "claude", agent: "Claude Code" },
    home: "/Users/me",
  });
  expect(rows.some((row) => row.type !== "ask")).toBe(true);
  const kept = commandRows(rows);
  expect(kept.map((row) => row.type)).toEqual(["ask"]);
});

test("`/resume <ref>` keeps its Resume row", () => {
  const rows = screenRows("/resume 3224ed6e", {
    omnibar: EMPTY_OMNIBAR,
    ask: { harness: "claude", agent: "Claude Code" },
  });
  expect(commandRows(rows)).toEqual([{ type: "resume", ref: "3224ed6e" }]);
});
