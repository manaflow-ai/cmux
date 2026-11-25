// What kind of work a background command does, from its command line, for the running tray's header
// counts (trayHeadKinds.ts) and its lines' marks. Leo, 2026-11-03: "you can split up
// commands/waits/bg tasks/subagents/maybe agent sessions you expect something from and maybe more if
// you can think like what KINDS of background commands run... so you can fit that all in counts of
// stuff and maybe times all in one line like a \ b \ c or a | b| c or a / b / c and whatnot". The
// kinds read as a coordinator's turn does: messages to other agents, reviews, test runs and builds
// (local or sent to the fleet with cmux-ci), waits on CI, a PR, a timer or a log, servers, and the
// rest as commands.
import { acpmuxSend } from "../conversation/acpmuxSends";
import type { StringKey } from "../i18n";
import { servesCommand } from "../session-info/processes";

export type CommandKind = "sends" | "reviews" | "tests" | "builds" | "waits" | "servers" | "commands";

/// The kinds in the order the header counts them, fixed so a count that appears or goes never moves
/// the others around more than its own width.
export const COMMAND_KINDS: readonly CommandKind[] = [
  "sends",
  "reviews",
  "tests",
  "builds",
  "waits",
  "servers",
  "commands",
];

/// Each kind's mark on its lines.
export const COMMAND_KIND_ICON: Record<CommandKind, string> = {
  sends: "agent.chat",
  reviews: "action.review",
  tests: "permission.checked",
  builds: "mode.build",
  waits: "history",
  servers: "server.health",
  commands: "terminal",
};

/// Each kind's count in words ("1 wait", "2 test runs").
export const COMMAND_KIND_COUNT: Record<CommandKind, StringKey> = {
  sends: "tray.kind.sends",
  reviews: "tray.kind.reviews",
  tests: "tray.kind.tests",
  builds: "tray.kind.builds",
  waits: "tray.kind.waits",
  servers: "tray.kind.servers",
  commands: "turn.working.commands",
};

// A tool counts only where a command starts (the line's start, or after `;`, `&&`, `||`, `|` or `(`),
// past a wrapper (`timeout 600`, `env`, `VAR=1`, `time`, `nice`), so an argument that names one
// ("grep tsc", "echo make sense") does not.
const AT_COMMAND = String.raw`(?:^|[;&|(])\s*(?:(?:timeout\s+\S+|env|time|nice|\w+=\S*)\s+)*`;
const atCommand = (tools: string) => new RegExp(`${AT_COMMAND}(?:${tools})`);

// A reviewer at work: router-review, a review box, a Codex review, a gh review.
const REVIEW = atCommand(
  String.raw`router-review\b|sessions\s+new\s+[^;&|]*--review\b|codex\s+(?:exec\s+)?review\b|gh\s+pr\s+review\b`,
);
// Waiting on something else: CI, a PR, a run, a reply, a timer, a condition or a log. A shell word
// (`sleep`, `until`, `while`, `wait`, `watch`) counts only at a command's start, and `while` only
// when it waits (not `while read`, which loops over input).
const WAIT = new RegExp(
  [
    String.raw`${AT_COMMAND}(?:sleep\s+\d|until\s|while\s+(?!read\b)|wait(?:\s|$)|watch\s)`,
    String.raw`\b(?:glaeda-gh|acpmux)\s+wait\b`,
    String.raw`\bgh\s+run\s+watch\b`,
    String.raw`\bgh\s+pr\s+checks\b[^;&|]*\s--watch\b`,
    String.raw`\blane-gh\s+(?:call\s+\S+\s+)?ci_wait\b`,
    String.raw`\btail\s+(?:-\w+\s+)*-[a-zA-Z]*[fF]\b`,
  ].join("|"),
);
// A test run, here or on the fleet.
const TEST = atCommand(
  String.raw`cmux-ci\s+test\b|bun\s+(?:run\s+)?test\b|bunx\s+vitest\b|cargo\s+(?:test|nextest)\b|(?:python3?\s+-m\s+)?pytest\b|(?:npx\s+)?(?:vitest|jest)\b|(?:npx\s+|bunx\s+)?playwright\s+test\b|go\s+test\b|swift\s+test\b|xcodebuild\s+[^;&|]*\btest\b|(?:npm|pnpm|yarn)\s+(?:run\s+)?test\b`,
);
// A build or compile, here or on the fleet.
const BUILD = atCommand(
  String.raw`cmux-ci\s+(?:compile-check|run|build)\b|cargo\s+(?:build|check|clippy)\b|swift\s+build\b|xcodebuild\b|make\b|(?:bun|npm|pnpm|yarn)\s+(?:run\s+)?build\b|(?:bunx\s+|npx\s+)?(?:vite\s+build|tsc)\b|cmake\s+--build\b|ninja\b|gradle\b`,
);

/// The kind of work a background command does, from its command line.
export function commandKind(command: string): CommandKind {
  // A message to another agent, waiting on its reply.
  if (/\b(?:acpmux|lane-gh)\s+send\b/.test(command) || acpmuxSend(command)) return "sends";
  if (REVIEW.test(command)) return "reviews";
  if (WAIT.test(command)) return "waits";
  if (TEST.test(command)) return "tests";
  if (BUILD.test(command)) return "builds";
  if (servesCommand(command)) return "servers";
  return "commands";
}
