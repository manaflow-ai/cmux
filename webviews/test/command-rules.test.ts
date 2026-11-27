// l10n-allow-file: test fixture commands, not shipped UI.
// The tray names a background command in words, not the shell line (Leo, 2026-11-03: "we should be
// able to parse these more... like instead of raw things, we should be able to
// deterministically/heuristically have stuff"; session-info/commandRules.ts). The built-in rules
// know only command shapes anyone runs; our own fleet tools are the `cmux-fleet` preset (Leo: "tho
// isn't glaeda-gh mostly me? we can prob genearlize more stuff"; commandRulePresets.ts), turned on
// in cmux-next.json with rules of one's own (commandLabelSettings.ts). The commands are real ones
// agents ran in the background, from the tray in his screenshots and from transcripts.
import { describe, expect, test } from "bun:test";
import { setPaneLanguage, translate } from "../src/agent-session/acpmux/i18n";
import {
  COMMAND_RULES,
  commandRead,
  programWords,
  type CommandRule,
} from "../src/agent-session/acpmux/session-info/commandRules";
import { COMMAND_RULE_PRESETS } from "../src/agent-session/acpmux/session-info/commandRulePresets";
import {
  COMMAND_LABELS_KEY,
  configuredCommandRules,
  currentCommandRules,
} from "../src/agent-session/acpmux/session-info/commandLabelSettings";
import { setChatDisplay } from "../src/agent-session/acpmux/chatDisplay";
import { isCommandLabel } from "../src/pages/settings/validate";
import { backgroundCommands } from "../src/agent-session/acpmux/session-info/processes";

setPaneLanguage("en");
const t = (key: Parameters<typeof translate>[0], values?: Parameters<typeof translate>[1]) =>
  translate(key, values, "en");
const read = (command: string, description?: string, configured: readonly CommandRule[] = []) =>
  commandRead(t, description === undefined ? { command } : { command, description }, undefined, configured);

type Case = [command: string, label: string, rule?: string, url?: string];
const run = (cases: readonly Case[], configured: readonly CommandRule[] = []) => {
  for (const [command, label, rule, url] of cases)
    test(JSON.stringify(command.slice(0, 60)), () => {
      const got = read(command, undefined, configured);
      expect(got.label).toBe(label);
      expect(got.rule).toBe(rule);
      expect(got.link?.url).toBe(url);
    });
};

