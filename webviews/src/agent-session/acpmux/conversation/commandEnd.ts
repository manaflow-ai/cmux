// A background command as every surface draws it (Leo, 2026-11-24, on a "Background command
// completed" row that opened to a Shell card with no command and no output: "but i couldnt... do
// anything?"): its command line, how it stands, and the end of what it printed. acpmux builds it
// (cmux-tui/crates/acpmux/src/hub/command_end.rs): a background turn's `cause.command`, and the same
// fields on `_acpmux/process/tail`'s reply. This file only reads it; it never fills a gap with a
// guess.
import type { AcpmuxCommandEnd } from "../model";

const STATES = ["printed", "empty", "gone"] as const;

/// `value` (a `cause.command`, or a `process/tail` reply's fields) as a command's end, or undefined
/// when it names neither a command nor a state.
export function commandEndOf(value: unknown): AcpmuxCommandEnd | undefined {
  if (!value || typeof value !== "object") return undefined;
  const raw = value as Record<string, unknown>;
  const command = typeof raw.command === "string" ? raw.command : "";
  const state = typeof raw.state === "string" ? raw.state : "";
  const outputState = STATES.find((known) => known === raw.outputState);
  if (!outputState || (!command && !state)) return undefined;
  const output = typeof raw.output === "string" && raw.output ? raw.output : undefined;
  return {
    command,
    ...(typeof raw.description === "string" && raw.description && { description: raw.description }),
    state,
    ...(Number.isInteger(raw.exitCode) && { exitCode: raw.exitCode as number }),
    outputState: outputState === "printed" && !output && !("data" in raw) ? "empty" : outputState,
    ...(output && { output }),
    ...(raw.cut === true && { cut: true }),
  };
}

/// Whether an opened card has anything to show: a command line, an exit code, or output (printed,
/// or known to be gone). A card with none of them does not open at all.
export function commandEndShows(end: Partial<AcpmuxCommandEnd> | undefined): boolean {
  if (!end) return false;
  return Boolean(end.command?.trim() || end.exitCode !== undefined || end.output?.trim() || end.outputState === "gone");
}
