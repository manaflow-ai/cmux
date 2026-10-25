// l10n-allow-file: test fixtures (command lines and messages).
// Shell calls that send another agent a message with `acpmux send` (acpmuxSends.ts), read from the
// command line as a shell reads it, through the wrappers agents put around it.
import { describe, expect, test } from "bun:test";
import type { AcpmuxActivity } from "../model";
import { acpmuxSend, acpmuxSendCall, shellCommands } from "./acpmuxSends";
import { sendLabel } from "../inspector/processes";
import type { Translate } from "../i18n";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

describe("acpmuxSend", () => {
  test("a plain send: its target and its prompt words", () => {
    expect(acpmuxSend("acpmux send coord-deputy 'Merged #22793. The review passed.'")).toEqual({
      target: "coord-deputy",
      text: "Merged #22793. The review passed.",
      noWait: false,
    });
    // Several prompt words are one prompt, joined by spaces, as clap collects them.
    expect(acpmuxSend("acpmux send lane hello there")?.text).toBe("hello there");
  });

  test("options before, between and after the words, per acpmux send --help", () => {
    expect(
      acpmuxSend(
        "acpmux send --no-wait --steer --from palette-audit --prompt-id 01a15c51 --timeout=30 claude-sr2 'done' --json",
      ),
    ).toEqual({ target: "claude-sr2", text: "done", noWait: true });
    expect(acpmuxSend("acpmux send -q --on-permission deny --stall 0 --supersede k lane -- --not-a-flag")?.text).toBe(
      "--not-a-flag",
    );
    // A delivery's state, and help, send nothing.
    expect(acpmuxSend("acpmux send --status 01a2b3")).toBeUndefined();
    expect(acpmuxSend("acpmux send --help")).toBeUndefined();
    expect(acpmuxSend("acpmux send -h")).toBeUndefined();
    // No session, no send to name.
    expect(acpmuxSend("acpmux send")).toBeUndefined();
  });

  test("target forms are the word as given, never looked up", () => {
    for (const target of ["tests", "huge-blue/lane-7", "cmux16:scroll-jitter", "reports:leo"])
      expect(acpmuxSend(`acpmux send --no-wait ${target} hi`)?.target).toBe(target);
  });

  test("quoting: single, double with escapes, $'…', backslashes, an apostrophe spliced in", () => {
    expect(acpmuxSend(`acpmux send x "say \\"hi\\" for \\$5"`)?.text).toBe('say "hi" for $5');
    expect(acpmuxSend("acpmux send x $'line one\\nline two'")?.text).toBe("line one\nline two");
    expect(acpmuxSend("acpmux send x it\\'s\\ fine")?.text).toBe("it's fine");
    expect(acpmuxSend(`acpmux send x 'it'"'"'s done; and | more'`)?.text).toBe("it's done; and | more");
    // A newline inside quotes is part of the message.
    expect(acpmuxSend("acpmux send x 'first\n\nsecond'")?.text).toBe("first\n\nsecond");
  });

  test("an expansion in the prompt leaves the text unknown; in the session, no send", () => {
    expect(acpmuxSend(`acpmux send --no-wait lane "$(cat /tmp/report.md)"`)).toEqual({ target: "lane", noWait: true });
    expect(acpmuxSend('acpmux send lane "PR $PR merged"')).toEqual({ target: "lane", noWait: false });
    expect(acpmuxSend("acpmux send lane `cat x`")).toEqual({ target: "lane", noWait: false });
    expect(acpmuxSend('acpmux send "$LANE" hi')).toBeUndefined();
    // A `$` that expands nothing is a dollar sign.
    expect(acpmuxSend("acpmux send lane 'costs $5' and $")?.text).toBe("costs $5 and $");
    // A glob or a brace expansion is not the word as typed.
    expect(acpmuxSend("acpmux send lane {ready,done}")).toEqual({ target: "lane", noWait: false });
    expect(acpmuxSend("acpmux send lane are you done?")).toEqual({ target: "lane", noWait: false });
    expect(acpmuxSend("acpmux send lane 'done?' '{a,b}'")?.text).toBe("done? {a,b}");
    expect(acpmuxSend("acpmux send lane ~/report")).toEqual({ target: "lane", noWait: false });
    // An unclosed quote is a line the shell refuses.
    expect(acpmuxSend("acpmux send lane 'message")).toBeUndefined();
    expect(acpmuxSend('acpmux send lane "message')).toBeUndefined();
    expect(acpmuxSend("acpmux send lane $(cat note.md")).toBeUndefined();
    expect(acpmuxSend("acpmux send lane `cat note.md")).toBeUndefined();
    expect(acpmuxSend('acpmux send lane "${V:-x"')).toBeUndefined();
    // An escape `$'…'` is not read here leaves the text unknown.
    expect(acpmuxSend("acpmux send lane $'\\x41'")).toEqual({ target: "lane", noWait: false });
  });

  test("stdin: a here-document, a here-string, a piped echo; a file or nothing is unknown", () => {
    const heredoc = [
      "acpmux send --no-wait coord-deputy - <<'EOF'",
      "## Merged #23091",
      "",
      "It's in; `$HOME` stays as typed.",
      "EOF",
    ].join("\n");
    expect(acpmuxSend(heredoc)).toEqual({
      target: "coord-deputy",
      text: "## Merged #23091\n\nIt's in; `$HOME` stays as typed.\n",
      noWait: true,
    });
    // An unquoted delimiter expands its body: unknown when it holds an expansion.
    expect(acpmuxSend("acpmux send lane <<EOF\nPR $N\nEOF")?.text).toBeUndefined();
    expect(acpmuxSend("acpmux send lane <<-EOF\n\tplain\n\tEOF")?.text).toBe("plain\n");
    expect(acpmuxSend("acpmux send lane <<< 'from a here-string'")?.text).toBe("from a here-string\n");
    expect(acpmuxSend("echo -n 'piped in' | acpmux send lane -")?.text).toBe("piped in");
    expect(acpmuxSend("printf 'piped\\nin' | acpmux send lane -")?.text).toBe("piped\nin");
    // A format that formats something: the text is its arguments, not read here.
    expect(acpmuxSend("printf '%s' world | acpmux send lane -")).toEqual({ target: "lane", noWait: false });
    // An escape echo may turn into a character (zsh, bash -e) is not read as typed.
    expect(acpmuxSend("echo -e 'a\\nb' | acpmux send lane -")).toEqual({ target: "lane", noWait: false });
    expect(acpmuxSend("cat <<'EOF' | acpmux send lane\nvia cat\nEOF")?.text).toBe("via cat\n");
    expect(acpmuxSend("acpmux send lane - < /tmp/note.md")).toEqual({ target: "lane", noWait: false });
    expect(acpmuxSend("acpmux send lane")).toEqual({ target: "lane", noWait: false });
  });

  test("wrappers: timeout, env, assignments, cd, perl alarm, nohup, bash -c, reach", () => {
    expect(acpmuxSend("timeout 100 acpmux send --no-wait coord-deputy 'blocked'")?.target).toBe("coord-deputy");
    expect(acpmuxSend("timeout -s KILL 5m acpmux send a b")?.text).toBe("b");
    expect(acpmuxSend("env ACPMUX_HOST=x NO_COLOR=1 acpmux send a b")?.target).toBe("a");
    expect(acpmuxSend("ACPMUX_SOCK=/tmp/s acpmux send a b")?.target).toBe("a");
    expect(acpmuxSend("cd ~/Projects/cmux && acpmux send a 'from the repo'")?.text).toBe("from the repo");
    expect(acpmuxSend(`perl -e 'alarm 60; exec @ARGV' acpmux send --no-wait a "in time"`)?.text).toBe("in time");
    expect(acpmuxSend("nohup /usr/local/bin/acpmux send a b")?.target).toBe("a");
    expect(acpmuxSend(`bash -lc 'acpmux send a "nested quotes"'`)?.text).toBe("nested quotes");
    expect(acpmuxSend("cmux acp send --no-wait a 'through cmux'")?.text).toBe("through cmux");
    // Through reach, the session is on that host unless it names its own.
    expect(acpmuxSend(`reach huge-blue 'acpmux send --no-wait lane-7 "rebased"'`)).toEqual({
      target: "huge-blue/lane-7",
      text: "rebased",
      noWait: true,
    });
    expect(acpmuxSend("reach --timeout 20 cmux16 acpmux send reports:leo done")?.target).toBe("reports:leo");
    expect(acpmuxSend(`reach cmux16 'timeout 30 perl -e "alarm 30; exec @ARGV" acpmux send x "deep"'`)).toMatchObject({
      target: "cmux16/x",
      text: "deep",
    });
  });

  test("output plumbing and reporting are not other work; other work is", () => {
    expect(acpmuxSend("acpmux send --no-wait a 'b' 2>&1 | tail -1")?.text).toBe("b");
    expect(acpmuxSend("acpmux send --no-wait a 'b' >/dev/null && echo sent || true")?.text).toBe("b");
    // A comment is not a command.
    expect(acpmuxSend("# report back\nacpmux send a b")?.text).toBe("b");
    expect(acpmuxSend("git push && acpmux send a 'pushed'")).toBeUndefined();
    expect(acpmuxSend("acpmux send a b; nohup glaeda-gh wait pr x#1 &")).toBeUndefined();
    // `tail` that is not reading the send's output is other work.
    expect(acpmuxSend("tail -1 log.txt; acpmux send a b")).toBeUndefined();
    // Two sends are two messages: the command row keeps both, one in a substitution too.
    expect(acpmuxSend("acpmux send a x; acpmux send b y")).toBeUndefined();
    expect(acpmuxSend('acpmux send x "$(acpmux send y z)"')).toBeUndefined();
    // A substitution that does more than read is work, wherever it is.
    expect(acpmuxSend('echo "$(touch /tmp/x)" | acpmux send a -')).toBeUndefined();
    expect(acpmuxSend("cd `mktemp -d` && acpmux send a b")).toBeUndefined();
    expect(acpmuxSend("acpmux send a <<EOF\n$(rm -f x)\nEOF")).toBeUndefined();
    expect(acpmuxSend('acpmux send target "${V:-$(rm -f /tmp/x)}"')).toBeUndefined();
    expect(acpmuxSend('acpmux send target "${V:-x}"')).toEqual({ target: "target", noWait: false });
    expect(acpmuxSend('acpmux send a "$(cat note.md | head -5)"')).toEqual({ target: "a", noWait: false });
    // A redirect that writes a file is work, on its own or on the send.
    expect(acpmuxSend("> /tmp/out && acpmux send a b")).toBeUndefined();
    expect(acpmuxSend("acpmux send a b; > /tmp/out")).toBeUndefined();
    expect(acpmuxSend("acpmux send a b > /tmp/out")).toBeUndefined();
    expect(acpmuxSend("acpmux send a b 2>&1 >/dev/null")?.text).toBe("b");
    // A filter that writes or reads a file of its own is work.
    expect(acpmuxSend("acpmux send a b | tee /tmp/out")).toBeUndefined();
    expect(acpmuxSend("acpmux send a b | tail -1 log.txt")).toBeUndefined();
    expect(acpmuxSend("acpmux send a b | sed -n 1p")).toBeUndefined();
    expect(acpmuxSend("acpmux send x y | grep -f secret")).toBeUndefined();
    expect(acpmuxSend("acpmux send x y | grep -r x")).toBeUndefined();
    expect(acpmuxSend("acpmux send x y | tr -d x file")).toBeUndefined();
    expect(acpmuxSend("acpmux send x y | jq --rawfile f secret .")).toBeUndefined();
    expect(acpmuxSend("acpmux send x y | grep -c queued")?.text).toBe("y");
    expect(acpmuxSend("acpmux send --json a b | jq -r .text | head -n 3")?.text).toBe("b");
  });

  test("only a command in command position: not an echoed or quoted mention, not another subcommand", () => {
    expect(acpmuxSend('echo "acpmux send x y"')).toBeUndefined();
    expect(acpmuxSend("grep -n 'acpmux send' notes.md")).toBeUndefined();
    expect(acpmuxSend("acpmux ls")).toBeUndefined();
    expect(acpmuxSend("acpmux sessions send x")).toBeUndefined();
    expect(acpmuxSend("acpmux dispatch --brief b.md --target auto")).toBeUndefined();
    expect(acpmuxSend("cat <<'EOF' > note.md\nacpmux send x y\nEOF")).toBeUndefined();
    expect(acpmuxSend("cmux send --surface s 'hi'")).toBeUndefined();
    // An option acpmux does not know, a value on a flag, or both --steer and --no-steer fail the call.
    expect(acpmuxSend("acpmux send --bogus value target text")).toBeUndefined();
    expect(acpmuxSend("acpmux send --no-wait=true a b")).toBeUndefined();
    expect(acpmuxSend("acpmux send --steer --no-steer a b")).toBeUndefined();
    expect(acpmuxSend("acpmux send --steer --steer a b")?.text).toBe("b");
    // reach's own commands (help, list, …) run no command.
    expect(acpmuxSend("reach --help host acpmux send x y")).toBeUndefined();
    expect(acpmuxSend("reach --list host acpmux send x y")).toBeUndefined();
    expect(acpmuxSend("reach --timeout 20 --help acpmux send x y")).toBeUndefined();
    // A wrapper's option that does not run the command (help, env -S) is not looked through.
    expect(acpmuxSend("timeout --help 10 acpmux send x y")).toBeUndefined();
    expect(acpmuxSend("env -S 'acpmux send x y'")).toBeUndefined();
    expect(acpmuxSend("nohup --version acpmux send x y")).toBeUndefined();
    expect(acpmuxSend("timeout --signal=KILL --foreground 10 env -i acpmux send x y")?.text).toBe("y");
    // Nothing after `exit` runs.
    expect(acpmuxSend("exit 0; acpmux send x y")).toBeUndefined();
    // Words a property of Object shares are no runner and no filter.
    expect(acpmuxSend("toString acpmux send x y")).toBeUndefined();
    expect(acpmuxSend("acpmux send x y | constructor")).toBeUndefined();
    // `-c` after an operand is the script's argument; a timeout that is no duration runs nothing.
    expect(acpmuxSend("bash script -c 'acpmux send x y'")).toBeUndefined();
    expect(acpmuxSend("timeout abc acpmux send x y")).toBeUndefined();
    // Values clap rejects fail the call; a number after a filter's operand is a file.
    expect(acpmuxSend("acpmux send --timeout=abc lane hi")).toBeUndefined();
    expect(acpmuxSend("acpmux send --stall soon lane hi")).toBeUndefined();
    expect(acpmuxSend("acpmux send --on-permission maybe lane hi")).toBeUndefined();
    expect(acpmuxSend("acpmux send --prompt-id --no-wait lane hi")).toBeUndefined();
    expect(acpmuxSend("timeout --signal --foreground 10 acpmux send lane hi")).toBeUndefined();
    expect(acpmuxSend("acpmux send a b | grep foo 5")).toBeUndefined();
    expect(acpmuxSend("acpmux send a b | grep -m 1 foo")?.text).toBe("b");
    expect(acpmuxSend("acpmux send x y | tail -1 < /tmp/log")).toBeUndefined();
    // A perl script that is not exactly `alarm N; exec @ARGV` is not looked through.
    expect(acpmuxSend(`perl -e 'print "exec @ARGV"' acpmux send a b`)).toBeUndefined();
    expect(acpmuxSend(`perl -e 'exec @ARGV' acpmux send a b`)).toBeUndefined();
  });

  test("acpmux's own flags may come before send", () => {
    expect(acpmuxSend("acpmux --json send lane hi")).toEqual({ target: "lane", text: "hi", noWait: false });
    expect(acpmuxSend("acpmux --suppress-reads --json send --no-wait lane hi")?.noWait).toBe(true);
  });

  test("a long pipeline after the send, and many here-documents, are one pass", () => {
    const started = performance.now();
    expect(acpmuxSend(`acpmux send a b${" | cat".repeat(5000)}`)?.text).toBe("b");
    const docs = `${"cat <<E; ".repeat(5000)}\n${"E\n".repeat(5000)}acpmux send a b`;
    expect(shellCommands(docs)).toHaveLength(5001);
    expect(performance.now() - started).toBeLessThan(1000);
  });
});

