// "A connect is one inline card, one tap" (cmuxterm-hq docs/design/remote-integrations.md; Leo,
// 2026-11-10: "make that sequence of steps far more ergonomic, if not like nigh automatic. Just as
// few hurdles to jump through as possible"). A Cloud chat's GitHub call that failed because the
// team has no GitHub connection (or one that needs linking again, or leaves the repository out)
// becomes one card under the turn (GitHubConnectCard.tsx), with one Connect GitHub button. The
// reader keys on the two shapes the agent's side gives:
//   - the GitHub MCP tool error (acpmux github_mcp.rs `refusal_result`): `structuredContent.error`
//     with `connect.action === "accounts.githubConnect"`;
//   - the stderr line git and gh print on a Cloud VM (cmux-host github_cli.rs `Refused` Display:
//     `cmux github credential: OWNER/REPO: integration.not_found: … Next: … Connect GitHub …
//     \`cmux accounts github-connect\` …`), which the MCP error's text block repeats.
// One card per turn, not per call. Only the GitHub MCP server's own error and arguments name the
// repository; printed text never does (githubConnectCall).
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { mcpCall } from "./mcpCalls";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// The app action the card runs (Mac `accounts.githubConnect`: palette, Settings > Accounts >
/// GitHub, `cmux accounts github-connect`). The host runs it only on the person's gesture.
export const GITHUB_CONNECT_ACTION = "accounts.githubConnect";

/// The CLI command every refusal names (cmux-host github_cli.rs `CONNECT_GITHUB`): the line's
/// anchor, so the card's matcher reads the same words the agent's side writes.
export const GITHUB_CONNECT_CLI = "cmux accounts github-connect";

/// Why the chat needs a connect: none for this team, one that needs linking again, or one that
/// does not cover the repository (GitHub's page picks it).
export type GitHubConnectReason = "not-connected" | "needs-reauth" | "not-covered";

export type GitHubConnectNeed = {
  reason: GitHubConnectReason;
  /// `OWNER/REPO` the failed call named, when it named a well-formed one.
  repo?: string;
  /// The failed call's id: the card's identity within its turn.
  callId: string;
};

/// A GitHub repository's full name as GitHub allows it (an owner of up to 39 letters, digits and
/// inner dashes; a name of letters, digits, `.`, `_`, `-`, never `.` or `..`). The Mac checks the
/// same before it passes one on (AgentPaneRequest+Decoding.swift `isGitHubRepo`).
export function isGitHubRepo(value: unknown): value is string {
  if (typeof value !== "string" || value.length > 140) return false;
  const match = /^([A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)\/([A-Za-z0-9._-]{1,100})$/.exec(value);
  return Boolean(match && match[2] !== "." && match[2] !== "..");
}

const CODE = /\b(integration\.not_found|github\.not_connected|needs_reauth|policy\.denied)\b/;

function reasonOf(code: string | undefined): GitHubConnectReason | undefined {
  switch (code) {
    case "integration.not_found":
    case "github.not_connected":
      return "not-connected";
    case "needs_reauth":
      return "needs-reauth";
    case "policy.denied":
      return "not-covered";
    default:
      return undefined;
  }
}

/// The cmux GitHub MCP server's name (acpmux `github_mcp.rs`; Claude titles its tools
/// `mcp__github__<tool>`, Codex passes `server: "github"`).
export const GITHUB_MCP_SERVER = "github";

/// What a tool call's failure asks of GitHub, or undefined for any other call. The repository comes
/// only from trusted structure: the cmux GitHub MCP server's own error and the call's arguments to
/// that server. Text a call printed never names it (a file the agent read, a page it fetched, or a
/// shell's output could print a refusal-shaped line naming any repository), so a git or gh refusal
/// draws the card with no repository and Connect asks GitHub without one.
export function githubConnectCall(tool: Tool): Omit<GitHubConnectNeed, "callId"> | undefined {
  const output = tool.output;
  // Only a call that failed: a completed call's output is content (a file, a page, an issue).
  if (tool.status !== "failed" || !output || !output.includes("github")) return undefined;
  // Large outputs: the refusal is a short line at the end of what the call printed.
  const text = output.length > 65_536 ? output.slice(-65_536) : output;
  // A shell call is never an MCP call, whatever its title says (Claude titles a Bash call with its
  // command's first line, so `mcp__github__x; cat f` would read as the server).
  const shellCall = Boolean(tool.command) || tool.kind === "execute";
  const mcp = shellCall ? undefined : mcpCall(tool);
  if (mcp) {
    if (mcp.server !== GITHUB_MCP_SERVER) return undefined;
    const argsRepo = repoOfArgs(mcp.args);
    const structured = structuredNeed(parseJSON(text));
    // The call's own arguments name the repository; the error's `repo` only when they name none.
    if (structured) return { reason: structured.reason, ...pick(argsRepo ?? structured.repo) };
    const reason = lineReason(text);
    return reason ? { reason, ...pick(argsRepo) } : undefined;
  }
  // A shell call that ran git or gh: the agent side's refusal line, no repository.
  if (!tool.command || !/(?:^|[\s;&|(])(?:git|gh)\s/.test(tool.command)) return undefined;
  const reason = lineReason(text);
  return reason ? { reason } : undefined;
}

function lineReason(text: string): GitHubConnectReason | undefined {
  const line = refusalLine(text);
  return line ? reasonOf(CODE.exec(line)?.[1]) : undefined;
}

/// The turn's need: its last failed GitHub call that asks for a connect, over the turn's rows.
export function githubConnectNeed(rows: readonly AcpmuxRow[]): GitHubConnectNeed | undefined {
  for (let at = rows.length - 1; at >= 0; at -= 1) {
    const items = rows[at]!.kind === "activity" ? rows[at]!.items : undefined;
    if (!items) continue;
    for (let index = items.length - 1; index >= 0; index -= 1) {
      const tool = items[index]!.tool;
      if (!tool || tool.status === "pending" || tool.status === "in_progress") continue;
      const need = githubConnectCall(tool);
      if (need) return { ...need, callId: tool.id };
    }
  }
  return undefined;
}

const pick = (repo: string | undefined) => (isGitHubRepo(repo) ? { repo } : {});

/// The refusal's one line: it starts with the agent side's own prefix (`cmux github credential:`,
/// `cmux github gh:`, or the MCP text's `cmux could not get a token`) and names the next step and
/// the CLI command. A file that merely mentions the words (a source file read, a grep) is not one.
function refusalLine(text: string): string | undefined {
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!/^cmux (?:github\b|could not get a token\b)/.test(line)) continue;
    if (line.includes("Next: ") && line.includes(`\`${GITHUB_CONNECT_CLI}\``) && CODE.test(line)) return line;
  }
  return undefined;
}

