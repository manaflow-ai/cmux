// l10n-allow-file: gallery fixtures (sample session names, branches and paths), not shipped UI.
// "Who else is working on these files" (WhoElseCard.tsx, whoElseCalls.ts): acpmux's who_else answer
// as one card in place of raw MCP or Bash output, whether a Claude chat called the acpmux MCP tool or
// a Codex chat ran `acpmux who-else --json` in its shell. Each session name is a chip that opens its
// chat; a peer's names its machine. Leo, 2026-11-05: "I kind of like this where like Claude sometimes
// decides to look up who else is working on stuff potentially".
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, session, tool, user } from "../../../gallery/fixtures/acpmux";
import { WHO_ELSE_SCHEMA } from "./whoElseCalls";
import real from "./whoElseCalls.fixture.json";

const MINUTE = 60_000;
const file = (path: string, edited: boolean) => ({ repo: "github.com/example/cmux", path, edited });

const ROWS = [
  {
    sessionId: "who-crate-split",
    name: "crate-split",
    ref: "crate-split",
    title: "Split cmux-tui-core into domain crates",
    harness: "codex",
    status: "running",
    live: true,
    branch: "lane/crate-split",
    pullRequests: ["https://github.com/example/cmux/pull/36001"],
    agoMs: 4 * MINUTE,
    filesInCommon: 4,
    editedInCommon: 2,
    files: [
      file("cmux-tui/crates/cmux-tui-core/src/mux.rs", true),
      file("cmux-tui/crates/cmux-tui-core/src/server.rs", true),
      file("cmux-tui/crates/cmux-tui-core/Cargo.toml", false),
    ],
    sameWorktree: false,
    sameBranch: false,
    topicWords: [],
  },
  {
    sessionId: "who-mux-rs",
    name: "mux-rs",
    ref: "big-red/mux-rs",
    host: "big-red",
    title: "mux.rs refactor",
    harness: "opencode",
    status: "idle",
    live: true,
    branch: "lane/mux-rs",
    pullRequests: [],
    agoMs: 3 * 60 * MINUTE,
    filesInCommon: 1,
    editedInCommon: 0,
    files: [file("cmux-tui/crates/cmux-tui-core/src/mux.rs", false)],
    sameWorktree: false,
    sameBranch: false,
    topicWords: [],
  },
  {
    sessionId: "who-term-hosts",
    name: "windows-terminal-hosts",
    ref: "windows-terminal-hosts",
    harness: "claude",
    status: "idle",
    live: true,
    branch: "lane/windows-terminal-hosts",
    pullRequests: ["https://github.com/example/cmux/pull/35880"],
    agoMs: 26 * 60 * MINUTE,
    filesInCommon: 0,
    editedInCommon: 0,
    files: [],
    sameWorktree: false,
    sameBranch: false,
    topicWords: ["crate", "split"],
  },
];

const answer = (sessions: unknown[], unreached: unknown[] = []) => ({
  schema: WHO_ELSE_SCHEMA,
  query: { files: ["cmux-tui/crates/cmux-tui-core/src/mux.rs"], fileCount: 1, topic: "crate split" },
  sessions,
  more: 0,
  unreached,
  lines: [],
});

/// Claude Code's shape: `mcp__acpmux__who_else`, the MCP result whole as its output.
const mcp = (result: unknown, status = "completed") =>
  tool("mcp__acpmux__who_else", "other", status, {
    inputSummary: JSON.stringify({ files: ["cmux-tui/crates/cmux-tui-core/src/mux.rs"], topic: "crate split" }),
    ...(result !== undefined && {
      output: JSON.stringify({ content: [{ type: "text", text: "…" }], structuredContent: result }),
    }),
  });

/// Codex's shape: a shell `acpmux who-else --json`, its stdout the answer.
const shell = (result: unknown) =>
  tool("acpmux --json who-else cmux-tui/crates/cmux-tui-core/src/mux.rs", "execute", "completed", {
    command: "acpmux --json who-else cmux-tui/crates/cmux-tui-core/src/mux.rs",
    output: JSON.stringify(result),
  });

const ask = "Before splitting mux.rs out, check who else is working on it.";
const others = [
  session({ sessionId: "who-crate-split", title: "Split cmux-tui-core into domain crates", harness: "codex" }),
];

export default agentPaneEntry({
  id: "agent-pane.who-else",
  title: "Who else is working on these files",
  area: "Agent pane",
  height: 420,
  covers: ["agent-session/acpmux/conversation/WhoElseCard.tsx"],
  variants: {
    claude: {
      note: "A Claude chat's acpmux who_else call: three sessions, the editor first, a peer's named with its machine, one matched by topic; one machine did not answer.",
      snapshot: (() => {
        const snapshot = chat(
          [
            user(ask, 3),
            activity([mcp(answer(ROWS, [{ host: "cosmic-gray", error: "no answer in 5 s" }]))], 2.8),
            assistant(
              "crate-split (Codex) is editing mux.rs and server.rs right now; I'll message it before touching them.",
              2.5,
            ),
          ],
          { title: "Move mux.rs to its own crate", branch: "lane/mux-crate" },
        );
        return { ...snapshot, sessions: [...snapshot.sessions, ...others] };
      })(),
    },
    codex: {
      note: "A Codex chat ran `acpmux who-else --json` in its shell: the same card, not the raw JSON.",
      snapshot: chat([user(ask, 3), activity([shell(answer(ROWS.slice(0, 1)))], 2.8)], {
        title: "Move mux.rs to its own crate",
        harness: "codex",
        model: "gpt-6.1-sol",
      }),
    },
    live: {
      note: "The answer a live Claude session got in an end-to-end run while a Codex session in another worktree edited the same file.",
      snapshot: chat(
        [
          user("Add greet_loud() to src/lib.rs, then check who else works on it.", 3),
          activity([mcp(JSON.parse(real.claude.at(-1)!.content![0]!.content.text) as unknown)], 2.8),
          assistant("greet-codex (Codex, lane/greeting) is editing src/lib.rs right now.", 2.5),
        ],
        { title: "Add greet_loud", branch: "main" },
      ),
    },
    nobody: {
      note: "Nobody else touches the files: one quiet line.",
      snapshot: chat([user(ask, 3), activity([mcp(answer([]))], 2.8)]),
    },
    looking: {
      note: "The call still runs.",
      snapshot: chat([user(ask, 3), activity([mcp(undefined, "in_progress")], 2.8)], { isWorking: true }),
    },
  },
});