describe("shellCommands", () => {
  test("operators split commands; redirects and here-documents are not words", () => {
    const commands = shellCommands("a 1 2>&1 | b && c || d; e & f\ng <<X\nbody\nX\nh");
    expect(commands.map((command) => [command.words.map((word) => word.text).join(" "), command.op])).toEqual([
      ["a 1", "|"],
      ["b", "&&"],
      ["c", "||"],
      ["d", ";"],
      ["e", "&"],
      ["f", ";"],
      ["g", ";"],
      ["h", ""],
    ]);
    expect(commands[6]!.stdin).toEqual({ text: "body\n", literal: true });
  });

  test("a redirect that writes a file, and the scripts substitutions run", () => {
    const [send, copy] = shellCommands('x "$(cat a)" `pwd` 2>&1 >/dev/null; > out');
    expect(send!.writes).toBeUndefined();
    expect(send!.runs).toEqual(["cat a", "pwd"]);
    expect(copy).toEqual({ words: [], op: "", writes: true });
  });

  test("a substitution keeps its operators inside its word", () => {
    const [command] = shellCommands('x "$(a | b; c)" `d && e`');
    expect(command!.words.map((word) => word.literal)).toEqual([true, false, false]);
    expect(shellCommands('x "$(a | b; c)"')).toHaveLength(1);
  });
});

