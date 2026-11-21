// What the tray above the composer (subagents/SubagentTray.tsx) calls a background command, in words
// rather than the shell line (Leo, 2026-11-03, on tray lines reading `glaeda-gh wait run
// manaflow-ai/cmux/41762593154 --until done --timeout 3000 2>...`: "we should be able to parse these
// more... like instead of raw things, we should be able to deterministically/heuristically have
// stuff"; then: "tho isn't glaeda-gh mostly me? we can prob genearlize more stuff").
//
// A command is named, in this order, by:
// 1. what its call says it does: Claude's Bash `description`, which acpmux keeps on the process
//    (`BackgroundCommand.description`); Codex sends no such words;
// 2. the first configured rule that matches: the rules and presets a person lists under
//    `agentPane.display.commandLabels` in cmux-next.json (commandLabelSettings.ts), in their order;
// 3. the first rule of `COMMAND_RULES` that matches the program it runs. These know only command
//    shapes anyone runs (waits, test runners, builds and installs, git, `gh pr`, curl, docker,
//    `ssh HOST CMD`), never one team's own tools: those live in presets (commandRulePresets.ts);
// 4. its program and main argument (`cargo test`, `npm run lint`, `script.py`).
// The whole command stays the line's tooltip, and its expanded tail says it in full. A rule may also
// give the line an icon and a link (a pull request, a run), which a description does not remove.
//
// Before matching, the command is cut to the one program that does its work (`programWords`):
// leading comments, `cd X &&`, `export X=1;` and assignment-only steps go, then the `env`, `timeout
// 600`, `nohup` or `nice` wrapped around it, its redirections (`2>&1`, `> log`) and whatever its
// output is piped into (`| tail -5`), and every step after it. One pass over the text, quotes kept
// whole: nothing in here can backtrack.
import type { StringKey, StringValues, Translate } from "../i18n";
import { formatDuration } from "../conversation/turns";
import { commandWorkLabel } from "./commandWorkLabel";

/// A place a command is about: a pull request or a workflow run.
export type CommandLink = { url: string };

/// What one rule makes of a command: a pane string and its values (a built-in or preset rule), or
/// the words a person wrote (a rule from cmux-next.json).
export type RuleRead = (
  | {
      key: StringKey;
      values?: StringValues;
      /// A command run inside this one (`ssh HOST CMD`): its own label goes in `values.label`.
      inner?: string;
    }
  | { text: string }
) & { link?: CommandLink };

/// One rule: the program it is about, how it reads the program's words, and the icon its lines take.
export type CommandRule = {
  /// A stable name, for tests and the gallery.
  id: string;
  /// The program (the first word, a path's basename): only words whose program this is are read.
  /// None reads every command (a configured rule with only a pattern).
  program?: string | readonly string[];
  icon: string;
  /// The rule's reading of the program's words (the program first), or undefined when it does not
  /// apply.
  read: (words: readonly string[]) => RuleRead | undefined;
};

/// What the tray shows for a command.
export type CommandRead = {
  label: string;
  icon: string;
  link?: CommandLink;
  /// The rule that matched, if one did.
  rule?: string;
};

// ---- Reading words -------------------------------------------------------------------------------

/// A word, or an operator and where the text after it starts.
type Token = { word: string } | { op: string; end: number };

/// The command as shell words and the operators between them (`&&`, `||`, `|`, `;`, `&`, a newline).
/// Quotes are removed from a word (`"a b"` is `a b`), `$(...)` and backticks stay inside one, and a
/// `#` that starts a word comments out the rest of its line.
function tokens(text: string): Token[] {
  const out: Token[] = [];
  let index = 0;
  const length = text.length;
  while (index < length) {
    const char = text[index]!;
    if (char === " " || char === "\t" || char === "\r" || (char === "\\" && text[index + 1] === "\n")) {
      index += char === "\\" ? 2 : 1;
      continue;
    }
    if (char === "\n" || char === ";") {
      out.push({ op: ";", end: index + 1 });
      index += 1;
      continue;
    }
    if (char === "#") {
      const end = text.indexOf("\n", index);
      index = end < 0 ? length : end;
      continue;
    }
    if (char === "&" || char === "|") {
      const double = text[index + 1] === char;
      // `&>` and `|&` are redirections and pipes of both streams.
      if (char === "&" && text[index + 1] === ">") {
        index = readWord(text, index, out);
        continue;
      }
      index += double ? 2 : char === "|" && text[index + 1] === "&" ? 2 : 1;
      out.push({ op: double ? char + char : char, end: index });
      continue;
    }
    index = readWord(text, index, out);
  }
  return out;
}

