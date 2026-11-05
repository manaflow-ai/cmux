// l10n-allow-file: test fixtures (harness tool names, titles and paths), not shipped UI.
// The same tool renders the same way in every harness (toolNames.ts): each harness's read, search,
// glob, fetch and web search, in the shape its ACP adapter sends them, read as one label, group by
// what they did and count in a run's summary alike. Claude Code's and Codex's rows read as before.
// Leo, 2026-11-05: "idk how much we wanna potentially improve acpmux and cmux-next's rendering? We
// have a pretty good situation as-is but could we potentially do even better?"
import { describe, expect, test } from "bun:test";
import { agentCall } from "../src/agent-session/acpmux/conversation/agentCalls";
import { toolGroupKind, toolGroups } from "../src/agent-session/acpmux/conversation/toolGroups";
import { toolRunSummary } from "../src/agent-session/acpmux/conversation/toolRunSummary";
import { writeCall } from "../src/agent-session/acpmux/conversation/WriteLabel";
import { turnView, WORKING } from "../src/agent-session/acpmux/conversation/turns";
import { translatorFor } from "../src/agent-session/acpmux/i18n";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import {
  canonicalCall,
  HARNESS_TOOL_NAMES,
  toolForName,
  toolKind,
  type CanonicalTool,
} from "../src/agent-session/acpmux/toolNames";
import { editedPaths, toolLabel } from "../src/agent-session/acpmux/toolPaths";
import {
  HARNESS_CALLS,
  HARNESS_FIXTURE_CWD,
  harnessItems,
  type FixtureHarness,
} from "../src/agent-session/acpmux/toolNamesFixture";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const CWD = HARNESS_FIXTURE_CWD;
const t = translatorFor("en");
let ids = 0;
const call = (title: string, kind: string, fields: Partial<Tool> = {}): Tool => ({
  id: `t${(ids += 1)}`,
  title,
  kind,
  status: "completed",
  ...fields,
});
const at = (path: string) => ({ locations: [{ path }] });
const label = (tool: Tool) => toolLabel(tool, tool.title, (command) => `Ran ${command}`, CWD);

/// What each reads as. Claude Code keeps its own verbs (Grep), Codex its own (Search).
const EXPECTED: Record<string, Record<string, string>> = {
  claude: {
    read: "Read src/foo.ts",
    search: "Grep useTool",
    glob: "Glob **/*.ts",
    fetch: "Fetch https://example.com/docs",
    websearch: "Search acp tool kinds",
  },
  codex: {
    read: "Read src/foo.ts",
    search: "Search useTool",
    glob: "Glob **/*.ts",
    fetch: "Fetch https://example.com/docs",
    websearch: "Search acp tool kinds",
  },
};
const CANONICAL_LABELS = {
  read: "Read src/foo.ts",
  search: "Search useTool",
  glob: "Glob **/*.ts",
  fetch: "Fetch https://example.com/docs",
  websearch: "Search acp tool kinds",
};

for (const [harness, calls] of Object.entries(HARNESS_CALLS)) {
  describe(harness, () => {
    for (const [tool, value] of Object.entries(calls)) {
      test(`${tool} reads as its canonical tool`, () => {
        expect(canonicalCall(value)?.tool).toBe(tool as CanonicalTool);
        expect(label(value)).toBe(EXPECTED[harness]?.[tool] ?? CANONICAL_LABELS[tool as keyof typeof CANONICAL_LABELS]);
      });
    }

    test("reads group as reads, searches as searches, web calls on their own", () => {
      expect(toolGroupKind(calls.read)).toBe("reads");
      expect(toolGroupKind(calls.search)).toBe("searches");
      expect(toolGroupKind(calls.glob)).toBe("searches");
      expect(toolGroupKind(calls.fetch)).toBeUndefined();
      expect(toolGroupKind(calls.websearch)).toBeUndefined();
    });

    test("the five calls summarize alike", () => {
      expect(toolRunSummary(t, harnessItems(harness as FixtureHarness))).toBe(
        "Read a file, ran 2 searches, searched the web",
      );
    });
  });
}

test("a shell's command line never reads as the tool its first word names", () => {
  for (const command of ["grep -rn foo src", "ls src", "find . -name '*.ts'", "read -r line"]) {
    const shell = call(command, "execute", { command });
    expect(canonicalCall(shell)?.tool).toBe("shell");
    expect(label(shell)).toBe(`Ran ${command}`);
  }
});