function repoOfArgs(args: unknown): string | undefined {
  if (!isRecord(args)) return undefined;
  const { owner, repo } = args;
  return typeof owner === "string" && typeof repo === "string" ? `${owner}/${repo}` : undefined;
}

/// The MCP error at the top of the call's result only (`structuredContent.error`, or `error` when
/// the harness keeps only structuredContent): never one nested in content, where a fetched file or
/// page could carry one.
function structuredNeed(value: unknown): { reason: GitHubConnectReason; repo?: string } | undefined {
  if (!isRecord(value)) return undefined;
  const error = isRecord(value.structuredContent) ? value.structuredContent.error : value.error;
  if (!isRecord(error) || !isRecord(error.connect) || error.connect.action !== GITHUB_CONNECT_ACTION) return undefined;
  const reason =
    reasonOf(typeof error.detail === "string" ? error.detail : undefined) ??
    reasonOf(typeof error.code === "string" ? error.code : undefined);
  return reason ? { reason, ...(typeof error.repo === "string" && { repo: error.repo }) } : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseJSON(text: string): unknown {
  const trimmed = text.trim();
  if (!trimmed.startsWith("{") && !trimmed.startsWith("[")) return trimmed;
  try {
    return JSON.parse(trimmed);
  } catch {
    return trimmed;
  }
}

/// Where the card is. `waiting`: the person tapped Connect and GitHub's page is open; the chat goes
/// on by itself when the person comes back to it. `continuing`: the card sent the chat's Continue.
/// `refused`: the app did not run Connect, with its reason when it gave one.
export type GitHubConnectPhase =
  | { kind: "idle" }
  | { kind: "opening" }
  | { kind: "waiting"; left: boolean }
  | { kind: "continuing" }
  | { kind: "refused"; reason?: string };

/// Each card's phase, by chat and turn, so a card the virtual transcript draws again (scrolled
/// away and back) keeps it, and the Continue it sent is sent once.
const phases = new Map<string, GitHubConnectPhase>();
const PHASES_KEPT = 64;

export function cardPhase(key: string): GitHubConnectPhase {
  return phases.get(key) ?? { kind: "idle" };
}

export function setCardPhase(key: string, phase: GitHubConnectPhase): void {
  phases.delete(key);
  phases.set(key, phase);
  if (phases.size > PHASES_KEPT) phases.delete(phases.keys().next().value!);
}

/// The phase after the page's visibility changed while the card waits: leaving marks it, coming
/// back after leaving goes on. Anything else stays.
export function afterVisibility(phase: GitHubConnectPhase, visible: boolean): GitHubConnectPhase | "continue" {
  if (phase.kind !== "waiting") return phase;
  if (!visible) return phase.left ? phase : { kind: "waiting", left: true };
  return phase.left ? "continue" : phase;
}

/// The offer as the pane wires it (App.tsx): Connect runs the app action with the repository and
/// this chat's link (the host hands it to GitHub's return); Continue sends the chat's Continue
/// prompt (turnActions.ts `CONTINUE_PROMPT`). Connect rejects with the app's reason when it did not run.
export type GitHubConnectOffer = {
  connect(repo: string | undefined): Promise<void>;
  continue(): Promise<void>;
};
