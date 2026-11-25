// The New Tab's `/` menu, before the agent's deferred chat answers (5 to 12 s for Claude Code with
// many plugins): it lists what the person's newest chat of that agent in that folder listed, and
// shows the skills first, A to Z.
import { expect, test } from "bun:test";
import type { SlashCommand } from "../slashCommands";
import { folderChat, skillsFirst, withFolderCommands } from "./folderCommands";

const skill = (name: string): SlashCommand => ({ name, description: "", source: "skill" });
const cmux: SlashCommand = { name: "model", description: "Model", source: "cmux" };
const builtIn: SlashCommand = { name: "compact", description: "", source: "agent" };

test("the stand-in list is the newest local chat of the same agent in the same folder", () => {
  const sessions = [
    { sessionId: "old", harness: "claude", cwd: "/Users/you/cmux", updatedAt: 1 },
    { sessionId: "new", harness: "claude", cwd: "/Users/you/cmux", updatedAt: 3 },
    { sessionId: "codex", harness: "codex", cwd: "/Users/you/cmux", updatedAt: 9 },
    { sessionId: "elsewhere", harness: "claude", cwd: "/Users/you/other", updatedAt: 9 },
    // Another machine's chat: its folder is that machine's.
    { sessionId: "peer", harness: "claude", cwd: "/Users/you/cmux", updatedAt: 9, peer: "mini" },
  ];
  expect(folderChat(sessions, "claude", "/Users/you/cmux")).toBe("new");
  expect(folderChat(sessions, "codex", "/Users/you/cmux")).toBe("codex");
  expect(folderChat(sessions, "claude", "/nowhere")).toBeUndefined();
  expect(folderChat(sessions, undefined, "/Users/you/cmux")).toBeUndefined();
  expect(folderChat(sessions, "claude", undefined)).toBeUndefined();
});

test("the stand-in fills in only until the agent's own list arrives, without cmux's rows", () => {
  const kept = [cmux, skill("prime")];
  expect(withFolderCommands([cmux], kept).map((command) => command.name)).toEqual(["model", "prime"]);
  expect(withFolderCommands([cmux, skill("fresh")], kept).map((command) => command.name)).toEqual(["model", "fresh"]);
  expect(withFolderCommands([cmux], undefined)).toEqual([cmux]);
});

test("skills come first, A to Z by their shown name, then every other command in its order", () => {
  const commands = [cmux, skill("prime"), builtIn, skill("Emil-color"), skill("$apple-design"), skill("issues")];
  expect(skillsFirst(commands).map((command) => command.name)).toEqual([
    "$apple-design",
    "Emil-color",
    "issues",
    "prime",
    "model",
    "compact",
  ]);
  expect(skillsFirst([cmux, builtIn])).toEqual([cmux, builtIn]);
});