describe("built-in rules: command shapes anyone runs", () => {
  run([
    // Leo's screenshots.
    ['python3 -c "import time; time.sleep(560)"; GH_QUOTA_TIMEOUT=1 gh pr view 1', "Waiting 9m 20s", "python-sleep"],
    // Without the preset, our own tools read by program and main argument.
    ["glaeda-gh wait run manaflow-ai/cmux/41762593154 --until done --timeout 3000 2>&1 | tail -5", "glaeda-gh wait"],
    ["cd ~/x && cmux-ci test --setup playwright --timeout 2400 -- bun test", "cmux-ci test"],
    ["sessions new -n 'Session Info drag handles' --brief b.md", "sessions new"],
    // Waits.
    ["sleep 690; date -u", "Waiting 11m 30s", "sleep"],
    ["sleep 5m", "Waiting 5m", "sleep"],
    // gh.
    [
      "gh pr merge 34395 -R manaflow-ai/cmux --squash --match-head-commit 5b7f734177dc3bc46cc7620f2bedc60891d72062 2>&1 | tail -5",
      "Merging cmux#34395",
      "gh",
      "https://github.com/manaflow-ai/cmux/pull/34395",
    ],
    ["cd ~/x && gh pr merge 34361 --squash --match-head-commit 73d09e86", "Merging #34361", "gh"],
    [
      "gh pr checks 33896 --repo manaflow-ai/cmux --watch",
      "Waiting on cmux#33896 checks",
      "gh",
      "https://github.com/manaflow-ai/cmux/pull/33896",
    ],
    [
      "timeout 100 gh pr merge 33896 --repo manaflow-ai/cmux --squash",
      "Merging cmux#33896",
      "gh",
      "https://github.com/manaflow-ai/cmux/pull/33896",
    ],
    ["gh pr create --base feat-cmux-next --title 'x' --body-file b.md", "Opening a pull request", "gh"],
    // git.
    [
      "# fg-ok\ncd /tmp/lane && git push -q origin HEAD:grid/sidebar-header > /tmp/push.log 2>&1; echo push=$?",
      "Pushing grid/sidebar-header",
      "git",
    ],
    ["cd ~/w && git push -q -u origin HEAD 2>&1 | tail -5; git rev-parse HEAD", "Pushing changes", "git"],
    ["git pull --rebase origin main", "Pulling", "git"],
    ["git -C ~/w fetch origin feat-cmux-next", "Fetching", "git"],
    ["git commit -qm 'fix: x'", "Committing", "git"],
    ["git clone --depth 1 https://github.com/manaflow-ai/cmux.git", "Cloning cmux", "git"],
    ["cd ~/w && git log --oneline -1 && cargo test -p acpmux 2>&1 | tail -30", "git log"],
    // Test runners.
    [
      "cd ~/w && nice cargo test -q -p acpmux --test hub_integration auto_resume 2>&1 | tail -15",
      "Testing acpmux",
      "cargo",
    ],
    [
      "cd ~/w/webviews && CMUX_BROWSER_TESTS=1 timeout 900 bun test test/composer-quiet-chips.test.ts 2>&1 | grep -E pass",
      "Testing composer-quiet-chips",
      "js",
    ],
    ["npm test", "Running tests", "js"],
    ["pnpm run test -- --watch=false", "Running tests", "js"],
    ["pytest tests/test_api.py -q", "Testing test_api", "python"],
    ["python3 -m pytest -x", "Running tests", "python"],
    ["go test ./...", "Running tests", "go"],
    ["go test -run TestX ./pkg/store", "Testing store", "go"],
    ["swift test --filter SettingsTests", "Testing SettingsTests", "swift"],
    ["xcodebuild -scheme cmux-unit -destination 'platform=macOS' test", "Testing cmux-unit", "xcodebuild"],
    // Builds and installs.
    ["cargo build --release -p cmux-tui", "Building cmux-tui", "cargo"],
    ["xcodebuild -scheme cmux -configuration Debug build", "Building cmux", "xcodebuild"],
    ["xcodebuild -scheme cmux clean", "xcodebuild"],
    ["yarn build", "Building", "js"],
    ["export CI=1 && make -j8 all", "Building", "make"],
    ["make test", "Running tests", "make"],
    ["bun install --frozen-lockfile", "Installing dependencies", "js"],
    ["npm i react", "Installing react", "js"],
    ["pip install -r requirements.txt", "Installing dependencies", "install"],
    ["python3 -m pip install requests", "Installing requests", "python"],
    ["brew install ripgrep", "Installing ripgrep", "install"],
    ["cargo install cargo-nextest", "Installing cargo-nextest", "cargo"],
    // The web, containers, other machines.
    ["curl -fsSL https://api.github.com/repos/x/y -o out.json", "Requesting api.github.com", "http"],
    ["docker build -t app:dev .", "Building app", "docker"],
    ["docker run --rm -e X=1 postgres:16", "Running postgres:16", "docker"],
    ["docker compose up -d", "Starting containers", "docker"],
    ["ssh -o BatchMode=yes dev@build-host 'cd ~/app && cargo test -p acpmux'", "On build-host: Testing acpmux", "ssh"],
    ["ssh mini-3 'tail -f /var/log/x.log'", "On mini-3: tail", "ssh"],
    ["ssh -N mini-3", "Connecting to mini-3", "ssh"],
    // A setup step's substitution is work: it stays named before the rule's words (#34679).
    ["A=$(touch marker); bun test", "touch marker · Running tests", "js"],
    [
      "SHA=$(git rev-parse HEAD); cmux-ci run --class light --key glyph-parity-${SHA:0:12} --ref $SHA --script x.sh",
      "git rev-parse HEAD · cmux-ci run",
    ],
    ['printf "%s" "$(git rev-parse HEAD)"', "git rev-parse HEAD · printf"],
    // No rule: the program and its main argument.
    ["cd ~/Projects/cmux && PORT=3000 bun run dev", "bun run dev"],
    [
      "python3 scripts/ci/merge_freeze.py check --repo manaflow-ai/cmux --pr 34361 2>&1 | tail -2",
      "python3 merge_freeze.py",
    ],
    ["env -u FOO ./scripts/reload.sh --tag x", "reload.sh"],
  ]);

  test("no built-in rule is about one team's own tools", () => {
    const programs = COMMAND_RULES.flatMap((rule) =>
      rule.program === undefined ? [] : typeof rule.program === "string" ? [rule.program] : rule.program,
    );
    for (const own of ["glaeda-gh", "cmux-ci", "lane-place", "sessions", "cmux"]) expect(programs).not.toContain(own);
  });

  test("the call's own description wins, and the rule still gives the link and icon", () => {
    const got = read("gh pr merge 34395 -R manaflow-ai/cmux --squash", "Land the tray fix");
    expect(got.label).toBe("Land the tray fix");
    expect(got.link?.url).toBe("https://github.com/manaflow-ai/cmux/pull/34395");
    expect(got.icon).toBe("git.pullrequest");
    expect(read("make", "  ").label).toBe("Building");
    expect(read("ls -la").icon).toBe("terminal");
  });

  test("an ssh line takes what it runs there's icon and link", () => {
    const got = read("ssh mini 'gh pr merge 7 -R o/r --squash'");
    expect(got.label).toBe("On mini: Merging r#7");
    expect(got.icon).toBe("git.pullrequest");
    expect(got.link?.url).toBe("https://github.com/o/r/pull/7");
    // Nested hops stop at a depth instead of recursing forever.
    expect(read(`ssh a ${"ssh b ".repeat(10)}make`).label.startsWith("On a: On b: On b: On b: ")).toBe(true);
  });

  test("the registry's description names a process whose call is not loaded", () => {
    const [command] = backgroundCommands(
      [
        {
          id: "s/1",
          toolCallId: "call-gone",
          command: "glaeda-gh wait run o/r/1",
          description: "Wait for CI",
          startedAt: 1,
          state: "running",
        },
      ],
      [],
      true,
    );
    expect(command!.description).toBe("Wait for CI");
  });

  test("the program is cut out of staging, wrappers, redirections and pipes", () => {
    expect(
      programWords("cd a && export X=1 && Y=2 timeout -k 5 600 nohup env Z=3 foo 'a b' 2>/dev/null | tail -1"),
    ).toEqual(["foo", "a b"]);
    expect(programWords("set -euo pipefail; source env.sh; bar --x")).toEqual(["bar", "--x"]);
    expect(programWords("cd ~/Projects")).toEqual(["cd", "~/Projects"]);
    expect(programWords("")).toEqual([]);
  });

  test("every rule has a unique id, an icon and a program", () => {
    const all = [...COMMAND_RULES, ...Object.values(COMMAND_RULE_PRESETS).flat()];
    expect(new Set(all.map((rule) => rule.id)).size).toBe(all.length);
    for (const rule of all) {
      expect(rule.icon).not.toBe("");
      expect(rule.program?.length).toBeGreaterThan(0);
    }
  });

  test("a long, quote-heavy command reads in one pass", () => {
    const long = `${'echo "a\\"b" '.repeat(5000)}| tail`;
    const started = performance.now();
    expect(read(long).label).toBe('echo a"b');
    expect(performance.now() - started).toBeLessThan(200);
  });
});

