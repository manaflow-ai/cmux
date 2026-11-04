// l10n-allow-file: test fixture commands, not shipped UI.
// The tray names a background command in words, not the shell line (Leo, 2026-11-03: "we should be
// able to parse these more... like instead of raw things, we should be able to
// deterministically/heuristically have stuff"; session-info/commandRules.ts). The commands are
// real ones agents ran in the background, from the tray in his screenshots and from transcripts.
import { describe, expect, test } from "bun:test";
import { setPaneLanguage, translate } from "../src/agent-session/acpmux/i18n";
import { COMMAND_RULES, commandRead, programWords } from "../src/agent-session/acpmux/session-info/commandRules";
import { backgroundCommands } from "../src/agent-session/acpmux/session-info/processes";

setPaneLanguage("en");
const t = (key: Parameters<typeof translate>[0], values?: Parameters<typeof translate>[1]) =>
  translate(key, values, "en");
const read = (command: string, description?: string) =>
  commandRead(t, description === undefined ? { command } : { command, description });

describe("a background command reads in words", () => {
  const cases: [command: string, label: string, rule?: string, url?: string][] = [
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
    ['python3 -c "import time; time.sleep(560)"; GH_QUOTA_TIMEOUT=1 gh pr view 1', "Waiting 9m 20s", "python-sleep"],
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
    ['S=/tmp/s; cd ~/w && cmux-ci test -- bash -c "$(cat $S/web-ci.sh)" > $S/ci5w.log 2>&1', "Fleet tests", "cmux-ci"],
    [
      "cd ~/w && git log --oneline -1 && cmux-ci test -- cargo test -p acpmux --lib -- peer_forward 2>&1 | tail -30",
      "git log",
    ],
    [
      "cmux-ci test -- cargo test -p acpmux --lib -- peer_forward 2>&1 | tail -30",
      "Fleet tests · cargo test acpmux",
      "cmux-ci",
    ],
    ["cmux-ci compile-check --app --ref abc", "Fleet compile check", "cmux-ci"],
    ["sleep 690; date -u", "Waiting 11m 30s", "sleep"],
    ["sleep 5m", "Waiting 5m", "sleep"],
    [
      "# fg-ok\ncd /tmp/lane && git push -q origin HEAD:grid/sidebar-header > /tmp/push.log 2>&1; echo push=$?",
      "Pushing grid/sidebar-header",
      "git-push",
    ],
    ["cd ~/w && git push -q -u origin HEAD 2>&1 | tail -5; git rev-parse HEAD", "Pushing changes", "git-push"],
    [
      "cd ~/w && nice cargo test -q -p acpmux --test hub_integration auto_resume 2>&1 | tail -15",
      "Testing acpmux",
      "cargo",
    ],
    ["cargo build --release -p cmux-tui", "Building cmux-tui", "cargo"],
    [
      "cd ~/w/webviews && CMUX_BROWSER_TESTS=1 timeout 900 bun test test/composer-quiet-chips.test.ts 2>&1 | grep -E pass",
      "Testing composer-quiet-chips",
      "bun-test",
    ],
    ["xcodebuild -scheme cmux-unit -destination 'platform=macOS' test", "Testing cmux-unit", "xcodebuild"],
    ["xcodebuild -scheme cmux -configuration Debug build", "Building cmux", "xcodebuild"],
    // A setup step's substitution is work: it stays named before the rule's words (#34679).
    [
      "SHA=$(git rev-parse HEAD); cmux-ci run --class light --key glyph-parity-${SHA:0:12} --ref $SHA --script x.sh",
      "git rev-parse HEAD · Fleet run",
      "cmux-ci",
    ],
    ["A=$(touch marker); bun test", "touch marker · Running tests", "bun-test"],
    ['printf "%s" "$(git rev-parse HEAD)"', "git rev-parse HEAD · printf"],
    // No rule: the program and its main argument.
    ["cd ~/Projects/cmux && PORT=3000 bun run dev", "bun run dev"],
    [
      "python3 scripts/ci/merge_freeze.py check --repo manaflow-ai/cmux --pr 34361 2>&1 | tail -2",
      "python3 merge_freeze.py",
    ],
    ["export CI=1 && make -j8 all", "make"],
    ["env -u FOO ./scripts/reload.sh --tag x", "reload.sh"],
    ["glaeda-gh status run manaflow-ai/cmux/1", "glaeda-gh status"],
  ];
  for (const [command, label, rule, url] of cases)
    test(JSON.stringify(command.slice(0, 60)), () => {
      const got = read(command);
      expect(got.label).toBe(label);
      expect(got.rule).toBe(rule);
      expect(got.link?.url).toBe(url);
    });

  test("the call's own description wins, and the rule still gives the link and icon", () => {
    const got = read(
      "glaeda-gh wait run manaflow-ai/cmux/41762593154 --until done",
      "Wait for the PR checks to finish",
    );
    expect(got.label).toBe("Wait for the PR checks to finish");
    expect(got.link?.url).toBe("https://github.com/manaflow-ai/cmux/actions/runs/41762593154");
    expect(got.icon).toBe("status.inprogress");
    expect(read("make", "  ").label).toBe("make");
    expect(read("ls -la").icon).toBe("terminal");
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
    expect(new Set(COMMAND_RULES.map((rule) => rule.id)).size).toBe(COMMAND_RULES.length);
    for (const rule of COMMAND_RULES) {
      expect(rule.icon).not.toBe("");
      expect(rule.program.length).toBeGreaterThan(0);
    }
  });

  test("a long, quote-heavy command reads in one pass", () => {
    const long = `${'echo "a\\"b" '.repeat(5000)}| tail`;
    const started = performance.now();
    expect(read(long).label).toBe('echo a"b');
    expect(performance.now() - started).toBeLessThan(200);
  });
});
