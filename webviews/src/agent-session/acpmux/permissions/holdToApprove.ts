// Hold to approve (holdToApprove.experiment.ts): which asks need the hold, how long it lasts and how
// far its ring has filled. Pure, so the cards (PermissionCard.tsx, permissions/Panel.tsx) and the
// test read the same rules; the hold's pointer and key wiring is HoldButton.tsx.
import { experimentArm } from "../../../experiments/experiment";
import { HOLD_DURATIONS_MS, holdToApprove, holdToApproveDuration, type HoldScope } from "./holdToApprove.experiment";

/// What a card knows of one ask: its ACP tool kind and, for a shell call, its command.
export type HoldAsk = { kind?: string; command?: string };

/// Where a program name stands as the command run, not an argument: the line's start, after `;`, `&`,
/// `|`, `(` or a backquote, or after sudo, xargs or env.
const AT = String.raw`(?:^|[;&|(\x60]\s*|\b(?:sudo|xargs|env)\s+(?:-\S+\s+)*)`;
const run = (body: string) => new RegExp(AT + body);
/// Words of a shell command that delete, overwrite or rewrite what cannot be had back. A heuristic for
/// an experiment's scope, not a guard: a miss means an ask allows at once, as it does today.
const DESTRUCTIVE_COMMANDS: readonly RegExp[] = [
  run(String.raw`(?:rm|rmdir|unlink|shred|truncate|mkfs(?:\.\w+)?)(?:\s|$)`),
  run(String.raw`dd\s[^;&|]*\bof=`),
  run(String.raw`find\s[^;&|]*\s-delete\b`),
  run(String.raw`sudo(?:\s|$)`),
  run(String.raw`(?:chmod|chown)\s+(?:-\S*R\S*|--recursive)\b`),
  run(String.raw`(?:kill|killall|pkill)(?:\s|$)`),
  /\bgit\s+reset\s+[^;&|]*--hard\b/,
  /\bgit\s+clean\b/,
  /\bgit\s+push\b[^;&|]*\s(?:--force(?:-with-lease)?|-f)(?:\s|=|$)/,
  /\bgit\s+push\b[^;&|]*\s\+\S/,
  /\bgit\s+restore\b/,
  /\bgit\s+checkout\s+(?:[^;&|]*\s)?(?:--|\.)(?:\s|$)/,
  /\bgit\s+branch\s+[^;&|]*-D\b/,
  /\bgit\s+stash\s+(?:drop|clear)\b/,
  /\b(?:drop\s+(?:table|database|schema)|truncate\s+table|delete\s+from)\b/i,
  // An output redirect that replaces a file (`> out.txt`), not an append, a descriptor dup or /dev/null.
  /(?:^|[^>&0-9])>(?![>&])\s*(?!\/dev\/null\b)[^\s;&|]/,
];

/// Whether an ask can lose work: a delete or move of files, or a shell command DESTRUCTIVE_COMMANDS
/// matches.
export function isDestructiveAsk(ask: HoldAsk): boolean {
  if (ask.kind === "delete" || ask.kind === "move") return true;
  const command = ask.command?.trim();
  if (!command) return false;
  return DESTRUCTIVE_COMMANDS.some((pattern) => pattern.test(command));
}

/// Whether an allow of these asks needs the hold under `scope`: none when off, every ask under
/// `all`, and under `destructive` a group with any destructive ask.
export function holdApplies(scope: HoldScope, asks: readonly HoldAsk[]): boolean {
  if (scope === "off") return false;
  if (scope === "all") return true;
  return asks.some(isDestructiveAsk);
}

/// The hold's settings as the experiments give them now (the host override, the debug key, else
/// off and 600 ms).
export function holdSettings(): { scope: HoldScope; durationMs: number } {
  return {
    scope: experimentArm(holdToApprove),
    durationMs: HOLD_DURATIONS_MS[experimentArm(holdToApproveDuration)],
  };
}

/// Under Reduce Motion the ring moves in this many steps instead of sweeping.
export const REDUCED_STEPS = 4;

/// How far the ring has filled, 0 to 1, `elapsed` ms into a hold of `durationMs`. With reduced
/// motion it jumps a quarter at a time (still full exactly at the end), so it shows progress with no
/// sweep.
export function holdProgress(elapsed: number, durationMs: number, reduced = false): number {
  if (!(durationMs > 0)) return 1;
  const fraction = Math.min(1, Math.max(0, elapsed / durationMs));
  if (!reduced || fraction >= 1) return fraction;
  return Math.floor(fraction * REDUCED_STEPS) / REDUCED_STEPS;
}
