// The composer's built-in @ tools (CMUX-682): which tools a sent message names, and the note the
// agent gets for them.
import { expect, test } from "bun:test";
import sharedCases from "../../../../cmux-tui/crates/acpmux/src/tool_mention_cases.json";
import { returnPicks, slashMatches, slashTrigger, type SlashCommand } from "./slashCommands";
import { withToolCommands } from "./composer/extensionCommands";
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
  // A four-backtick fence holds a three-backtick line; an inline `~~~` opens no fence.
  expect(toolMentionsIn("````\n```\n@computer-use\n````")).toEqual([]);
  expect(toolMentionsIn("a ~~~ b\nthen @computer-use")).toEqual(["computer-use"]);
  expect(toolMentionsIn("mail me@computer-use.dev")).toEqual([]);
  expect(toolMentionsIn("@computer-user")).toEqual([]);
  // A double-backtick code span is code too, and emphasis then letters is another word.
  expect(toolMentionsIn("run `` a `@computer-use` b `` now")).toEqual([]);
  expect(toolMentionsIn("see @computer-use_notes and @browser-use**x")).toEqual([]);
  // Markdown's emphasis around it is no part of the word.
  expect(toolMentionsIn("use **@computer-use** now and _@browser-use_")).toEqual(["computer-use", "browser-use"]);
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
  // A typographic quote around it is punctuation, as a straight one is.
  expect(toolWords("say \u201C@computer-use\u201D or \u2018@browser-use\u2019").map((word) => word.href)).toEqual([
    "cmux-tool:computer-use",
    "cmux-tool:browser-use",
  ]);
  expect(toolOfHref("cmux-tool:computer-use")?.icon).toBe("computeruse.observe");
  expect(toolOfHref("cmux://workspace/ws_1")).toBeUndefined();
});

test("a tool word right after an attachment placed in the text is still the mention", () => {
  expect(toolMentionsIn("\uFFFCshot-1\uFFFC@computer-use")).toEqual(["computer-use"]);
  expect(toolWords("\uFFFC@browser-use").map((word) => word.href)).toEqual(["cmux-tool:browser-use"]);
});

test("Return picks a $ row only once the arrows chose it: a price or a shell variable stays text", () => {
  const tools = toolSlashCommands((key) => key);
  const first = (before: string) => {
    const trigger = slashTrigger(before, undefined)!;
    return { trigger, match: slashMatches(tools, trigger)[0] };
  };
  const price = first("the price is $");
  expect(returnPicks(price.match, price.trigger.query, false, price.trigger.mark)).toBe(false);
  const variable = first("echo $BROWSER");
  expect(variable.match?.command.name).toBe("browser-use");
  expect(returnPicks(variable.match, variable.trigger.query, false, variable.trigger.mark)).toBe(false);
  expect(returnPicks(variable.match, variable.trigger.query, true, variable.trigger.mark)).toBe(true);
  // A `/word` keeps its rule: the typed start of a name picks it.
  const slash = first("open it with /comp");
  expect(returnPicks(slash.match, slash.trigger.query, false, slash.trigger.mark)).toBe(true);
});

// The cases acpmux's tool_mentions.rs reads too (tool_mention_cases.json): one list, so the gate, the
// badges and the agent's note agree on what names a tool.

test("every shared case names the tools acpmux's note names", () => {
  for (const { text, tools } of sharedCases as { text: string; tools: string[] }[])
    expect(`${text} -> ${toolMentionsIn(text).join(",")}`).toBe(`${text} -> ${tools.join(",")}`);
});

test("an agent command named like a tool keeps both rows: the tool row writes its @ word", () => {
  const tools = toolSlashCommands((key) => key);
  const agent: SlashCommand = { name: "computer-use", description: "", source: "agent" };
  const merged = withToolCommands([agent], tools);
  expect(merged.map((command) => [command.name, command.source, command.insert])).toEqual([
    ["computer-use", "agent", undefined],
    ["computer-use", "extension", "@computer-use "],
    ["browser-use", "extension", "@browser-use "],
  ]);
});
