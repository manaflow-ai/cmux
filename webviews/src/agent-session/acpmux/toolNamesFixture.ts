// l10n-allow-file: fixture tool titles, paths and queries, not shipped UI.
// The same five calls (read a file, search for text, find files, fetch a page, search the web) in the
// shape each harness's ACP adapter sends them (toolNames.ts), for the test that they read alike and
// the gallery's `agent-pane.harness-tool-names`. Every path and query is made up.
import type { AcpmuxActivity } from "./model";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export const HARNESS_FIXTURE_CWD = "/work/app";
const CWD = HARNESS_FIXTURE_CWD;
const FILE = `${CWD}/src/foo.ts`;
const URL = "https://example.com/docs";

export type FixtureCall = "read" | "search" | "glob" | "fetch" | "websearch";
export type FixtureHarness = "claude" | "codex" | "gemini" | "opencode" | "pi";

const call = (harness: string, n: string, title: string, kind: string, fields: Partial<Tool> = {}): Tool => ({
  id: `${harness}-${n}`,
  title,
  kind,
  status: "completed",
  ...fields,
});
const input = (value: Record<string, unknown>) => ({ inputSummary: JSON.stringify(value) });
const at = (path: string) => ({ locations: [{ path }] });

export const HARNESS_CALLS: Record<FixtureHarness, Record<FixtureCall, Tool>> = {
  // acpmux's own titles (claude_stdio/mod.rs `tool_title`); Grep and Glob say "read", WebSearch "fetch".
  claude: {
    read: call("claude", "read", "Read foo.ts", "read", { ...input({ file_path: FILE }), ...at(FILE) }),
    search: call("claude", "search", "Grep useTool", "read", input({ pattern: "useTool", path: "src" })),
    glob: call("claude", "glob", "Glob **/*.ts", "read", input({ pattern: "**/*.ts" })),
    fetch: call("claude", "fetch", `Fetch ${URL}`, "fetch", input({ url: URL, prompt: "Summarize" })),
    websearch: call("claude", "websearch", "Search acp tool kinds", "fetch", input({ query: "acp tool kinds" })),
  },
  // cmux-codex-acp's parsed commands (items.rs) and web search item.
  codex: {
    read: call("codex", "read", "Read foo.ts", "read", {
      ...input({ command: "sed -n 1,80p src/foo.ts", cwd: CWD }),
      ...at(FILE),
    }),
    search: call("codex", "search", "Search useTool", "search", input({ command: "rg useTool", cwd: CWD })),
    glob: call("codex", "glob", "Glob **/*.ts", "search", input({ command: "rg --files -g '**/*.ts'", cwd: CWD })),
    fetch: call("codex", "fetch", `Fetch ${URL}`, "fetch"),
    websearch: call("codex", "websearch", "Search acp tool kinds", "fetch", input({ query: "acp tool kinds" })),
  },
  // Gemini CLI: no input, its descriptions as titles (packages/core tools `getDescription`).
  gemini: {
    read: call("gemini", "read", "src/foo.ts", "read", at(FILE)),
    search: call("gemini", "search", "'useTool' within src", "search"),
    glob: call("gemini", "glob", "'**/*.ts' within ./", "search"),
    fetch: call("gemini", "fetch", `Fetching content from: ${URL}`, "fetch"),
    websearch: call("gemini", "websearch", 'Searching the web for: "acp tool kinds"', "search"),
  },
  // opencode: the tool's name, then its own short title (a file name for a read); the input as sent.
  opencode: {
    read: call("opencode", "read", "src/foo.ts", "read", { ...input({ filePath: FILE }), ...at(FILE) }),
    search: call("opencode", "search", "grep", "search", input({ pattern: "useTool", path: "src" })),
    glob: call("opencode", "glob", "glob", "search", input({ pattern: "**/*.ts" })),
    fetch: call("opencode", "fetch", "webfetch", "fetch", input({ url: URL, format: "markdown" })),
    websearch: call("opencode", "websearch", "websearch", "fetch", input({ query: "acp tool kinds" })),
  },
  // pi: the tool's name and its input.
  pi: {
    read: call("pi", "read", "read", "read", input({ path: FILE })),
    search: call("pi", "search", "grep", "search", input({ pattern: "useTool", path: "src" })),
    glob: call("pi", "glob", "find", "search", input({ pattern: "**/*.ts" })),
    fetch: call("pi", "fetch", `Fetch ${URL}`, "fetch", input({ url: URL })),
    websearch: call("pi", "websearch", "Search acp tool kinds", "fetch", input({ query: "acp tool kinds" })),
  },
};

/// A harness's five calls as transcript items.
export const harnessItems = (harness: FixtureHarness): AcpmuxActivity[] =>
  Object.values(HARNESS_CALLS[harness]).map((tool) => ({ kind: "tool", text: tool.title, tool }));
