/**
 * `cmux101 state` subcommand — read-only display of worker_state.json.
 */

import { join } from "node:path";

export interface StateResult {
  ok: boolean;
  data?: unknown;
  error?: string;
}

const HINT = `  Hint: worker state is written when you run an interactive REPL or a one-shot prompt.
  Run:   cmux101                # start the TUI
  Or:    cmux101 -p <prompt>    # one-shot print
  Then rerun: cmux101 state [--output-format json]`;

export async function runState(cwd: string): Promise<StateResult> {
  const wsPath = join(cwd, ".cmux101", "worker_state.json");

  let data: unknown;
  try {
    const file = Bun.file(wsPath);
    const exists = await file.exists();
    if (!exists) {
      return {
        ok: false,
        error: `error: no worker state file found at .cmux101/worker_state.json\n${HINT}`,
      };
    }
    data = await file.json();
  } catch (err) {
    return {
      ok: false,
      error: `error: no worker state file found at .cmux101/worker_state.json\n${HINT}`,
    };
  }

  return { ok: true, data };
}

export function formatStateHuman(data: unknown): string {
  if (!data || typeof data !== "object") {
    return String(data);
  }
  const lines: string[] = [];
  for (const [key, value] of Object.entries(data as Record<string, unknown>)) {
    lines.push(`${key}: ${value}`);
  }
  return lines.join("\n") + "\n";
}