test("Gemini's file writes and replaces read as writes and edits of their file", () => {
  const write = call(`Writing to ${CWD}/notes.md`, "edit", { status: "in_progress" });
  expect(canonicalCall(write)).toEqual({ tool: "write", input: { path: `${CWD}/notes.md` } });
  expect(editedPaths(write)).toEqual([`${CWD}/notes.md`]);
  expect(writeCall(write)).toEqual({ path: `${CWD}/notes.md` });
  const replace = call("src/foo.ts: const a = 1 => const a = 2", "edit", at(`${CWD}/src/foo.ts`));
  expect(canonicalCall(replace)?.tool).toBe("edit");
  expect(label(replace)).toBe("Edit src/foo.ts");
});

test("a raw tool name takes the canonical verb; a pending Gemini write keeps its own title", () => {
  expect(label(call("WebFetch", "fetch", { inputSummary: JSON.stringify({ url: "https://example.com" }) }))).toBe(
    "Fetch https://example.com",
  );
  expect(label(call("NotebookRead", "read", at(`${CWD}/a.ipynb`)))).toBe("Read a.ipynb");
  expect(label(call(`Writing to ${CWD}/notes.md`, "edit", { status: "pending" }))).toBe(`Writing to ${CWD}/notes.md`);
});

test("opencode's task reads as the same subagent card as Claude Code's Agent", () => {
  const input = { inputSummary: JSON.stringify({ description: "Find the bug", prompt: "Look for it" }) };
  expect(agentCall(call("task", "think", input))?.description).toBe("Find the bug");
  expect(agentCall(call("Agent: Find the bug", "think", input))?.description).toBe("Find the bug");
  expect(agentCall(call("read", "think", input))).toBeUndefined();
});

test("an acpmux dispatch run as a shell keeps its dispatch card", () => {
  const cli = call("Shell", "execute", { command: "acpmux dispatch brief.md --host h" });
  expect(toolGroups([{ kind: "tool", text: cli.title, tool: cli }])[0]?.type).toBe("dispatch");
});

test("a Gemini replace of a path with a space names its file", () => {
  const replace = call("src/my file.ts: const a = 1 => const a = 2", "edit", at(`${CWD}/src/my file.ts`));
  expect(label(replace)).toBe("Edit src/my file.ts");
});

test("Gemini's list_directory and Muse's read_file name their subject", () => {
  expect(label(call("src/components", "search"))).toBe("List src/components");
  expect(label(call("read_file: src/parser.rs", "read", at(`${CWD}/src/parser.rs`)))).toBe("Read src/parser.rs");
});

test("Gemini's bare folder lists and single-star globs read as such; a regex star does not", () => {
  expect(label(call("src", "search"))).toBe("List src");
  expect(label(call("'src/*.ts' within ./", "search"))).toBe("Glob src/*.ts");
  expect(label(call("'foo.*bar' within ./", "search"))).toBe("Search foo.*bar");
  expect(label(call("'foo*bar' within ./", "search"))).toBe("Search foo*bar");
});

test("a Claude Code Grep and Glob draw and count as searches, not reads", () => {
  expect(toolKind(HARNESS_CALLS.claude.search)).toBe("search");
  expect(toolKind(HARNESS_CALLS.gemini.websearch)).toBe("fetch");
});

test("every harness's names are in the table, case-blind", () => {
  for (const names of Object.values(HARNESS_TOOL_NAMES))
    for (const [name, tool] of Object.entries(names)) {
      expect(toolForName(name), name).toBe(tool);
      expect(toolForName(name.toUpperCase()), name).toBe(tool);
    }
  expect(toolForName("Frobnicate")).toBeUndefined();
});

test("calls no table names keep their titles", () => {
  expect(canonicalCall(call("mcp__repo__repo_grep", "other"))).toBeUndefined();
  expect(canonicalCall(call("ScheduleWakeup", "other"))).toBeUndefined();
  expect(label(call("Frobnicate", "other"))).toBe("Frobnicate");
});

test("the live line names a running search by its pattern, not the folder it searches", () => {
  const user: AcpmuxRow = { id: "u1", version: 1, at: 0, kind: "user", text: "find it" };
  for (const harness of ["claude", "opencode", "pi"] as const) {
    const search = { ...HARNESS_CALLS[harness].search, status: "in_progress" };
    const activity: AcpmuxRow = {
      id: "a1",
      version: 1,
      at: 1,
      kind: "activity",
      // Two searches share a closed line, so the live line is what names the running one.
      items: [
        { kind: "tool", text: search.title, tool: { ...search, id: `${search.id}-done`, status: "completed" } },
        { kind: "tool", text: search.title, tool: search },
      ],
    };
    const live = turnView([user, activity], new Set(), { working: true }).find((row) => row.kind === WORKING);
    expect(live?.doing, harness).toMatch(/ useTool$/);
  }
});
