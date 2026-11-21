// One row per installed agent CLI (Lawrence 2026-11-19, msg 42278: "there are duplicates sometimes").
// acpmux reports health per harness profile, and two profiles can run one binary: its `cmux` profile
// (the router fallback) runs the same ~/.local/bin/claude as `claude`. A list of updates is a list of
// binaries, so it shows that binary once, named for the agent it is, never for the profile ("Cmux").
// The pick never waits on the catalog: the same rows always give the same list. Used by the model
// menus' Harness updates (harnessUpdateList.ts) and Settings > Agents' update cards.
import { agentKey } from "../shared/agentKey";
import { knownAgentName } from "./agents";

/// The fields of a health row (`_acpmux/harness/health`) that say which install it is.
export type InstallRow = {
  id: string;
  /// Where acpmux found the program.
  path?: string | null;
  /// The npm package or Homebrew formula behind it.
  package?: string | null;
  update?: { command: string } | null;
};

/// The keys that name a row's install: its program's path with its package, and the command that
/// updates it (two rows that one command updates are one update). A row with neither is its own.
function installKeys(row: InstallRow): string[] {
  const keys: string[] = [];
  if (row.path) keys.push(`path:${row.path}\u0000${row.package ?? ""}`);
  if (row.update?.command) keys.push(`update:${row.update.command}`);
  return keys.length > 0 ? keys : [`id:${row.id}`];
}

/// Whether two health rows are one install.
export function sameInstall(a: InstallRow, b: InstallRow): boolean {
  const keys = new Set(installKeys(a));
  return installKeys(b).some((key) => keys.has(key));
}

const programOf = (row: InstallRow): string | undefined => row.path?.split("/").filter(Boolean).pop();

/// How well a row's id names the program it runs: 0 the program itself (`claude`), 1 a variant of
/// its agent (`claude-sr`), 2 a profile that wraps another agent's program (`cmux`).
function fit(row: InstallRow): number {
  const program = programOf(row);
  if (!program || row.id === program) return 0;
  return agentKey(row.id) === agentKey(program) ? 1 : 2;
}

/// `rows` with each install once, in the order its first row came: the row of each that `prefer`
/// takes (the menus' offered harnesses), then the one whose id is its program, then the shortest id.
export function oneRowPerInstall<T extends InstallRow>(
  rows: readonly T[],
  prefer: (row: T) => boolean = () => true,
): T[] {
  const groups: T[][] = [];
  const byKey = new Map<string, T[]>();
  for (const row of rows) {
    const keys = installKeys(row);
    const found = keys.map((key) => byKey.get(key)).filter((group): group is T[] => group !== undefined);
    const group = found[0] ?? [];
    if (found.length === 0) groups.push(group);
    group.push(row);
    // A row that joins two groups (one by path, one by command) makes them one.
    for (const other of found.slice(1)) {
      if (other === group) continue;
      group.push(...other);
      groups.splice(groups.indexOf(other), 1);
      for (const [key, value] of byKey) if (value === other) byKey.set(key, group);
    }
    for (const key of keys) byKey.set(key, group);
  }
  const rank = (row: T): [number, number, number, string] => [prefer(row) ? 0 : 1, fit(row), row.id.length, row.id];
  const before = (a: T, b: T) => {
    const [x, y] = [rank(a), rank(b)];
    for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return x[i]! < y[i]! ? -1 : 1;
    return 0;
  };
  return groups.map((group) => [...group].sort(before)[0]!);
}

/// The name a row's update shows: the agent its program is when its id names no agent this app
/// knows but its program does (`cmux` running `claude` is "Claude Code"), else `nameFor(id)`.
export function installName(row: InstallRow, nameFor: (id: string) => string): string {
  const program = programOf(row);
  if (!knownAgentName(row.id) && program) {
    const known = knownAgentName(program);
    if (known) return known;
  }
  return nameFor(row.id);
}