describe("the cmux-fleet preset", () => {
  const fleet = configuredCommandRules(["cmux-fleet"]);
  run(
    [
      // Leo's screenshots.
      [
        "glaeda-gh wait run manaflow-ai/cmux/41762593154 --until done --timeout 3000 2>&1 | tail -5",
        "Waiting on cmux checks",
        "glaeda-wait",
        "https://github.com/manaflow-ai/cmux/actions/runs/41762593154",
      ],
      [
        'cd ~/Projects/checkouts/cmux/lane--x && cmux-ci test --setup playwright --timeout 2400 --workflow-ref feat-cmux-next -- "$(cat s.sh)"',
        "Fleet tests · Playwright",
        "cmux-ci",
      ],
      [
        "cmux-ci run --key sr2c-ctx-34769-$(date +%s) --class light --script x.sh --ref abc",
        "Fleet run for #34769",
        "cmux-ci",
      ],
      // From transcripts.
      [
        "glaeda-gh wait run manaflow-ai/cmux/41723867191 --until done --jobs --timeout 5400 > /tmp/wait.log 2>&1; echo exit=$? >> /tmp/wait.log",
        "Waiting on cmux checks",
        "glaeda-wait",
        "https://github.com/manaflow-ai/cmux/actions/runs/41723867191",
      ],
      [
        "glaeda-gh wait pr manaflow-ai/cmux#34769 --until green --sha 0123abc",
        "Waiting on cmux#34769 checks",
        "glaeda-wait",
        "https://github.com/manaflow-ai/cmux/pull/34769",
      ],
      [
        'S=/tmp/s; cd ~/w && cmux-ci test -- bash -c "$(cat $S/web-ci.sh)" > $S/ci5w.log 2>&1',
        "Fleet tests",
        "cmux-ci",
      ],
      [
        "cmux-ci test -- cargo test -p acpmux --lib -- peer_forward 2>&1 | tail -30",
        "Fleet tests · cargo test acpmux",
        "cmux-ci",
      ],
      ["cmux-ci compile-check --app --ref abc", "Fleet compile check", "cmux-ci"],
      [
        "SHA=$(git rev-parse HEAD); cmux-ci run --class light --key glyph-parity-${SHA:0:12} --ref $SHA --script x.sh",
        "git rev-parse HEAD · Fleet run",
        "cmux-ci",
      ],
      [
        "sessions new -n 'Session Info drag handles' --brief b.md",
        "Starting Session Info drag handles",
        "sessions-new",
      ],
      ["lane-place --brief b.md", "Starting a session", "sessions-new"],
      ["sessions ls", "sessions ls"],
      ["glaeda-gh status run manaflow-ai/cmux/1", "glaeda-gh status"],
      // The built-in rules still apply under a preset.
      ["sleep 5m", "Waiting 5m", "sleep"],
      ["ssh mini-3 'cmux-ci compile-check'", "On mini-3: Fleet compile check", "ssh"],
    ],
    fleet,
  );
});