/// Reads one word from `start`, pushes it, and returns where it ended.
function readWord(text: string, start: number, out: Token[]): number {
  let word = "";
  let index = start;
  let depth = 0;
  const length = text.length;
  while (index < length) {
    const char = text[index]!;
    if (depth === 0 && /[\s;|]/.test(char)) break;
    // `&` ends a word unless it is part of a redirection (`2>&1`, `&>`).
    if (depth === 0 && char === "&" && !(index === start || text[index - 1] === ">")) break;
    if (char === "'") {
      const close = text.indexOf("'", index + 1);
      const stop = close < 0 ? length : close;
      word += text.slice(index + 1, stop);
      index = stop + 1;
      continue;
    }
    if (char === '"') {
      index += 1;
      while (index < length && text[index] !== '"') {
        if (text[index] === "\\" && index + 1 < length) index += 1;
        word += text[index];
        index += 1;
      }
      index += 1;
      continue;
    }
    if (char === "\\" && index + 1 < length) {
      word += text[index + 1];
      index += 2;
      continue;
    }
    if (char === "$" && text[index + 1] === "(") {
      depth += 1;
      word += "$(";
      index += 2;
      continue;
    }
    if (char === ")" && depth > 0) depth -= 1;
    word += char;
    index += 1;
  }
  out.push({ word });
  return Math.max(index, start + 1);
}

type Step = { words: string[]; joiner?: string; start: number };

/// The steps of a command, how each is joined to the next, and where each starts in the text.
function steps(text: string): Step[] {
  const list: Step[] = [{ words: [], start: 0 }];
  for (const token of tokens(text)) {
    if ("op" in token) {
      list[list.length - 1]!.joiner = token.op;
      list.push({ words: [], start: token.end });
    } else list[list.length - 1]!.words.push(token.word);
  }
  return list.filter((step) => step.words.length > 0);
}

const ASSIGNMENT = /^[A-Za-z_]\w*=/;
/// A redirection, alone (`>`, `2>`) or with its target (`2>&1`, `>/dev/null`, `&>log`).
const REDIRECT = /^(?:\d*|&)(?:>>?|<|>&|<&)(.*)$/;

/// A step that only sets the stage for the next: `cd X`, `export X=1`, `set -e`, assignments.
const STAGING = (words: readonly string[]) =>
  (words[0] === "cd" && words.length <= 2) ||
  (words[0] === "export" && words.slice(1).every((word) => ASSIGNMENT.test(word))) ||
  (words[0] === "set" && words.slice(1).every((word) => /^[-+]/.test(word) || word === "pipefail")) ||
  ((words[0] === "source" || words[0] === ".") && words.length === 2) ||
  words.every((word) => ASSIGNMENT.test(word));

/// Words in front of a program that only run it another way, and how many arguments each takes.
const WRAPPERS: Record<string, (words: readonly string[], at: number) => number> = {
  env: (words, at) => skipFlags(words, at + 1, new Set(["-u", "-C", "-S"])),
  nohup: (_, at) => at + 1,
  time: (words, at) => skipFlags(words, at + 1),
  exec: (_, at) => at + 1,
  command: (_, at) => at + 1,
  caffeinate: (words, at) => skipFlags(words, at + 1, new Set(["-t", "-w"])),
  nice: (words, at) => skipFlags(words, at + 1, new Set(["-n"])),
  timeout: (words, at) => {
    const next = skipFlags(words, at + 1, new Set(["-k", "-s", "--kill-after", "--signal"]));
    // Its duration.
    return /^\d/.test(words[next] ?? "") ? next + 1 : next;
  },
};

/// The first word at or after `at` that is not a flag (or a flag's value, for those in `valued`).
function skipFlags(words: readonly string[], at: number, valued: ReadonlySet<string> = new Set()): number {
  let index = at;
  while (index < words.length && words[index]!.startsWith("-")) {
    index += valued.has(words[index]!) ? 2 : 1;
  }
  return index;
}

