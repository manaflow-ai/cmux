// Agent adapters for agent evals. Each adapter returns the shell command that
// runs the agent once, non-interactively, on the prompt in "$D/prompt.txt",
// and reads the agent's final message from its output files.
// Surfaces: "cli" (shell only) and "mcp" (also `cmux mcp serve`, code mode).
// The built-in "oracle" and "noop" agents validate the harness itself.
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const q = (s) => `'${String(s).replaceAll("'", "'\\''")}'`;
const read = (path) => (existsSync(path) ? readFileSync(path, "utf8") : "");

/** Codex MCP servers from the user's config that must stay off in evals (one is computer use). */
const CODEX_USER_MCP = ["node_repl", "openaiDeveloperDocs", "computer-use"];

export const AGENTS = Object.freeze({
  claude: {
    surfaces: ["cli", "mcp"],
    command: ({ dir, surface }) =>
      [
        "claude -p \"$(cat \"$D/prompt.txt\")\"",
        "--output-format json --dangerously-skip-permissions",
        "--strict-mcp-config", `--mcp-config ${q(join(dir, surface === "mcp" ? "mcp.json" : "mcp-empty.json"))}`,
        "--setting-sources project,local",
        "> \"$D/agent.out\" 2> \"$D/agent.err\"",
      ].join(" "),
    answer: (dir) => {
      try {
        return JSON.parse(read(join(dir, "agent.out"))).result ?? "";
      } catch {
        return read(join(dir, "agent.out"));
      }
    },
    meta: (dir) => {
      try {
        const out = JSON.parse(read(join(dir, "agent.out")));
        return { cost_usd: out.total_cost_usd ?? null, turns: out.num_turns ?? null, is_error: !!out.is_error };
      } catch {
        return {};
      }
    },
  },
  codex: {
    surfaces: ["cli", "mcp"],
    command: ({ dir, surface }) =>
      [
        "codex exec --json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check",
        "-c 'notify=[]'",
        ...CODEX_USER_MCP.map((name) => `-c ${q(`mcp_servers.${name}.enabled=false`)}`),
        ...(surface === "mcp" ? [`-c ${q(`mcp_servers.cmux.command="${join(dir, "mcp.sh")}"`)}`] : []),
        "-o \"$D/last.txt\"",
        "\"$(cat \"$D/prompt.txt\")\"",
        "> \"$D/agent.out\" 2> \"$D/agent.err\" < /dev/null",
      ].join(" "),
    answer: (dir) => read(join(dir, "last.txt")),
    meta: (dir) => {
      const usage = read(join(dir, "agent.out"))
        .split("\n")
        .filter((l) => l.includes("turn.completed"))
        .map((l) => {
          try {
            return JSON.parse(l).usage;
          } catch {
            return null;
          }
        })
        .filter(Boolean);
      return usage.length ? { input_tokens: usage.at(-1).input_tokens, output_tokens: usage.at(-1).output_tokens } : {};
    },
  },
  opencode: {
    // The default Kimi key is expired (2026-10-19); GLM goes through the subrouter.
    surfaces: ["cli", "mcp"],
    command: ({ dir, surface }) =>
      [
        surface === "mcp" ? `OPENCODE_CONFIG=${q(join(dir, "opencode-mcp.json"))}` : "",
        "opencode run -m zai/glm-5.2 \"$(cat \"$D/prompt.txt\")\"",
        "> \"$D/agent.out\" 2> \"$D/agent.err\" < /dev/null",
      ].join(" "),
    answer: (dir) => read(join(dir, "agent.out")).replace(/\x1b\[[0-9;]*m/g, ""),
    meta: () => ({}),
  },
  amp: {
    surfaces: ["cli"],
    command: () => "amp -x \"$(cat \"$D/prompt.txt\")\" --dangerously-allow-all > \"$D/agent.out\" 2> \"$D/agent.err\" < /dev/null",
    answer: (dir) => read(join(dir, "agent.out")),
    meta: () => ({}),
  },
  "cursor-agent": {
    surfaces: ["cli"],
    command: () => "cursor-agent -p \"$(cat \"$D/prompt.txt\")\" -f --output-format text > \"$D/agent.out\" 2> \"$D/agent.err\" < /dev/null",
    answer: (dir) => read(join(dir, "agent.out")),
    meta: () => ({}),
  },
  gemini: {
    surfaces: ["cli"],
    command: () => "gemini -p \"$(cat \"$D/prompt.txt\")\" --yolo > \"$D/agent.out\" 2> \"$D/agent.err\" < /dev/null",
    answer: (dir) => read(join(dir, "agent.out")),
    meta: () => ({}),
  },
  // Harness checks: oracle does each task the right way with the CLI (must
  // score 100%); noop does nothing (must fail every task that asks for work).
  oracle: {
    surfaces: ["cli"],
    command: ({ task }) => `bash ${q(join(import.meta.dir, "oracle.sh"))} ${q(task.id)} > "$D/agent.out" 2> "$D/agent.err"`,
    answer: (dir) => read(join(dir, "agent.out")),
    meta: () => ({}),
  },
  noop: {
    surfaces: ["cli"],
    command: () => "echo 'I did nothing.' > \"$D/agent.out\"",
    answer: (dir) => read(join(dir, "agent.out")),
    meta: () => ({}),
  },
});

/** Output that means the agent never got to work: no account, expired key, no network. */
export const NO_LOGIN_PATTERNS = [
  /api key has expired/i,
  /reauthenticate/i,
  /must specify the GEMINI_API_KEY/i,
  /not logged in|please log in|run .*login/i,
  /WritableIterable is closed/,
];
