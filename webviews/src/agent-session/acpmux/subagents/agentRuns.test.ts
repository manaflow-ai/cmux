// l10n-allow-file: recorded shell commands and prompts, not shipped UI.
import { describe, expect, test } from "bun:test";
import { agentRun, backgroundOutputPath, promptTitle, runModel, runReply, simpleCommands } from "./agentRuns";

describe("agentRun", () => {
  test("a recorded Codex review through reach, its prompt on stdin", () => {
    // Claude Code recorded this call on 2026-10-24 (paths scrubbed).
    const command =
      "cd /tmp && ~/.local/bin/reach cmux16 'cd /tmp && codex exec --skip-git-repo-check --sandbox read-only -c model_reasoning_effort=xhigh -m gpt-6-astra - 2>&1 | tail -70' < /tmp/lane/review/1017.txt > /tmp/lane/review/1017.out 2>&1; tail -70 /tmp/lane/review/1017.out";
    expect(agentRun(command)).toEqual({ harness: "codex", model: "gpt-6-astra", effort: "xhigh", host: "cmux16" });
  });

  test("an inline prompt, through the perl alarm and timeout wrappers", () => {
    expect(
      agentRun(
        `cd /tmp && perl -e 'alarm 120; exec @ARGV' codex exec -m gpt-6.1-sol --skip-git-repo-check "Reply with OK." 2>&1 | tail -5`,
      ),
    ).toEqual({ harness: "codex", model: "gpt-6.1-sol", prompt: "Reply with OK." });
    expect(agentRun(`timeout -k 5 600 nohup env A=1 codex exec "Codex xhigh re-review of hq#4038"`)?.prompt).toBe(
      "Codex xhigh re-review of hq#4038",
    );
  });

  test("a heredoc on stdin is the prompt", () => {
    const command = [
      "codex exec --sandbox read-only -c 'model=\"gpt-6-astra\"' - <<'EOF' > /tmp/out.txt",
      "# Review PR 24977",
      "Read the diff and say SHIP or FIX.",
      "EOF",
      "cat /tmp/out.txt",
    ].join("\n");
    const run = agentRun(command);
    expect(run?.model).toBe("gpt-6-astra");
    expect(run?.prompt).toBe("# Review PR 24977\nRead the diff and say SHIP or FIX.");
    expect(promptTitle(run?.prompt)).toBe("Review PR 24977");
  });

  test("a nohup sh -c inside reach, its stdin from a pipe", () => {
    const command = `{ echo "Do not read files."; cat review.txt; } | reach cmux16 'mkdir -p /tmp/r && cat > /tmp/r/prompt.txt && cd /tmp/r && nohup sh -c "codex exec --sandbox read-only -m gpt-6-astra -c model_reasoning_effort=xhigh --skip-git-repo-check - < prompt.txt > out.txt 2>&1" &'`;
    expect(agentRun(command)).toEqual({ harness: "codex", model: "gpt-6-astra", effort: "xhigh", host: "cmux16" });
  });

  test("acpmux runs name their harness, model, effort, session and host", () => {
    expect(
      agentRun(
        "timeout 120 acpmux new -n wn-review-24143 -m codex -e xhigh --policy approve-reads --cwd /tmp/wn --prompt-file /tmp/wn/review-prompt.md -d --stall 0 --json 2>&1 | tail -3",
      ),
    ).toEqual({ harness: "codex", effort: "xhigh", session: "wn-review-24143" });
    expect(agentRun(`acpmux run -m claude-sr2/opus --host big-red "Review #24977"`)).toEqual({
      harness: "claude-sr2",
      model: "opus",
      host: "big-red",
      prompt: "Review #24977",
    });
    // A sub-session of a chat (#25019), whose state and result that chat's log records.
    expect(agentRun(`acpmux run --parent 01a1-parent -m codex -n fix "Fix the flaky test"`)).toEqual({
      harness: "codex",
      session: "fix",
      prompt: "Fix the flaky test",
      parent: "01a1-parent",
    });
    expect(agentRun(`acpmux new --parent=p1 -m codex "Go"`)?.parent).toBe("p1");
    expect(agentRun(`sr codex exec -m gpt-6-astra "hi"`)?.harness).toBe("codex");
    // Attached short options, env's split string, and a prompt after `--`.
    expect(agentRun(`acpmux run -mclaude/opus -exhigh "Go"`)).toEqual({
      harness: "claude",
      model: "opus",
      effort: "xhigh",
      prompt: "Go",
    });
    expect(agentRun(`env -S 'codex exec -mgpt-6 "Look"'`)).toEqual({
      harness: "codex",
      model: "gpt-6",
      prompt: "Look",
    });
    expect(agentRun(`codex exec -- --help`)?.prompt).toBe("--help");
    expect(agentRun(`perl -e 'alarm 1; exec @ARGV' -- codex exec "x"`)?.prompt).toBe("x");
    expect(agentRun(`exec -a worker codex exec "x"`)?.prompt).toBe("x");
    expect(agentRun(`/usr/bin/time -o /tmp/t codex exec "x"`)?.prompt).toBe("x");
    expect(agentRun(`perl -e'alarm 1; exec @ARGV' codex exec "x"`)?.prompt).toBe("x");
    expect(agentRun(`perl -we 'alarm 1; exec @ARGV' codex exec "x"`)?.prompt).toBe("x");
    expect(agentRun(`f() { echo hi; }; codex exec "x"`)?.prompt).toBe("x");
    expect(agentRun(`bash -o pipefail -lc 'codex exec "x"'`)?.prompt).toBe("x");
    expect(agentRun(`env --split-string='codex exec "Look"'`)?.prompt).toBe("Look");
    expect(agentRun(`acpmux run -m codex -- --parent`)?.prompt).toBe("--parent");
    expect(agentRun(`claude -p --model opus "Summarize the log"`)).toEqual({
      harness: "claude",
      model: "opus",
      prompt: "Summarize the log",
    });
  });

  test("commands that only mention an agent start none", () => {
    for (const command of [
      `grep -n "codex exec" notes.md`,
      `codex exec --help 2>&1 | grep -E "sandbox|model"`,
      `pgrep -fl 'codex exec|acpmux run' | cut -c1-150`,
      `echo "- relay: acpmux new --group --host refusal" >> lanes/coord.md`,
      `cat >> notes.md <<'EOF'\nRun codex exec -m gpt-6 "x" for reviews.\nEOF`,
      `acpmux send --no-wait big-red/hb-acpmux "codex exec runs"`,
      `acpmux new -n idle-lane -d`,
      `acpmux session stop review; which codex; codex --version`,
      `claude mcp list`,
      `command -v codex exec`,
      `command -p -v codex exec`,
      `env -- -S codex exec`,
      `env echo -S codex exec`,
      `env -S 'echo ok; codex exec'`,
      `nohup A=1 codex exec`,
      `${"exec ".repeat(40)}codex exec "deep"`,
      `perl -e 'print "exec @ARGV"' codex exec "text"`,
      `sh build.sh -c 'codex exec "x"'`,
      `perl tool.pl -e 'alarm 1; exec @ARGV' codex exec "x"`,
      `env -S 'echo ok; codex exec' codex exec "x"`,
      `f() { codex exec "x"; }`,
      `function g { codex exec "x"; }`,
      `review() (codex exec "x")`,
      `args=(codex exec "x")`,
      `f() { printf '}'; codex exec "x"; }`,
    ])
      expect(agentRun(command)).toBeUndefined();
  });
});