/// The words of the one program a command runs to do its work, its program first (see the top of
/// this file), or empty when it runs none.
export function programWords(command: string): string[] {
  return mainProgram(command).words;
}

/// The program's words and the text of the setup steps before it (`SHA=$(git rev-parse HEAD); `),
/// whose substitutions are work the label still names (`commandRead`).
function mainProgram(command: string): { words: string[]; setup: string } {
  const list = steps(command);
  let step = 0;
  // A staging step joined by `&&` or `;` sets the stage for the next one.
  while (
    step < list.length - 1 &&
    STAGING(list[step]!.words) &&
    (list[step]!.joiner === "&&" || list[step]!.joiner === ";")
  )
    step += 1;
  const words = list[step]?.words ?? [];
  const setup = step > 0 ? command.slice(0, list[step]!.start) : "";
  // Its redirections, alone or with their target.
  const kept: string[] = [];
  for (let index = 0; index < words.length; index += 1) {
    const match = REDIRECT.exec(words[index]!);
    if (!match) kept.push(words[index]!);
    else if (!match[1]) index += 1;
  }
  let at = 0;
  for (;;) {
    while (at < kept.length - 1 && ASSIGNMENT.test(kept[at]!)) at += 1;
    const word = kept[at] ?? "";
    const wrap = Object.hasOwn(WRAPPERS, word) ? WRAPPERS[word] : undefined;
    if (!wrap || at >= kept.length - 1) break;
    const next = wrap(kept, at);
    if (next <= at || next >= kept.length) break;
    at = next;
  }
  return { words: kept.slice(at), setup };
}

// ---- Helpers rules share (commandRulePresets.ts reads with them too) ------------------------------

/// A flag's value: `--key v` or `--key=v` (any of `names`).
export function flag(words: readonly string[], ...names: string[]): string | undefined {
  for (let index = 0; index < words.length; index += 1) {
    const word = words[index]!;
    for (const name of names) {
      if (word === name) return words[index + 1];
      if (name.startsWith("--") && word.startsWith(`${name}=`)) return word.slice(name.length + 1);
    }
  }
  return undefined;
}

/// The arguments that are not flags, after the program and `skip` subcommand words. A flag in
/// `valued` takes the next word as its value.
export function positionals(words: readonly string[], skip: number, valued: ReadonlySet<string> = new Set()): string[] {
  const out: string[] = [];
  for (let index = 1 + skip; index < words.length; index += 1) {
    const word = words[index]!;
    if (word === "--") break;
    if (word.startsWith("-")) {
      if (valued.has(word)) index += 1;
      continue;
    }
    out.push(word);
  }
  return out;
}

export const OWNER_REPO = /^([\w.-]+)\/([\w.-]+)$/;
export const github = (owner: string, repo: string, path: string): CommandLink => ({
  url: `https://github.com/${owner}/${repo}/${path}`,
});

/// A pull request named as `N`, `#N`, `owner/repo#N` or its URL, with the repo `-R` names.
export function pullRequest(
  target: string | undefined,
  repoFlag: string | undefined,
): { number: string; owner?: string; repo?: string } | undefined {
  if (!target) return undefined;
  const url = /^https:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/pull\/(\d+)/.exec(target);
  if (url) return { owner: url[1], repo: url[2], number: url[3]! };
  const full = /^([\w.-]+)\/([\w.-]+)#(\d+)$/.exec(target);
  if (full) return { owner: full[1], repo: full[2], number: full[3]! };
  const number = /^#?(\d+)$/.exec(target)?.[1];
  if (!number) return undefined;
  const repo = repoFlag ? OWNER_REPO.exec(repoFlag) : null;
  return repo ? { owner: repo[1], repo: repo[2], number } : { number };
}

export const prName = (pr: { number: string; repo?: string }) =>
  pr.repo ? `${pr.repo}#${pr.number}` : `#${pr.number}`;
export const prLink = (pr: { number: string; owner?: string; repo?: string }) =>
  pr.owner && pr.repo ? github(pr.owner, pr.repo, `pull/${pr.number}`) : undefined;

