import type { TurnFile } from "../diff";

type Output = Pick<TurnFile, "path" | "canonical">;
type Checkpoint = Pick<TurnFile, "path" | "displayPath" | "canonical">;
type Candidate = { path: string; order: number };

/// Keep the shortest output path; on equal lengths keep the earliest, exactly as the
/// Summary's previous filter + reduce over ordered outputs did.
function prefer(a: Candidate | undefined, b: Candidate | undefined): Candidate | undefined {
  if (!a) return b;
  if (!b) return a;
  return a.path.length < b.path.length || (a.path.length === b.path.length && a.order <= b.order) ? a : b;
}

function remember(table: Map<string, Candidate>, key: string, candidate: Candidate) {
  const previous = table.get(key);
  table.set(key, prefer(previous, candidate)!);
}

/// Index paths a tool reported so last-turn checkpoint files can find their Summary output
/// without scanning every output for every changed file. A canonical path wins only when
/// BOTH entries have one; otherwise the tool path may end in '/' + file.displayPath.
export function summaryOutputLookup(outputs: readonly Output[]): (file: Checkpoint) => string | undefined {
  const exact = new Set<string>();
  const canonical = new Map<string, Candidate>();
  const suffix = new Map<string, Candidate>();
  const suffixWithoutCanonical = new Map<string, Candidate>();

  outputs.forEach((output, order) => {
    const path = output.path;
    const candidate = { path, order };
    exact.add(path);
    if (output.canonical) remember(canonical, output.canonical, candidate);
    // Includes suffixes after every separator, so the literal endsWith('/' + displayPath)
    // rule still works when displayPath contains nested directories.
    for (let slash = path.indexOf("/"); slash >= 0; slash = path.indexOf("/", slash + 1)) {
      const key = path.slice(slash + 1);
      remember(suffix, key, candidate);
      if (!output.canonical) remember(suffixWithoutCanonical, key, candidate);
    }
  });

  return (file) => {
    // Exact names take precedence even if a file has a different canonical path.
    if (exact.has(file.path)) return file.path;
    const byCanonical = file.canonical ? canonical.get(file.canonical) : undefined;
    const bySuffix = (file.canonical ? suffixWithoutCanonical : suffix).get(file.displayPath);
    return prefer(byCanonical, bySuffix)?.path;
  };
}
