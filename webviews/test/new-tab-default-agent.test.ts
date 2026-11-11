// The agent a New Tab prompt goes to before the user picks one (new-user friction run,
// 2026-10-11): with Claude Code signed in, a first launch chose the cmux model router and showed
// "Qwen3.7 Flash". acpmux names its default (`defaultHarness`), but the native relay hands the
// `_acpmux/harnesses` reply on with its keys in any order, and the page took the first key.
import { expect, test } from "bun:test";
import { mergeModelCatalog } from "../src/agent-session/acpmux/modelCatalog";
import { defaultHarness } from "../src/agent-session/acpmux/newtab/screenModel";

const reply = {
  // Relay order: the router before Claude Code.
  harnesses: {
    cmux: { family: "claude", models: [{ id: "qwen/qwen3.7-flash", name: "Qwen3.7 Flash" }] },
    codex: {},
    claude: {},
  },
  defaultHarness: "claude",
};

const agents = () => mergeModelCatalog(reply, undefined).map((entry) => ({ id: entry.id, name: entry.name }));

test("a first launch asks acpmux's default agent, whatever order the reply's keys come in", () => {
  expect(defaultHarness(agents())).toBe("claude");
});

test("the agent the user picked last still comes first", () => {
  expect(defaultHarness(agents(), "codex")).toBe("codex");
});

// Leo 2026-11-11: a friend with neither Claude Code nor Codex "tried to start a chat" and "ran into"
// setup text. acpmux then lists only its built-in Chief and UniiChat, and the page asked the first of
// them. Neither is a default: the prompt asks Claude Code, whose start the composer's notice answers
// with Install, and a built-in agent asks only once it is picked.
test("a Mac with only the built-in agents asks Claude Code, never the Chief or UniiChat", () => {
  const builtIn = [
    { id: "chief", name: "Chief", family: "chief" },
    { id: "unii", name: "UniiChat", family: "unii" },
  ];
  expect(defaultHarness(builtIn)).toBe("claude");
  expect(defaultHarness(builtIn, "unii")).toBe("unii");
  expect(defaultHarness([...builtIn, { id: "codex", name: "Codex" }])).toBe("codex");
  // Before acpmux lists any agent there is none yet.
  expect(defaultHarness([])).toBeUndefined();
});