/// Seconds in a `sleep` duration: `90`, `1.5`, `5m`, `2h`, `1d`.
function sleepSeconds(text: string | undefined): number | undefined {
  const match = /^(\d+(?:\.\d+)?)([smhd]?)$/.exec(text ?? "");
  if (!match) return undefined;
  const scale = { "": 1, s: 1, m: 60, h: 3600, d: 86400 }[match[2] as "" | "s" | "m" | "h" | "d"];
  return Number(match[1]) * scale;
}

const waiting = (seconds: number | undefined): RuleRead | undefined =>
  seconds === undefined || !(seconds > 0)
    ? undefined
    : { key: "commandRules.waiting", values: { time: formatDuration(seconds * 1000) } };

/// A file or path as its short name: `test/composer-quiet.test.tsx` is `composer-quiet`,
/// `tests/test_api.py` is `test_api`.
const shortName = (path: string) =>
  (path.split("/").filter(Boolean).pop() ?? path)
    .replace(/::.*$/, "")
    .replace(/\.(?:test|spec)\.[cm]?[jt]sx?$/, "")
    .replace(/\.(?:[cm]?[jt]sx?|py)$/, "");

export const titleCase = (word: string) => word.charAt(0).toUpperCase() + word.slice(1);

/// The program `words` run (a path's basename).
export const programOf = (words: readonly string[]) => (words[0] ?? "").split("/").pop() ?? "";

const testOrBuild = (testing: boolean, target: string | undefined): RuleRead =>
  target
    ? { key: testing ? "commandRules.testing" : "commandRules.building", values: { target } }
    : { key: testing ? "commandRules.testingAll" : "commandRules.buildingAll" };

const installing = (target: string | undefined): RuleRead =>
  target ? { key: "commandRules.installing", values: { target } } : { key: "commandRules.installingDeps" };

