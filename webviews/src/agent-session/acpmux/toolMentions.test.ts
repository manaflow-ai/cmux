// The composer's built-in @ tools (CMUX-682): which tools a sent message names, and the note the
// agent gets for them.
import { expect, test } from "bun:test";
import { slashMatches, slashTrigger, type SlashCommand } from "./slashCommands";
import {
  toolMentionContext,
  toolMentionsFor,
  toolMentionsIn,
  toolOfHref,
  toolSlashCommands,
  toolWords,
} from "./toolMentions";

test("a message names a tool as its own @word outside code, once, in menu order", () => {
  expect(toolMentionsIn("open the app with @computer-use")).toEqual(["computer-use"]);
  expect(toolMentionsIn("@browser-use then @computer-use, then @browser-use again.")).toEqual([
    "computer-use",
    "browser-use",
  ]);
  expect(toolMentionsIn("@Computer-Use please")).toEqual(["computer-use"]);
  // Inside code, inside a word or with more letters after it, it is not a mention.
  expect(toolMentionsIn("run `@computer-use` literally")).toEqual([]);
  expect(toolMentionsIn("```\n@browser-use\n```")).toEqual([]);
  expect(toolMentionsIn("mail me@computer-use.dev")).toEqual([]);
  expect(toolMentionsIn("@computer-user")).toEqual([]);
  // A file named after it is a file; a sentence's full stop still ends the mention.
  expect(toolMentionsIn("review @computer-use.md")).toEqual([]);
  expect(toolMentionsIn("use @computer-use. Then stop")).toEqual(["computer-use"]);
  expect(toolMentionsIn("no tools here")).toEqual([]);
});

test("a typed word finds a tool by its name or short form", () => {
  expect(toolMentionsFor("").map((tool) => tool.id)).toEqual(["computer-use", "browser-use"]);
  expect(toolMentionsFor("computer ").map((tool) => tool.id)).toEqual(["computer-use"]);
  expect(toolMentionsFor("bu").map((tool) => tool.id)).toEqual(["browser-use"]);
  expect(toolMentionsFor("x").map((tool) => tool.id)).toEqual([]);
});

test("the agent's note starts on its own line and names each tool the message named", () => {
  expect(toolMentionContext([])).toBeUndefined();
  const note = toolMentionContext(["computer-use", "browser-use"])!;
  expect(note.startsWith("\n\n<cmux-tools-context>\n")).toBe(true);
  expect(note).toContain("cmux Computer Use");
  expect(note).toContain("cmux-browser");
  expect(note.endsWith("</cmux-tools-context>")).toBe(true);
});

test("the / and $ menus list both tools as cmux's own rows, and a pick writes the @ word", () => {
  const tools = toolSlashCommands((key) => key);
  expect(tools.map((command) => [command.name, command.insert, command.source])).toEqual([
    ["computer-use", "@computer-use ", "extension"],
    ["browser-use", "@browser-use ", "extension"],
  ]);
  const skill: SlashCommand = { name: "emil-color", description: "", source: "skill" };
  const builtIn: SlashCommand = { name: "model", description: "", source: "cmux" };
  const commands = [builtIn, skill, ...tools];
  const names = (before: string, lead?: number) => {
    const trigger = slashTrigger(before, lead);
    return trigger ? slashMatches(commands, trigger).map((match) => match.command.name) : undefined;
  };
  // A `/` at the prompt's start lists everything; mid-prompt, the rows that go as text.
  expect(names("/", 0)).toEqual(["model", "emil-color", "computer-use", "browser-use"]);
  expect(names("open it with /comp")).toEqual(["computer-use"]);
  // `$` (Codex's skill mark) lists the rows that go as text wherever it is, the start included.
  expect(names("$", 0)).toEqual(["emil-color", "computer-use", "browser-use"]);
  expect(names("then $brow")).toEqual(["browser-use"]);
  expect(names("costs $5")).toEqual([]);
  expect(toolMentionsIn("open it with $computer-use")).toEqual(["computer-use"]);
});

test("the draft's badges: each tool word's range and href, and the tool each href names", () => {
  expect(toolWords("use @computer-use and \uFFFC@browser-use.")).toEqual([
    { start: 4, end: 17, href: "cmux-tool:computer-use" },
    { start: 23, end: 35, href: "cmux-tool:browser-use" },
  ]);
  expect(toolWords("review @computer-use.md or me@computer-use")).toEqual([]);
  expect(toolOfHref("cmux-tool:computer-use")?.icon).toBe("computeruse.observe");
  expect(toolOfHref("cmux://workspace/ws_1")).toBeUndefined();
});
