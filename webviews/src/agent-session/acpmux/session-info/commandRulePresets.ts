// Rule presets: sets of command rules for one team's or one tool's own programs, which the built-in
// table (commandRules.ts) leaves out because nobody else runs them (Leo, 2026-11-03: "tho isn't
// glaeda-gh mostly me? we can prob genearlize more stuff"). A person turns one on by its name in
// cmux-next.json, before or between their own rules:
//
//   "agentPane": { "display": { "commandLabels": ["cmux-fleet", { "program": "deploy", ... }] } }
//
// A preset is code, not data, so its words are pane strings in every locale and it can read a
// command as closely as a built-in rule does. A new one is a new entry below with its own tests in
// test/command-rules.test.ts.
import {
  flag,
  github,
  OWNER_REPO,
  positionals,
  prLink,
  prName,
  programOf,
  programWords,
  pullRequest,
  titleCase,
  type CommandRule,
  type RuleRead,
} from "./commandRules";

/// manaflow's fleet tools: `glaeda-gh` (CI waits), `cmux-ci` (fleet tests and runs) and `sessions` /
/// `lane-place` (agent sessions).
const CMUX_FLEET: readonly CommandRule[] = [
  {
    // `glaeda-gh wait run OWNER/REPO/RUN_ID ...`, `glaeda-gh wait pr OWNER/REPO N` (or `OWNER/REPO#N`).
    id: "glaeda-wait",
    program: "glaeda-gh",
    icon: "status.inprogress",
    read: (words) => {
      if (words[1] !== "wait") return undefined;
      const [target, extra] = positionals(
        words,
        2,
        new Set(["--until", "--timeout", "--sha", "--rescue-grace", "--author", "--match", "--since", "--contains"]),
      );
      if (words[2] === "run") {
        const run =
          /^([\w.-]+)\/([\w.-]+)\/(\d+)$/.exec(target ?? "") ??
          /^https:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/actions\/runs\/(\d+)/.exec(target ?? "");
        if (!run) return { key: "commandRules.waitChecks", values: { target: "CI" } };
        return {
          key: "commandRules.waitChecks",
          values: { target: run[2]! },
          link: github(run[1]!, run[2]!, `actions/runs/${run[3]}`),
        };
      }
      if (words[2] === "pr") {
        const repo = OWNER_REPO.exec(target ?? "");
        const pr = pullRequest(repo ? extra : target, repo ? target : undefined);
        if (!pr) return { key: "commandRules.waitChecks", values: { target: "CI" } };
        return { key: "commandRules.waitChecks", values: { target: prName(pr) }, link: prLink(pr) };
      }
      return undefined;
    },
  },
  {
    // `cmux-ci test --setup playwright ... -- CMD`, `cmux-ci run --key ...-34769-...`,
    // `cmux-ci compile-check`.
    id: "cmux-ci",
    program: "cmux-ci",
    icon: "cloud",
    read: (words): RuleRead | undefined => {
      if (words[1] === "test") {
        const setup = flag(words, "--setup");
        if (setup) return { key: "commandRules.fleetTestsOf", values: { what: titleCase(setup) } };
        const dash = words.indexOf("--");
        const inner = dash < 0 ? [] : programWords(words.slice(dash + 1).join(" "));
        const program = programOf(inner);
        // A script run through a shell names nothing worth the line.
        if (!program || ["bash", "sh", "zsh"].includes(program)) return { key: "commandRules.fleetTests" };
        const detail = inner[1] && !inner[1].startsWith("-") ? `${program} ${inner[1]}` : program;
        const crate = program === "cargo" ? flag(inner, "-p", "--package") : undefined;
        return { key: "commandRules.fleetTestsOf", values: { what: crate ? `${detail} ${crate}` : detail } };
      }
      if (words[1] === "run") {
        // A PR number inside the run's key: `sr2c-ctx-34769-$(date +%s)`.
        const pr = /(?:^|[-_/#])(\d{4,6})(?=$|[-_/])/.exec(flag(words, "--key") ?? "")?.[1];
        return pr
          ? { key: "commandRules.fleetRunFor", values: { target: `#${pr}` } }
          : { key: "commandRules.fleetRun" };
      }
      if (words[1] === "compile-check") return { key: "commandRules.fleetCompile" };
      return undefined;
    },
  },
  {
    // `sessions new -n "Session Info drag handles" --brief b.md`, `lane-place ...` (its old name).
    id: "sessions-new",
    program: ["sessions", "lane-place"],
    icon: "agent.session",
    read: (words) => {
      const at = programOf(words) === "lane-place" ? 0 : 1;
      if (at === 1 && words[1] !== "new") return undefined;
      const name = flag(words.slice(at), "-n", "--name");
      return name
        ? { key: "commandRules.startingSessionNamed", values: { name } }
        : { key: "commandRules.startingSession" };
    },
  },
];

/// Every preset by the name cmux-next.json lists it under.
export const COMMAND_RULE_PRESETS: Readonly<Record<string, readonly CommandRule[]>> = {
  "cmux-fleet": CMUX_FLEET,
};