describe("acpmuxSendCall", () => {
  const bash = (command: string, fields: Partial<Tool> = {}): Tool => ({
    id: "toolu_1",
    title: command.slice(0, 120),
    kind: "execute",
    status: "completed",
    command,
    description: "Report merge to coord-deputy",
    ...fields,
  });

  test("its state: running, sent, or failed on a nonzero exit", () => {
    const line = "acpmux send --no-wait coord-deputy 'Merged.' 2>&1 | tail -1";
    expect(acpmuxSendCall(bash(line, { status: "in_progress" }))?.state).toBe("sending");
    expect(acpmuxSendCall(bash(line, { output: "queued" }))?.state).toBe("sent");
    expect(acpmuxSendCall(bash(line, { status: "failed", output: "Exit code 4\nacpmux: no_session" }))?.state).toBe(
      "failed",
    );
    expect(acpmuxSendCall(bash(line, { exitCode: 4 }))?.state).toBe("failed");
    // Not a shell call.
    expect(acpmuxSendCall({ ...bash(line), kind: "other" })).toBeUndefined();
    // Moved to the background: running there, then how it ended there.
    expect(acpmuxSendCall(bash(line, { background: { state: "running" } }))?.state).toBe("sending");
    expect(acpmuxSendCall(bash(line, { background: { state: "failed" } }))?.state).toBe("failed");
    expect(acpmuxSendCall(bash(line, { background: { state: "completed" } }))?.state).toBe("sent");
    expect(acpmuxSendCall(bash(line, { status: "in_progress", background: { state: "stopped" } }))?.state).toBe(
      "failed",
    );
  });
});

test("Background tasks and the tray name a background send as its row does", () => {
  const t = ((key: string, values: { target: string }) => `${key}:${values.target}`) as unknown as Translate;
  const command = "timeout 100 acpmux send --no-wait huge-blue/lane 'hi'";
  expect(sendLabel(t, { command, state: "running" })).toBe("send.sending:huge-blue/lane");
  expect(sendLabel(t, { command, state: "completed" })).toBe("send.sent:huge-blue/lane");
  expect(sendLabel(t, { command, state: "failed" })).toBe("send.failed:huge-blue/lane");
  expect(sendLabel(t, { command: "bun test", state: "running" })).toBeUndefined();
  // Stopped: whether it went is not known.
  expect(sendLabel(t, { command, state: "stopped" })).toBeUndefined();
});