/// A URL's host: `https://api.example.com/x` is `api.example.com`.
const hostOf = (url: string | undefined) =>
  url ? /^(?:[a-z][\w+.-]*:\/\/)?(?:[^@/]*@)?([^/:?#]+)/i.exec(url)?.[1] : undefined;

// ---- The rules -----------------------------------------------------------------------------------

/// The built-in rules, first match wins. Each reads only the words of the one program a command
/// runs, and each knows a command shape anyone runs; a team's own tools are a preset
/// (commandRulePresets.ts) a person turns on in cmux-next.json.
export const COMMAND_RULES: readonly CommandRule[] = [
  {
    // `sleep 560`, `sleep 5m`.
    id: "sleep",
    program: "sleep",
    icon: "history",
    read: (words) =>
      waiting(
        words.slice(1).reduce<number | undefined>((sum, word) => {
          const seconds = sleepSeconds(word);
          return seconds === undefined || sum === undefined ? undefined : sum + seconds;
        }, 0),
      ),
  },
  {
    // `python3 -c "import time; time.sleep(560)"`, as agents wait without a shell `sleep`.
    id: "python-sleep",
    program: ["python", "python3"],
    icon: "history",
    read: (words) => {
      const code = flag(words, "-c");
      const seconds = code ? /\btime\.sleep\(\s*(\d+(?:\.\d+)?)\s*\)/.exec(code)?.[1] : undefined;
      return seconds && /^\s*(?:import time\s*[;\n]\s*)?time\.sleep\([^)]*\)\s*;?\s*$/.test(code!)
        ? waiting(Number(seconds))
        : undefined;
    },
  },
  {
    // `gh pr merge N`, `gh pr checks N --watch`, `gh pr create`, `gh run watch ID`.
    id: "gh",
    program: "gh",
    icon: "git.pullrequest",
    read: (words) => {
      const repo = flag(words, "-R", "--repo");
      const valued = new Set(["-R", "--repo", "--match-head-commit", "-t", "--title", "-b", "--body", "-B", "--base"]);
      if (words[1] === "pr" && (words[2] === "merge" || words[2] === "checks")) {
        const pr = pullRequest(positionals(words, 2, valued)[0], repo);
        if (!pr) return undefined;
        return words[2] === "merge"
          ? { key: "commandRules.merging", values: { target: prName(pr) }, link: prLink(pr) }
          : words.includes("--watch")
            ? { key: "commandRules.waitChecks", values: { target: prName(pr) }, link: prLink(pr) }
            : undefined;
      }
      if (words[1] === "pr" && words[2] === "create") return { key: "commandRules.openingPr" };
      if (words[1] === "run" && words[2] === "watch") {
        const id = positionals(words, 2, valued)[0];
        const owner = repo ? OWNER_REPO.exec(repo) : null;
        return {
          key: "commandRules.waitChecks",
          values: { target: owner ? owner[2]! : "CI" },
          link: owner && id && /^\d+$/.test(id) ? github(owner[1]!, owner[2]!, `actions/runs/${id}`) : undefined,
        };
      }
      return undefined;
    },
  },
  {
    // `git push [-u] origin HEAD:refs/heads/x`, `git pull`, `git fetch`, `git commit -m x`,
    // `git clone URL`.
    id: "git",
    program: "git",
    icon: "git.branch",
    read: (words): RuleRead | undefined => {
      // `git -C DIR push`.
      const at = words[1] === "-C" ? 3 : 1;
      const sub = words[at];
      if (sub === "push") {
        const args = positionals(words, at, new Set(["-o", "--push-option", "--repo"]));
        const ref = args[1]
          ?.split(":")
          .pop()
          ?.replace(/^refs\/heads\//, "");
        return ref && ref !== "HEAD" && !ref.startsWith("+")
          ? { key: "commandRules.pushingBranch", values: { branch: ref } }
          : { key: "commandRules.pushing" };
      }
      if (sub === "pull") return { key: "commandRules.pulling" };
      if (sub === "fetch") return { key: "commandRules.fetching" };
      if (sub === "commit") return { key: "commandRules.committing" };
      if (sub === "clone") {
        const source = positionals(words, at, new Set(["-b", "--branch", "--depth", "--filter", "-o", "--origin"]))[0];
        const name = source
          ?.replace(/\/+$/, "")
          .split(/[/:]/)
          .pop()
          ?.replace(/\.git$/, "");
        return name ? { key: "commandRules.cloning", values: { target: name } } : undefined;
      }
      return undefined;
    },
  },
  {
    // `until [ -s /tmp/x/review.out ]; do sleep 5; done; cat ...`, `while ! test -f done.txt; ...`:
    // a loop that waits for a file. Claude's Monitor calls wait this way.
    id: "wait-for-file",
    program: ["until", "while"],
    icon: "history",
    read: (words) => {
      const test = words.findIndex((word) => word === "[" || word === "[[" || word === "test");
      if (test < 0) return undefined;
      const at = words.findIndex((word, index) => index > test && /^-[efsd]$/.test(word));
      const file = at < 0 ? undefined : words[at + 1];
      if (!file || file === "]" || file === "]]") return undefined;
      return { key: "commandRules.waitingForFile", values: { file: file.split("/").filter(Boolean).pop() ?? file } };
    },
  },
  {
    // `cargo test -p acpmux`, `cargo build -p cmux-tui`, `cargo nextest run -p x`, `cargo install x`.
    id: "cargo",
    program: "cargo",
    icon: "mode.build",
    read: (words) => {
      const sub = words.find((word, index) => index > 0 && !word.startsWith("-") && !word.startsWith("+"));
      if (sub === "install") return installing(positionals(words, 1).find((word) => word !== "install"));
      const testing = sub === "test" || sub === "nextest";
      if (!testing && sub !== "build" && sub !== "check" && sub !== "clippy") return undefined;
      return testOrBuild(testing, flag(words, "-p", "--package"));
    },
  },
  {
    // `bun test test/foo.test.tsx`, `npm test`, `pnpm run test`, `yarn build`, `npm ci`,
    // `bun add x`.
    id: "js",
    program: ["bun", "npm", "pnpm", "yarn"],
    icon: "mode.build",
    read: (words) => {
      const [sub, script] = [words[1], words[2]];
      if (sub === "test" || ((sub === "run" || sub === "run-script") && script === "test")) {
        const file =
          sub === "test" ? positionals(words, 1, new Set(["--timeout", "-t", "--test-name-pattern"]))[0] : undefined;
        return testOrBuild(true, file ? shortName(file) : undefined);
      }
      if (sub === "build" || (sub === "run" && script === "build")) return testOrBuild(false, undefined);
      if (sub === "install" || sub === "i" || sub === "ci" || sub === "add") {
        return installing(sub === "ci" ? undefined : positionals(words, 1)[0]);
      }
      // `yarn` alone installs.
      if (programOf(words) === "yarn" && words.length === 1) return installing(undefined);
      return undefined;
    },
  },
  {
    // `pytest tests/test_api.py`, `python3 -m pytest -q`, `python3 -m pip install x`.
    id: "python",
    program: ["pytest", "python", "python3"],
    icon: "mode.build",
    read: (words) => {
      const module = programOf(words) === "pytest" ? "pytest" : flag(words, "-m");
      const from = programOf(words) === "pytest" ? 0 : words.indexOf("-m") + 1;
      const rest = words.slice(from);
      if (module === "pytest") {
        const file = positionals(rest, 0, new Set(["-k", "-m", "-n", "--maxfail", "-p"]))[0];
        return testOrBuild(true, file ? shortName(file) : undefined);
      }
      if (module === "pip" && rest[1] === "install") return installing(positionals(rest, 1, new Set(["-r"]))[0]);
      return undefined;
    },
  },
  {
    // `pip install -r requirements.txt`, `brew install x`, `apt-get install -y x`.
    id: "install",
    program: ["pip", "pip3", "brew", "apt", "apt-get", "uv"],
    icon: "package",
    read: (words) => {
      const at = programOf(words) === "uv" && words[1] === "pip" ? 2 : 1;
      if (words[at] !== "install" && !(programOf(words) === "uv" && words[1] === "sync")) return undefined;
      return installing(positionals(words, at, new Set(["-r", "--requirement", "-c"]))[0]);
    },
  },
  {
    // `go test ./...`, `go test ./pkg/x`, `go build ./cmd/x`.
    id: "go",
    program: "go",
    icon: "mode.build",
    read: (words) => {
      if (words[1] !== "test" && words[1] !== "build") return undefined;
      const target = positionals(words, 1, new Set(["-run", "-o", "-tags", "-timeout", "-count", "-p"]))[0];
      const named = target && !target.startsWith("./...") && target !== "." ? shortName(target) : undefined;
      return testOrBuild(words[1] === "test", named);
    },
  },
  {
    // `swift test --filter X`, `swift build -c release`.
    id: "swift",
    program: "swift",
    icon: "mode.build",
    read: (words) =>
      words[1] === "test" || words[1] === "build"
        ? testOrBuild(words[1] === "test", flag(words, "--filter", "--product", "--target"))
        : undefined,
  },
  {
    // `make`, `make -j8 all`, `make test`.
    id: "make",
    program: ["make", "gmake"],
    icon: "mode.build",
    read: (words) => {
      const target = positionals(words, 0, new Set(["-C", "-f", "-j"])).find((word) => !word.includes("="));
      if (target === "test" || target === "check") return testOrBuild(true, undefined);
      return testOrBuild(false, target && target !== "all" ? target : undefined);
    },
  },
  {
    // `xcodebuild -scheme cmux-unit test`, `xcodebuild -scheme X build`.
    id: "xcodebuild",
    program: "xcodebuild",
    icon: "mode.build",
    read: (words) => {
      if (words.includes("-version") || words.includes("-showsdks") || words.includes("-list")) return undefined;
      const valued = new Set([
        "-scheme",
        "-project",
        "-workspace",
        "-destination",
        "-configuration",
        "-derivedDataPath",
        "-only-testing",
        "-skip-testing",
        "-sdk",
        "-resultBundlePath",
        "-testPlan",
      ]);
      const actions = positionals(words, 0, valued);
      // Only a build or test reads as one; `clean`, `archive` or `-exportArchive` fall back.
      const known = ["build", "test", "test-without-building", "build-for-testing"];
      if (actions.some((action) => !known.includes(action))) return undefined;
      if (words.some((word) => word.startsWith("-export"))) return undefined;
      return testOrBuild(
        actions.some((action) => action === "test" || action === "test-without-building"),
        flag(words, "-scheme"),
      );
    },
  },
  {
    // `curl -fsSL https://api.example.com/x`, `wget URL`.
    id: "http",
    program: ["curl", "wget"],
    icon: "link.web",
    read: (words) => {
      const url = words.slice(1).find((word) => /^https?:\/\//i.test(word));
      const host = hostOf(url);
      return host ? { key: "commandRules.fetchingFrom", values: { host } } : undefined;
    },
  },
  {
    // `docker build -t app .`, `docker run --rm img`, `docker compose up -d`, `docker pull img`.
    id: "docker",
    program: ["docker", "podman", "docker-compose"],
    icon: "package",
    read: (words) => {
      const valued = new Set([
        "-t",
        "--tag",
        "-f",
        "--file",
        "-e",
        "--env",
        "-v",
        "--volume",
        "-p",
        "--publish",
        "--name",
        "-w",
        "--workdir",
        "--network",
        "--platform",
        "--entrypoint",
        "-u",
        "--user",
        "--build-arg",
      ]);
      if (words[1] === "build" || (words[1] === "buildx" && words[2] === "build")) {
        const tag = flag(words, "-t", "--tag");
        return testOrBuild(false, tag ? tag.split(":")[0] : undefined);
      }
      if (words[1] === "run") {
        const image = positionals(words, 1, valued)[0];
        return image ? { key: "commandRules.runningImage", values: { image: image.split("@")[0]! } } : undefined;
      }
      if (words[1] === "pull") return positionals(words, 1)[0] ? { key: "commandRules.pulling" } : undefined;
      if ((words[1] === "compose" && words[2] === "up") || (programOf(words) === "docker-compose" && words[1] === "up"))
        return { key: "commandRules.startingContainers" };
      return undefined;
    },
  },
  {
    // `ssh mini-3 'cd x && make test'`: the inner command's label on its host.
    id: "ssh",
    program: ["ssh", "mosh"],
    icon: "machine.remote",
    read: (words) => {
      const valued = new Set([
        "-p",
        "-i",
        "-o",
        "-l",
        "-F",
        "-J",
        "-L",
        "-R",
        "-D",
        "-W",
        "-E",
        "-b",
        "-c",
        "-m",
        "-S",
        "-O",
        "-Q",
        "-w",
        "-e",
        "-I",
        "-B",
      ]);
      let index = 1;
      while (index < words.length && words[index]!.startsWith("-")) index += valued.has(words[index]!) ? 2 : 1;
      const target = words[index];
      if (!target) return undefined;
      const host = target.replace(/^[^@]*@/, "");
      const inner = words
        .slice(index + 1)
        .join(" ")
        .trim();
      return inner
        ? { key: "commandRules.onHost", values: { host }, inner }
        : { key: "commandRules.connecting", values: { host } };
    },
  },
];

/// The rules by program, and those that read every program, in order.
type RuleIndex = { byProgram: Map<string, CommandRule[]>; any: CommandRule[] };

function indexRules(rules: readonly CommandRule[]): RuleIndex {
  const index: RuleIndex = { byProgram: new Map(), any: [] };
  for (const rule of rules) {
    if (rule.program === undefined) {
      index.any.push(rule);
      continue;
    }
    for (const program of typeof rule.program === "string" ? [rule.program] : rule.program)
      index.byProgram.set(program, [...(index.byProgram.get(program) ?? []), rule]);
  }
  return index;
}

const BUILT_IN = indexRules(COMMAND_RULES);
const INDEXES = new WeakMap<readonly CommandRule[], RuleIndex>();
const indexOf = (rules: readonly CommandRule[]) => {
  let index = INDEXES.get(rules);
  if (!index) INDEXES.set(rules, (index = indexRules(rules)));
  return index;
};

/// The first rule of `index` that reads `words`. Rules for this program and rules for every program
/// keep their listed order between them.
function firstRead(index: RuleIndex, words: readonly string[]): { rule: CommandRule; read: RuleRead } | undefined {
  const candidates = index.any.length
    ? [...(index.byProgram.get(programOf(words)) ?? []), ...index.any]
    : (index.byProgram.get(programOf(words)) ?? []);
  for (const rule of candidates) {
    const read = rule.read(words);
    if (read) return { rule, read };
  }
  return undefined;
}

/// The longest fallback word; a longer one ends in an ellipsis.
const WORD_MAX = 32;
const clip = (word: string) => (word.length > WORD_MAX ? `${word.slice(0, WORD_MAX - 1)}…` : word);

/// A command no rule knows: its program and its main argument (`npm run lint`, `python3 script.py`,
/// `make`), a path shortened to its last part.
export function fallbackLabel(words: readonly string[]): string | undefined {
  const program = programOf(words);
  if (!program) return undefined;
  const parts = [program];
  for (const word of words.slice(1)) {
    if (word.startsWith("-") || ASSIGNMENT.test(word) || parts.length >= 3) break;
    parts.push(word.includes("/") ? (word.split("/").filter(Boolean).pop() ?? word) : word);
    // A subcommand runner names what it runs next (`npm run lint`, `bun run dev`); anything else
    // stops at its main argument.
    if (!["run", "exec", "x"].includes(word)) break;
  }
  return parts.map(clip).join(" ");
}

/// What a rule makes of a command's program, if one knows it: the configured rules (`configured`,
/// commandLabelSettings.ts) first, then the built-in ones.
export function ruleOf(
  command: string,
  configured: readonly CommandRule[] = [],
): { rule: CommandRule; read: RuleRead; setup: string } | undefined {
  const { words, setup } = mainProgram(command);
  const match = (configured.length ? firstRead(indexOf(configured), words) : undefined) ?? firstRead(BUILT_IN, words);
  return match ? { ...match, setup } : undefined;
}

/// The most words a description may have and still be only a nickname for the command ("hold",
/// "review result"): such a one is not enough on its own.
const TERSE_WORDS = 2;

/// A description, or, when it is only a word or two (Claude's Monitor calls, which an agent names
/// "hold" or "review result"), what the command does first and the agent's name for it after:
/// "Waiting 14m · hold" (Leo, 2026-11-04, on a tray of lines reading "Command hold": "wtf are these
/// holds"). A long description stays as it is; so does a short one when the command says no more
/// (Claude named the task only by its description, which then stands for the command too).
function describedLabel(description: string, command: string, reading: string | undefined): string {
  if (description.split(/\s+/).length > TERSE_WORDS) return description;
  if (!reading || command.trim() === description) return description;
  if (reading.toLowerCase() === description.toLowerCase()) return reading;
  return `${reading} · ${description}`;
}

/// How deep `ssh a ssh b ...` reads before the inner command is named as it is.
const INNER_DEPTH = 3;

/// What the tray shows for a command: its call's description, else a configured or built-in rule's
/// words, else its program and main argument; the rule's icon and link either way.
export function commandRead(
  t: Translate,
  command: { command: string; description?: string },
  fallbackIcon = "terminal",
  configured: readonly CommandRule[] = [],
  depth = 0,
): CommandRead {
  const match = ruleOf(command.command, configured);
  const description = command.description?.trim();
  // A command run inside this one (`ssh HOST CMD`) is named by the same rules.
  const inner: CommandRead | undefined =
    match && "key" in match.read && match.read.inner !== undefined
      ? depth < INNER_DEPTH
        ? commandRead(t, { command: match.read.inner }, fallbackIcon, configured, depth + 1)
        : { label: match.read.inner, icon: fallbackIcon }
      : undefined;
  // A setup step's substitution runs work (`SHA=$(git rev-parse HEAD); cmux-ci run …`): it stays
  // named before the rule's words, as commandWorkLabel.ts names it (#34679). One in the program's
  // own arguments (`--key x-$(date +%s)`) is part of what the rule reads.
  const setupWork = match?.setup ? commandWorkLabel(match.setup) : undefined;
  const ruled = !match
    ? undefined
    : "text" in match.read
      ? match.read.text
      : t(match.read.key, inner ? { ...match.read.values, label: inner.label } : match.read.values);
  const reading =
    (ruled && setupWork ? `${setupWork} · ${ruled}` : ruled) ||
    commandWorkLabel(command.command.trim()) ||
    fallbackLabel(programWords(command.command));
  const label = description ? describedLabel(description, command.command, reading) : reading || command.command;
  const link = match?.read.link ?? inner?.link;
  return {
    label,
    icon: (inner && inner.icon !== fallbackIcon ? inner.icon : match?.rule.icon) ?? fallbackIcon,
    ...(link ? { link } : {}),
    ...(match ? { rule: match.rule.id } : {}),
  };
}
