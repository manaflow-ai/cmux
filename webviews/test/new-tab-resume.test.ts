// Resuming a Claude Code session from New Tab "needs to just work" (user 2026-11-20, a screenshot
// of `/resume 3224ed6e-…` in the New Tab field: its top row offered `file:///resume%203224ed6e…`,
// so Return or a click opened a file tab instead of the chat). The field's text names a chat to
// resume when it is `/resume <ref>`, a pasted session id, or the harness's own resume command
// (`claude --resume <id>`, `claude -r <id>`, `codex resume <id>`): the Resume row leads, Return
// takes it, and no row turns the slash command into a file address.
import { expect, test } from "bun:test";
import { EMPTY_OMNIBAR } from "../src/agent-session/acpmux/omnibar";
import { defaultSelection, screenRows, type ScreenRow } from "../src/agent-session/acpmux/newtab/screenModel";
import { resumeReference } from "../src/agent-session/acpmux/resumeCommand";

const ID = "3224ed6e-c1e0-4741-bc35-60295c2878fb";
const ask = { harness: "claude", agent: "Claude Code", model: "Claude Opus 5.5" };
const rows = (text: string) => screenRows(text, { omnibar: EMPTY_OMNIBAR, ask, home: "/Users/me" });
const fileRows = (list: ScreenRow[]) => list.filter((row) => "url" in row && !!row.url?.startsWith("file:"));

test.each([
  [`/resume ${ID}`, ID],
  [`  /Resume   ${ID}  `, ID],
  ["/resume 3224ed6e", "3224ed6e"],
  ["/resume ~/.claude/projects/-Users-me-app/x.jsonl", "~/.claude/projects/-Users-me-app/x.jsonl"],
  [ID, ID],
  [`"${ID}"`, ID],
  [ID.toUpperCase(), ID.toUpperCase()],
  [`claude --resume ${ID}`, ID],
  [`claude -r ${ID}`, ID],
  [`claude --resume=${ID}`, ID],
  [`claude --dangerously-skip-permissions --resume ${ID} --model opus`, ID],
  [`codex resume ${ID}`, ID],
])("%p names the chat %p to resume", (text, ref) => {
  expect(resumeReference(text)).toBe(ref);
});

test.each([
  "",
  "/resume",
  "/resume   ",
  "/model opus",
  "/tmp",
  "fix the build",
  "claude",
  "claude --resume",
  `what is ${ID}?`,
  `/resume ${ID}\nand fix it`,
  "3224ed6e",
])("%p names no chat to resume", (text) => {
  expect(resumeReference(text)).toBeUndefined();
});

test("/resume <id> leads with the Resume row and offers no file address", () => {
  const list = rows(`/resume ${ID}`);
  expect(list[defaultSelection(list)]).toEqual({ type: "resume", ref: ID });
  expect(fileRows(list)).toEqual([]);
  // The slash command is not a web search either.
  expect(list.some((row) => row.type === "search")).toBe(false);
});

test("a pasted session id leads with the Resume row; Ask stays offered under it", () => {
  const list = rows(ID);
  expect(list[0]).toEqual({ type: "resume", ref: ID });
  expect(list.some((row) => row.type === "ask")).toBe(true);
});

test.each([`claude --resume ${ID}`, `claude -r ${ID}`])(
  "%p leads with the Resume row, Run in Terminal still under it",
  (text) => {
    const list = rows(text);
    expect(list[0]).toEqual({ type: "resume", ref: ID });
    expect(list.some((row) => row.type === "run" && row.command === text)).toBe(true);
  },
);

test("codex resume <id> leads with the Resume row", () => {
  expect(rows(`codex resume ${ID}`)[0]).toEqual({ type: "resume", ref: ID });
});

test("a real path still opens as a file, and other slash commands are no file address", () => {
  expect(rows("/tmp")[0]).toEqual({ type: "open", url: "file:///tmp", text: "/tmp" });
  expect(fileRows(rows("/model opus"))).toEqual([]);
  expect(rows("fix the build").some((row) => row.type === "resume")).toBe(false);
});