describe("rules from cmux-next.json", () => {
  const rules = configuredCommandRules([
    { program: "deploy", match: "^deploy (\\S+)", label: "Deploying {1}", link: "https://deploys.example.com/{1}" },
    { match: "^make (?<target>\\w+)", label: "make: {target}", icon: "mode.build" },
    { program: ["just", "task"], label: "Running a task" },
    { program: "bad", match: "(", label: "never" },
    { program: "x", label: "  " },
    { label: "no program or match" },
    { program: "evil", match: ".*", label: "Evil", link: "javascript:alert(1)" },
    "no-such-preset",
    "cmux-fleet",
  ]);

  run(
    [
      [
        "cd ~/app && deploy staging --wait 2>&1 | tee log",
        "Deploying staging",
        "configured-0",
        "https://deploys.example.com/staging",
      ],
      // A rule of one's own goes before the built-in ones.
      ["make release", "make: release", "configured-1"],
      ["just lint", "Running a task", "configured-2"],
      ["task build", "Running a task", "configured-2"],
      ["bad x", "bad x"],
      ["evil", "Evil", "configured-6"],
      // A preset listed after them still applies.
      ["cmux-ci compile-check", "Fleet compile check", "cmux-ci"],
    ],
    rules,
  );

  test("a rule's icon is its own, the terminal by default", () => {
    expect(read("make release", undefined, rules).icon).toBe("mode.build");
    expect(read("just lint", undefined, rules).icon).toBe("terminal");
  });

  test("anything but a list configures nothing", () => {
    for (const value of [undefined, null, "cmux-fleet", { program: "x", label: "y" }, 1])
      expect(configuredCommandRules(value)).toEqual([]);
  });

  test("the chat's display push carries the setting, compiled once per value", () => {
    setChatDisplay({ [COMMAND_LABELS_KEY]: ["cmux-fleet"] });
    const first = currentCommandRules();
    expect(first.map((rule) => rule.id)).toContain("glaeda-wait");
    expect(currentCommandRules()).toBe(first);
    setChatDisplay({});
    expect(currentCommandRules()).toEqual([]);
  });

  test("the Settings validator agrees with what the page reads", () => {
    for (const item of [
      "cmux-fleet",
      { program: "deploy", label: "Deploying" },
      { match: "^x", label: "X", icon: "cloud", link: "https://x" },
      { program: ["a", "b"], label: "A" },
    ])
      expect(isCommandLabel(item)).toBe(true);
    for (const item of [
      " ",
      { label: "x" },
      { program: "x" },
      { program: [], label: "x" },
      { program: "x", label: "x", icon: 1 },
      1,
    ])
      expect(isCommandLabel(item)).toBe(false);
  });
});