describe("simpleCommands", () => {
  test("lists, pipes, groups and quotes", () => {
    expect(simpleCommands(`a 'b c' "d\\"e" f\\ g && { h | i; } || (j) # k`).map((c) => c.argv)).toEqual([
      ["a", "b c", 'd"e', "f g"],
      ["h"],
      ["i"],
      ["j"],
    ]);
    expect(simpleCommands(`x "$(printf '%s' "a b")" 2>&1 >/dev/null`).map((c) => c.argv)).toEqual([
      ["x", `$(printf '%s' "a b")`],
    ]);
  });
});

describe("what the card shows", () => {
  test("Codex's final message after its log", () => {
    const output = "hook: Stop\nhook: Stop Completed\ntokens used\n6,624\nOK\nShell cwd was reset to /Users/x\n";
    expect(runReply(output)).toBe("OK");
    expect(runReply("VERDICT: SHIP\n")).toBe("VERDICT: SHIP");
    expect(runReply("  \n")).toBeUndefined();
  });

  test("model and effort, the background output file", () => {
    expect(runModel({ model: "gpt-6-astra", effort: "xhigh" })).toBe("gpt-6-astra xhigh");
    expect(runModel({})).toBeUndefined();
    expect(
      backgroundOutputPath(
        "Command running in background with ID: bciav1e7r. Output is being written to: /tmp/claude-501/x/tasks/bciav1e7r.output. You will be notified when it completes.",
      ),
    ).toBe("/tmp/claude-501/x/tasks/bciav1e7r.output");
  });
});
