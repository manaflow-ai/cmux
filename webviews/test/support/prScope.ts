// A whole-tree webviews check on a pull request (ui-rules, gallery coverage) fails only for the
// pull request's own findings, as the Swift lint gates do (scripts/ci/pr_owned_findings.py): one
// finding that reached feat-cmux-next used to fail every pull request until someone fixed it
// forward. ci-web.yml's react-apps-check sets CMUX_PR_CHANGED_FILES on a pull request's merge
// commit (the files from its first parent to HEAD). A finding counts when it names a file the
// pull request changes, a name on a line it adds or removes in a pending or allow list, or any
// finding when it changes the check's own code. The rest print as warnings and pass. Without
// CMUX_PR_CHANGED_FILES (locally, base pushes) every finding counts.
// CMUX_NEXT_STYLE_GUARDS=warn (ci-web.yml sets it for feat-cmux-next, Leo 2026-10-19) makes every
// finding a warning: these are style and structure rules, and they no longer fail a run there.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

export const REPO = path.resolve(import.meta.dir, "../../..");

/** Where a finding is: the repository paths it is about, and its names in a pending or allow list. */
export interface FindingPlace {
  files: readonly string[];
  names?: readonly string[];
}

export interface PrScope {
  /** False locally and on base pushes: every finding counts. */
  readonly scoped: boolean;
  /** The repository paths the pull request changes (empty when not scoped). */
  readonly changed: ReadonlySet<string>;
  /** Whether a finding at `place` fails this run. */
  owns(place: FindingPlace): boolean;
  /** The findings that fail this run; the others print as warnings. */
  owned<T>(findings: readonly T[], place: (finding: T) => FindingPlace, text: (finding: T) => string): string[];
}

/**
 * `rules`: repository paths of the check's own code (a change makes every finding count).
 * `lists`: repository paths (or patterns) of the files that name findings, such as pending and allow
 * lists or gallery entries' covers: a line the pull request adds or removes owns the names quoted on it.
 */
export function prScope(options: { rules: readonly string[]; lists?: readonly (string | RegExp)[] }): PrScope {
  const scope = changedScope(options);
  return process.env.CMUX_NEXT_STYLE_GUARDS === "warn" ? warnOnly(scope) : scope;
}

/** Every finding prints as a warning and none fails the run. */
function warnOnly(scope: PrScope): PrScope {
  return {
    scoped: scope.scoped,
    changed: scope.changed,
    owns: () => false,
    owned(findings, _place, text) {
      for (const finding of findings) console.log(`::warning title=Style rule (warn-only)::${text(finding)}`);
      return [];
    },
  };
}

function changedScope(options: { rules: readonly string[]; lists?: readonly (string | RegExp)[] }): PrScope {
  const listed = process.env.CMUX_PR_CHANGED_FILES;
  if (!listed) return everyFinding;
  const changed = new Set(fs.readFileSync(listed, "utf8").split("\n").filter(Boolean));
  if (options.rules.some((file) => changed.has(file))) return everyFinding;
  const names = new Set<string>();
  const lists = [...changed].filter((file) =>
    (options.lists ?? []).some((list) => (typeof list === "string" ? list === file : list.test(file))),
  );
  for (const list of lists) {
    const diff = execFileSync("git", ["diff", "-U0", "--no-renames", "HEAD^1", "HEAD", "--", list], {
      cwd: REPO,
      encoding: "utf8",
    });
    for (const line of diff.split("\n"))
      if (/^[+-](?![+-])/.test(line)) for (const match of line.matchAll(/"([^"]+)"/g)) names.add(match[1]!);
  }
  const owns = (place: FindingPlace) =>
    place.files.some((file) => changed.has(file)) || (place.names ?? []).some((name) => names.has(name));
  return {
    scoped: true,
    changed,
    owns,
    owned(findings, place, text) {
      const failing: string[] = [];
      for (const finding of findings) {
        if (owns(place(finding))) failing.push(text(finding));
        else console.log(`::warning title=On the base branch, not in this PR::${text(finding)}`);
      }
      return failing;
    },
  };
}

const everyFinding: PrScope = {
  scoped: false,
  changed: new Set(),
  owns: () => true,
  owned: (findings, _place, text) => findings.map(text),
};
