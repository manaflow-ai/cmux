// l10n-allow-file: test fixtures (command lines and messages).
// Shell calls that send another agent a message with `acpmux send` (acpmuxSends.ts), read from the
// command line as a shell reads it, through the wrappers agents put around it.
import { describe, expect, test } from "bun:test";
import type { AcpmuxActivity } from "../model";
import { acpmuxSend, acpmuxSendCall, recordedMessageBodyChanges, shellCommands } from "./acpmuxSends";
import { sendLabel } from "../session-info/processes";
import type { Translate } from "../i18n";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// The send a line makes, without whether it owns the call's exit status or surely ran (tested below).
function read(line: string) {
  const send = acpmuxSend(line);
  if (!send) return send;
  const { ownsExit: _, unsure: __, ...rest } = send;
  return rest;
}

describe("acpmuxSend", () => {
  test("a plain send: its target and its prompt words", () => {
    expect(read("acpmux send coord-deputy 'Merged #22793. The review passed.'")).toEqual({
      target: "coord-deputy",
      text: "Merged #22793. The review passed.",
      noWait: false,
    });
    // Several prompt words are one prompt, joined by spaces, as clap collects them.
    expect(read("acpmux send lane hello there")?.text).toBe("hello there");
  });

  test("options before, between and after the words, per acpmux send --help", () => {
    expect(
      read(
        "acpmux send --no-wait --steer --from palette-audit --prompt-id 01a15c51 --timeout=30 claude-sr2 'done' --json",
      ),
    ).toEqual({ target: "claude-sr2", text: "done", noWait: true });
    expect(read("acpmux send -q --on-permission deny --stall 0 --supersede k lane -- --not-a-flag")?.text).toBe(
      "--not-a-flag",
    );
    // A delivery's state, and help, send nothing.
    expect(read("acpmux send --status 01a2b3")).toBeUndefined();
    expect(read("acpmux send --help")).toBeUndefined();
    expect(read("acpmux send -h")).toBeUndefined();
    // No session, no send to name.
    expect(read("acpmux send")).toBeUndefined();
  });

  test("target forms are the word as given, never looked up", () => {
    for (const target of ["tests", "huge-blue/lane-7", "cmux16:scroll-jitter", "reports:leo"])
      expect(read(`acpmux send --no-wait ${target} hi`)?.target).toBe(target);
  });

  test("quoting: single, double with escapes, $'…', backslashes, an apostrophe spliced in", () => {
    expect(read(`acpmux send x "say \\"hi\\" for \\$5"`)?.text).toBe('say "hi" for $5');
    expect(read("acpmux send x $'line one\\nline two'")?.text).toBe("line one\nline two");
    expect(read("acpmux send x it\\'s\\ fine")?.text).toBe("it's fine");
    expect(read(`acpmux send x 'it'"'"'s done; and | more'`)?.text).toBe("it's done; and | more");
    // A newline inside quotes is part of the message.
    expect(read("acpmux send x 'first\n\nsecond'")?.text).toBe("first\n\nsecond");
  });

  test("an expansion in the prompt leaves the text unknown; in the session, no send", () => {
    // The file it reads is named, so the row can say where the words came from.
    expect(read(`acpmux send --no-wait lane "$(cat /tmp/report.md)"`)).toEqual({
      target: "lane",
      file: "/tmp/report.md",
      noWait: true,
    });
    expect(read('acpmux send lane "PR $PR merged"')).toEqual({ target: "lane", noWait: false });
    expect(read("acpmux send lane `cat x`")).toEqual({ target: "lane", noWait: false });
    expect(read('acpmux send "$LANE" hi')).toBeUndefined();
    // A `$` that expands nothing is a dollar sign.
    expect(read("acpmux send lane 'costs $5' and $")?.text).toBe("costs $5 and $");
    // A glob or a brace expansion is not the word as typed.
    expect(read("acpmux send lane {ready,done}")).toEqual({ target: "lane", noWait: false });
    expect(read("acpmux send lane are you done?")).toEqual({ target: "lane", noWait: false });
    expect(read("acpmux send lane 'done?' '{a,b}'")?.text).toBe("done? {a,b}");
    expect(read("acpmux send lane ~/report")).toEqual({ target: "lane", noWait: false });
    // An unclosed quote is a line the shell refuses.
    expect(read("acpmux send lane 'message")).toBeUndefined();
    expect(read('acpmux send lane "message')).toBeUndefined();
    expect(read("acpmux send lane $(cat note.md")).toBeUndefined();
    expect(read("acpmux send lane `cat note.md")).toBeUndefined();
    expect(read('acpmux send lane "${V:-x"')).toBeUndefined();
    // An escape `$'…'` is not read here leaves the text unknown.
    expect(read("acpmux send lane $'\\x41'")).toEqual({ target: "lane", noWait: false });
  });

  test("stdin: a here-document, a here-string, a piped echo; a file or nothing is unknown", () => {
    const heredoc = [
      "acpmux send --no-wait coord-deputy - <<'EOF'",
      "## Merged #23091",
      "",
      "It's in; `$HOME` stays as typed.",
      "EOF",
    ].join("\n");
    expect(read(heredoc)).toEqual({
      target: "coord-deputy",
      text: "## Merged #23091\n\nIt's in; `$HOME` stays as typed.\n",
      noWait: true,
    });
    // An unquoted delimiter expands its body: unknown when it holds an expansion.
    expect(read("acpmux send lane <<EOF\nPR $N\nEOF")?.text).toBeUndefined();
    expect(read("acpmux send lane <<-EOF\n\tplain\n\tEOF")?.text).toBe("plain\n");
    expect(read("acpmux send lane <<< 'from a here-string'")?.text).toBe("from a here-string\n");
    expect(read("echo -n 'piped in' | acpmux send lane -")?.text).toBe("piped in");
    expect(read("(echo hi) | acpmux send lane -")?.text).toBe("hi");
    expect(read("printf 'piped\\nin' | acpmux send lane -")?.text).toBe("piped\nin");
    // A format that formats something: the text is its arguments, not read here.
    expect(read("printf '%s' world | acpmux send lane -")).toEqual({ target: "lane", noWait: false });
    // An escape echo may turn into a character (zsh, bash -e) is not read as typed.
    expect(read("echo -e 'a\\nb' | acpmux send lane -")).toEqual({ target: "lane", noWait: false });
    expect(read("cat <<'EOF' | acpmux send lane\nvia cat\nEOF")?.text).toBe("via cat\n");
    expect(read("acpmux send lane - < /tmp/note.md")).toEqual({ target: "lane", file: "/tmp/note.md", noWait: false });
    // A same-turn literal write is safe to display without reading the filesystem. The writer is
    // still counted as other work, and a later unrelated command cannot provide its body.
    expect(
      read("cat > /tmp/message.md <<'EOF'\n# Review\n\n- pass\nEOF\nacpmux send --no-wait lane - < /tmp/message.md"),
    ).toEqual({ target: "lane", file: "/tmp/message.md", noWait: true, others: 1 });
    expect(read("acpmux send lane - < /tmp/message.md")).toEqual({
      target: "lane",
      file: "/tmp/message.md",
      noWait: false,
    });
    // The last stdin redirect wins; a writer whose stdout goes elsewhere feeds nothing.
    expect(read("acpmux send lane - <<EOF < /tmp/message\nbody\nEOF")).toEqual({ target: "lane", noWait: false });
    expect(
      acpmuxSend(
        "acpmux send lane - <<EOF < /tmp/message\nbody\nEOF",
        undefined,
        0,
        new Map([["/tmp/message", "stale\n"]]),
      )?.text,
    ).toBeUndefined();
    expect(read("acpmux send lane - < /tmp/message <<EOF\nbody\nEOF")?.text).toBe("body\n");
    expect(read("echo secret >/dev/null | acpmux send lane -")).toEqual({ target: "lane", noWait: false });
    expect(read("echo shown 2>/dev/null | acpmux send lane -")?.text).toBe("shown");
    // A non-zero-fd here-document is not the producer's stdin, even when it is piped onward.
    expect(read("cat 1<<'EOF' | acpmux send lane -\nwrong fd\nEOF")?.text).toBeUndefined();
    expect(read("cat 3<<<'wrong fd' | acpmux send lane -")?.text).toBeUndefined();
    expect(read("acpmux send lane - <<'EOF' 0<&-\nclosed\nEOF")).toEqual({ target: "lane", noWait: false });
    expect(read("acpmux send lane - <<EOF <<<NEW\nOLD\nEOF")).toEqual({ target: "lane", noWait: false });
    expect(read("acpmux send lane - <<$'\\x45OF'\nSECRET\nEOF")).toEqual({ target: "lane", noWait: false });
    // A later independent command runs after the send has opened stdin and cannot erase its text.
    expect(read("acpmux send lane 'hello'; printf done > /tmp/log")).toEqual({
      target: "lane",
      text: "hello",
      noWait: false,
      others: 1,
    });
    expect(read("acpmux send lane")).toEqual({ target: "lane", noWait: false });
  });

  test("wrappers: timeout, env, assignments, cd, perl alarm, nohup, bash -c, reach", () => {
    expect(read("timeout 100 acpmux send --no-wait coord-deputy 'blocked'")?.target).toBe("coord-deputy");
    expect(read("timeout -s KILL 5m acpmux send a b")?.text).toBe("b");
    expect(read("env ACPMUX_HOST=x NO_COLOR=1 acpmux send a b")?.target).toBe("a");
    expect(read("ACPMUX_SOCK=/tmp/s acpmux send a b")?.target).toBe("a");
    expect(read("cd ~/Projects/cmux && acpmux send a 'from the repo'")?.text).toBe("from the repo");
    expect(read(`perl -e 'alarm 60; exec @ARGV' acpmux send --no-wait a "in time"`)?.text).toBe("in time");
    expect(read("nohup /usr/local/bin/acpmux send a b")?.target).toBe("a");
    expect(read(`bash -lc 'acpmux send a "nested quotes"'`)?.text).toBe("nested quotes");
    expect(read("cmux acp send --no-wait a 'through cmux'")?.text).toBe("through cmux");
    // Through reach, the session is on that host unless it names its own.
    expect(read(`reach huge-blue 'acpmux send --no-wait lane-7 "rebased"'`)).toEqual({
      target: "huge-blue/lane-7",
      text: "rebased",
      noWait: true,
    });
    expect(read("reach --timeout 20 cmux16 acpmux send reports:leo done")?.target).toBe("reports:leo");
    expect(read(`reach cmux16 'timeout 30 perl -e "alarm 30; exec @ARGV" acpmux send x "deep"'`)).toMatchObject({
      target: "cmux16/x",
      text: "deep",
    });
  });

  test("through ssh, as through reach: the session is on that host", () => {
    // ask-1b0c0b04de: a lane relayed to cmux16 by copying the message file there and running the
    // send over ssh; the pane drew it as a raw Shell block instead of a sent message.
    expect(read(`ssh cmux16 'acpmux send --no-wait lane-7 "rebased"'`)).toEqual({
      target: "cmux16/lane-7",
      text: "rebased",
      noWait: true,
    });
    expect(
      read(
        `scp -q /tmp/claude-sr2/m318.txt cmux16:/tmp/cx-lanes/ && ssh cmux16 'acpmux send --no-wait cx-lane "$(cat /tmp/cx-lanes/m318.txt)"'`,
      ),
    ).toEqual({ target: "cmux16/cx-lane", file: "/tmp/cx-lanes/m318.txt", noWait: true, others: 1 });
    // Options, a user and a port: the host is what names the machine.
    expect(read("ssh -o ConnectTimeout=5 -i ~/.ssh/fleet leoli@cmux16 acpmux send x hi")?.target).toBe("cmux16/x");
    expect(read("ssh -qtt -p22 ssh://me@box:2222 'acpmux send x hi'")?.target).toBe("box/x");
    expect(read("ssh -- box 'acpmux send x hi'")?.target).toBe("box/x");
    // A target that names its own host keeps it.
    expect(read("ssh box 'acpmux send hb/review ship'")?.target).toBe("hb/review");
    // -n points ssh's stdin at /dev/null: the here-string never reaches the send.
    expect(read("ssh box 'acpmux send x -' <<< 'local words'")?.text).toBe("local words\n");
    expect(read("ssh -n box 'acpmux send x -' <<< 'local words'")?.text).toBeUndefined();
    // Modes that run no command, a missing value, a host that is not literal: no send row.
    expect(read("ssh -N box acpmux send x y")).toBeUndefined();
    expect(read("ssh -G box acpmux send x y")).toBeUndefined();
    expect(read("ssh -O exit box acpmux send x y")).toBeUndefined();
    expect(read("ssh -s box acpmux send x y")).toBeUndefined();
    expect(read("ssh -p")).toBeUndefined();
    expect(read(`ssh "$HOST" 'acpmux send x y'`)).toBeUndefined();
    // Two sends, one over ssh, are two messages.
    expect(read("acpmux send a x; ssh box 'acpmux send b y'")).toBeUndefined();
    // ssh that runs no send leaves the local send alone, as other work.
    expect(read("ssh box 'df -h'; acpmux send a b")?.others).toBe(1);
  });

  test("output plumbing and reporting are not other work; other work is counted", () => {
    expect(read("acpmux send --no-wait a 'b' 2>&1 | tail -1")?.text).toBe("b");
    expect(read("acpmux send --no-wait a 'b' >/dev/null && echo sent || true")?.text).toBe("b");
    // A comment is not a command.
    expect(read("# report back\nacpmux send a b")?.text).toBe("b");
    expect(read("git push && acpmux send a 'pushed'")?.others).toBe(1);
    expect(read("acpmux send a b; nohup glaeda-gh wait pr x#1 &")?.others).toBe(1);
    // `tail` that is not reading the send's output is other work.
    expect(read("tail -1 log.txt; acpmux send a b")?.others).toBe(1);
    // Two sends are two messages: the command row keeps both, one in a substitution too.
    expect(read("acpmux send a x; acpmux send b y")).toBeUndefined();
    expect(read('acpmux send first hi; acpmux send "$SECOND" hi')).toBeUndefined();
    expect(read("acpmux send first hi; reach box 'acpmux send \"$X\" hi'")).toBeUndefined();
    expect(read('acpmux send x "$(acpmux send y z)"')).toBeUndefined();
    // A substitution that does more than read is work, wherever it is.
    expect(read('echo "$(touch /tmp/x)" | acpmux send a -')?.others).toBe(1);
    expect(read("cd `mktemp -d` && acpmux send a b")?.others).toBe(1);
    expect(read("acpmux send a <<EOF\n$(rm -f x)\nEOF")?.others).toBe(1);
    expect(read('acpmux send target "${V:-$(rm -f /tmp/x)}"')?.others).toBe(1);
    expect(read('acpmux send target "${V:-x}"')).toEqual({ target: "target", noWait: false });
    expect(read('acpmux send a "$(cat note.md | head -5)"')).toEqual({ target: "a", noWait: false });
    // A redirect that writes a file is work, on its own or on the send.
    expect(read("> /tmp/out && acpmux send a b")?.others).toBe(1);
    expect(read("acpmux send a b; > /tmp/out")?.others).toBe(1);
    expect(read("acpmux send a b > /tmp/out")?.others).toBe(1);
    expect(read("acpmux send a b 2>&1 >/dev/null")?.text).toBe("b");
    // A filter that writes or reads a file of its own is work.
    expect(read("acpmux send a b | tee /tmp/out")?.others).toBe(1);
    expect(read("acpmux send a b | tail -1 log.txt")?.others).toBe(1);
    expect(read("acpmux send a b | sed -n 1p")?.others).toBe(1);
    expect(read("acpmux send x y | grep -f secret")?.others).toBe(1);
    expect(read("acpmux send x y | grep -r x")?.others).toBe(1);
    expect(read("acpmux send x y | tr -d x file")?.others).toBe(1);
    expect(read("acpmux send x y | jq --rawfile f secret .")?.others).toBe(1);
    expect(read("acpmux send x y | grep -c queued")?.text).toBe("y");
    expect(read("acpmux send --json a b | jq -r .text | head -n 3")?.text).toBe("b");
  });

  test("only a command in command position: not an echoed or quoted mention, not another subcommand", () => {
    expect(read('echo "acpmux send x y"')).toBeUndefined();
    expect(read("grep -n 'acpmux send' notes.md")).toBeUndefined();
    expect(read("acpmux ls")).toBeUndefined();
    expect(read("acpmux sessions send x")).toBeUndefined();
    expect(read("acpmux dispatch --brief b.md --target auto")).toBeUndefined();
    expect(read("cat <<'EOF' > note.md\nacpmux send x y\nEOF")).toBeUndefined();
    expect(read("cmux send --surface s 'hi'")).toBeUndefined();
    // An option acpmux does not know, a value on a flag, or both --steer and --no-steer fail the call.
    expect(read("acpmux send --bogus value target text")).toBeUndefined();
    expect(read("acpmux send --no-wait=true a b")).toBeUndefined();
    expect(read("acpmux send --steer --no-steer a b")).toBeUndefined();
    expect(read("acpmux send --steer --steer a b")?.text).toBe("b");
    // reach's own commands (help, list, …) run no command.
    expect(read("reach --help host acpmux send x y")).toBeUndefined();
    expect(read("reach --list host acpmux send x y")).toBeUndefined();
    expect(read("reach --timeout 20 --help acpmux send x y")).toBeUndefined();
    expect(read("reach --timeout --help host acpmux send x y")).toBeUndefined();
    // A wrapper's option that does not run the command (help, env -S) is not looked through.
    expect(read("timeout --help 10 acpmux send x y")).toBeUndefined();
    expect(read("env -S 'acpmux send x y'")).toBeUndefined();
    expect(read("nohup --version acpmux send x y")).toBeUndefined();
    expect(read("timeout --signal=KILL --foreground 10 env -i acpmux send x y")?.text).toBe("y");
    // Nothing after `exit` runs.
    expect(read("exit 0; acpmux send x y")).toBeUndefined();
    // Words a property of Object shares are no runner and no filter.
    expect(read("toString acpmux send x y")).toBeUndefined();
    expect(read("acpmux send x y | constructor")?.others).toBe(1);
    // `-c` after an operand is the script's argument; a timeout that is no duration runs nothing.
    expect(read("bash script -c 'acpmux send x y'")).toBeUndefined();
    expect(read("timeout abc acpmux send x y")).toBeUndefined();
    // Values clap rejects fail the call; a number after a filter's operand is a file.
    expect(read("acpmux send --timeout=abc lane hi")).toBeUndefined();
    expect(read("acpmux send --stall soon lane hi")).toBeUndefined();
    expect(read("acpmux send --on-permission maybe lane hi")).toBeUndefined();
    expect(read("acpmux send --prompt-id --no-wait lane hi")).toBeUndefined();
    expect(read("timeout --signal --foreground 10 acpmux send lane hi")).toBeUndefined();
    expect(read("acpmux send a b | grep foo 5")?.others).toBe(1);
    expect(read("acpmux send a b | grep -m 1 foo")?.text).toBe("b");
    expect(read("acpmux send x y | tail -1 < /tmp/log")?.others).toBe(1);
    // A perl script that is not exactly `alarm N; exec @ARGV` is not looked through.
    expect(read(`perl -e 'print "exec @ARGV"' acpmux send a b`)).toBeUndefined();
    expect(read(`perl -e 'exec @ARGV' acpmux send a b`)).toBeUndefined();
  });

  test("nested wrappers count executable sends without counting quoted mentions", () => {
    for (const command of [`bash -c 'echo "acpmux send x y"'; acpmux send lane hi`]) {
      const send = read(command);
      expect(send?.target).toBe("lane");
      expect(send?.text).toBe("hi");
      expect(send?.others).toBe(1);
    }
    for (const command of [
      `bash -c 'acpmux send first hi'; acpmux send second hi`,
      `bash -c 'acpmux send first hi; acpmux send second hi'`,
      `bash -c 'echo "$(acpmux send hidden hi)"'; acpmux send second hi`,
      "bash -c 'cat <<EOF\n$(acpmux send hidden hi)\nEOF'; acpmux send second hi",
      `bash -c 'acpmux send "$FIRST" hi'; acpmux send second hi`,
      `reach box 'acpmux send "$FIRST" hi'; acpmux send second hi`,
      `bash -c "$SCRIPT"; acpmux send lane hi`,
      `reach "$HOST" 'acpmux send first hi'; acpmux send second hi`,
    ]) {
      try {
        expect(read(command)).toBeUndefined();
      } catch (error) {
        throw new Error(`${command}: ${String(error)}`);
      }
    }
  });

  test("a send anywhere in a compound command, with the other work counted", () => {
    expect(
      read(
        "cd ~/wt/base && git fetch -q origin && acpmux send --no-wait --from claude-sr2 coord-deputy 'Restore base first.'; reach studio-mac 'df -h'",
      ),
    ).toEqual({ target: "coord-deputy", text: "Restore base first.", noWait: true, others: 2 });
    // In a subshell, with a fallback that only reports.
    expect(read("(cd ~/wt && acpmux send lane done) || echo failed")).toEqual({
      target: "lane",
      text: "done",
      noWait: false,
    });
    // The text from a file on stdin: the target and the file.
    expect(read("acpmux send --no-wait --from net-retries coord-deputy - < /tmp/report.md")).toEqual({
      file: "/tmp/report.md",
      target: "coord-deputy",
      noWait: true,
    });
    expect(
      read("git push -q && acpmux send --no-wait --from net-retries coord-deputy - <<'EOF'\n## Pushed\nEOF"),
    ).toEqual({ target: "coord-deputy", text: "## Pushed\n", noWait: true, others: 1 });
    // Mentions are not sends, wherever they are.
    expect(read("acpmux ls; echo acpmux send")).toBeUndefined();
    // A shell that only checks the script runs nothing.
    expect(read("bash -n -c 'acpmux send lane hi'")).toBeUndefined();
    // A Unicode space is part of the word, as in the shell.
    expect(read("acpmux send lane hi\u00a0there")?.text).toBe("hi\u00a0there");
  });

  test("acpmux's own flags may come before send", () => {
    expect(read("acpmux --json send lane hi")).toEqual({ target: "lane", text: "hi", noWait: false });
    expect(read("acpmux --suppress-reads --json send --no-wait lane hi")?.noWait).toBe(true);
  });

  test("a long pipeline after the send, and many here-documents, are one pass", () => {
    const started = performance.now();
    expect(read(`acpmux send a b${" | cat".repeat(5000)}`)?.text).toBe("b");
    expect(read(`bash -c '${"cat | ".repeat(5000)}acpmux send a -' <<< 'forwarded'`)?.text).toBe("forwarded\n");
    const docs = `${"cat <<E; ".repeat(5000)}\n${"E\n".repeat(5000)}acpmux send a b`;
    expect(shellCommands(docs)).toHaveLength(5001);
    expect(performance.now() - started).toBeLessThan(1000);
  });

  test("recorded message producers fail closed around control flow and path mutators", () => {
    expect(recordedMessageBodyChanges("true || cat > /tmp/message <<'EOF'\nskipped\nEOF")).toEqual([{ reset: true }]);
    expect(recordedMessageBodyChanges("mv /tmp/other /tmp/message")).toEqual([{ reset: true }]);
    expect(recordedMessageBodyChanges("cat 2> /tmp/message <<'EOF'\nnot stdout\nEOF")).toEqual([{ reset: true }]);
    expect(recordedMessageBodyChanges("cat >> /tmp/message <<'EOF'\nappend\nEOF")).toEqual([{ reset: true }]);
    expect(recordedMessageBodyChanges("cat <> /tmp/message <<'EOF'\nread-write\nEOF")).toEqual([{ reset: true }]);
    expect(recordedMessageBodyChanges("cat > \"$MESSAGE\" <<'EOF'\ndynamic\nEOF")).toEqual([{ reset: true }]);
    expect(recordedMessageBodyChanges("cd /tmp")).toEqual([{ reset: true }]);
    expect(recordedMessageBodyChanges('python3 -c \'open("/tmp/message", "w").write("new")\'')).toEqual([
      { reset: true },
    ]);
    expect(recordedMessageBodyChanges("cat > /tmp/message 3<<'EOF'\nwrong fd\nEOF")).toEqual([{ reset: true }]);
    expect(recordedMessageBodyChanges("cat > /tmp/message <<EOF\nunquoted\nEOF")).toEqual([{ reset: true }]);
    expect(recordedMessageBodyChanges("cat > /tmp/message <<A <<B\nA\nOLD\nB\n")).toEqual([{ reset: true }]);
    expect(recordedMessageBodyChanges("cat > /tmp/message <<'EOF'\n\\\nEOF")).toEqual([
      { path: "/tmp/message", text: "\\\n" },
    ]);
    expect(read("acpmux send lane - 3<<<'SECRET'")).toEqual({ target: "lane", noWait: false });
    expect(read("acpmux send lane - 1<<'EOF'\nSECRET\nEOF")).toEqual({ target: "lane", noWait: false });
    expect(read("acpmux send lane - <<'EOF' 0>/tmp/out\nSECRET\nEOF")).toEqual({
      target: "lane",
      noWait: false,
      others: 1,
    });
    expect(read("acpmux send lane - <<EOF\nfirst \\\nsecond\nEOF")).toEqual({ target: "lane", noWait: false });
    expect(read("cat > /tmp/message >> /tmp/other <<'EOF'\nambiguous\nEOF\nacpmux send lane - < /tmp/message")).toEqual(
      {
        file: "/tmp/message",
        target: "lane",
        noWait: false,
        others: 1,
      },
    );
    expect(read("cat > /tmp/message 1>&2 <<'EOF'\nredirected\nEOF\nacpmux send lane - < /tmp/message")).toEqual({
      file: "/tmp/message",
      target: "lane",
      noWait: false,
      others: 1,
    });
    expect(read("cat > /tmp/message 2> /tmp/other <<'EOF'\nstderr\nEOF\nacpmux send lane - < /tmp/message")).toEqual({
      file: "/tmp/message",
      target: "lane",
      noWait: false,
      others: 1,
    });
    expect(read("cat > /tmp/message <<'EOF'\nOLD\nEOF\nacpmux send lane - < /tmp/message > /tmp/message")).toEqual({
      file: "/tmp/message",
      target: "lane",
      noWait: false,
      others: 2,
    });
    expect(
      read("cat > /tmp/message <<'EOF'\nOLD\nEOF\nacpmux send lane - < /tmp/message \"$(rm -f /tmp/message)\""),
    ).toEqual({
      target: "lane",
      noWait: false,
      others: 2,
    });
    expect(read("{ cat > /tmp/message <<'EOF'\nGROUPED\nEOF\n}\nacpmux send lane - < /tmp/message")).toEqual({
      file: "/tmp/message",
      target: "lane",
      noWait: false,
      others: 1,
    });
    expect(
      read("cat > /tmp/message <<'EOF'\nOLD\nEOF\nprintf NEW > /tmp/message\nacpmux send lane - < /tmp/message"),
    ).toEqual({ file: "/tmp/message", target: "lane", noWait: false, others: 2 });
    expect(read("cat > /tmp/message > /dev/null <<'EOF'\nSHADOWED\nEOF\nacpmux send lane - < /tmp/message")).toEqual({
      file: "/tmp/message",
      target: "lane",
      noWait: false,
      others: 1,
    });
    expect(read("true || cat > /tmp/message <<'EOF'\nSKIPPED\nEOF\nacpmux send lane - < /tmp/message")).toEqual({
      file: "/tmp/message",
      target: "lane",
      noWait: false,
      others: 1,
    });
  });
});

describe("whose exit status the call reports", () => {
  test("not when ! inverts it, nor when the send's group pipes its output on", () => {
    expect(acpmuxSend("! acpmux send lane hi")?.ownsExit).toBeUndefined();
    expect(acpmuxSend("(acpmux send lane hi) | tail -1")).toMatchObject({ target: "lane", text: "hi" });
    expect(acpmuxSend("(acpmux send lane hi) | tail -1")?.others).toBeUndefined();
    expect(acpmuxSend("(acpmux send lane hi) | tail -1")?.ownsExit).toBeUndefined();
  });

  test("not when a || before the send may skip it; unsure when a && or || before it may", () => {
    expect(acpmuxSend("test -d / || acpmux send lane hi")).toMatchObject({ unsure: true });
    expect(acpmuxSend("test -d / || acpmux send lane hi")?.ownsExit).toBeUndefined();
    expect(acpmuxSend("cd ~/wt && acpmux send lane hi")).toMatchObject({ ownsExit: true, unsure: true });
    expect(acpmuxSend("cd ~/wt; acpmux send lane hi")?.unsure).toBeUndefined();
  });

  test("the send's when it is the line's last command, its output piped nowhere", () => {
    expect(acpmuxSend("acpmux send lane hi")?.ownsExit).toBe(true);
    expect(acpmuxSend("cd ~/wt && acpmux send lane hi")?.ownsExit).toBe(true);
    expect(acpmuxSend("reach box 'timeout 30 acpmux send lane hi'")?.ownsExit).toBe(true);
    expect(acpmuxSend("acpmux send lane hi 2>&1 | tail -1")?.ownsExit).toBeUndefined();
    expect(acpmuxSend("acpmux send lane hi && make")?.ownsExit).toBeUndefined();
    expect(acpmuxSend("reach box 'acpmux send lane hi | tail -1'")?.ownsExit).toBeUndefined();
  });
});

describe("shellCommands", () => {
  test("only executable grouping is syntax; quoted words and heredoc bodies are content", () => {
    for (const command of [
      `acpmux send lane '[review](https://example.com) {pass}'`,
      `acpmux send lane "[review](https://example.com) {pass}"`,
      `acpmux send lane \\(review\\) \\{pass\\}`,
      `cat > /tmp/message <<'EOF'\n[review](https://example.com)\n{pass}\nEOF`,
      "acpmux send lane ready # (comment) {comment}",
    ])
      expect(shellCommands(command).every((part) => !part.grouped)).toBe(true);
    for (const command of [
      "(acpmux send lane - < /tmp/message)",
      "{ acpmux send lane - < /tmp/message; }",
      "(cat > /tmp/message <<'EOF'\ngrouped\nEOF\n)",
      "{ cat > /tmp/message <<'EOF'\ngrouped\nEOF\n}",
    ]) {
      expect(shellCommands(command).every((part) => part.grouped)).toBe(true);
      expect(recordedMessageBodyChanges(command)).toEqual([{ reset: true }]);
    }
    for (const command of [
      "bash -c '(acpmux send lane - < /tmp/message)'",
      "reach box '{ acpmux send lane - < /tmp/message; }'",
    ])
      expect(recordedMessageBodyChanges(command)).toEqual([{ reset: true }]);
  });

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
    expect(copy).toEqual({
      words: [],
      op: "",
      writes: true,
      writeFile: { text: "out", literal: true },
      redirectWrites: 1,
      stdout: true,
    });
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

  test("in a compound command, failed by acpmux's own error line, not another command's status", () => {
    const after = "acpmux send lane hi && false";
    expect(acpmuxSendCall(bash(after, { status: "failed", exitCode: 1, output: "queued" }))?.state).toBe("sent");
    const piped = "acpmux send lane hi 2>&1 | tail -1";
    const refused = 'acpmux: no_session: no session matches "lane"; run `acpmux ls` or `acpmux ensure lane`';
    expect(acpmuxSendCall(bash(piped, { exitCode: 0, output: refused }))?.state).toBe("failed");
    expect(acpmuxSendCall(bash(piped, { exitCode: 0, output: "queued" }))?.state).toBe("sent");
  });

  test("ended, not sent, when nothing says whether a send that may have been skipped went", () => {
    const skipped = "git push && acpmux send lane done; git status";
    expect(acpmuxSendCall(bash(skipped, { exitCode: 0, output: "nothing to commit" }))?.state).toBe("ended");
    expect(acpmuxSendCall(bash("test -d / || acpmux send lane hi", { exitCode: 0 }))?.state).toBe("ended");
    // A --no-wait send that printed how the daemon took it went.
    const taken = "git push && acpmux send --no-wait lane done; git status";
    expect(acpmuxSendCall(bash(taken, { exitCode: 0, output: "queued\nnothing to commit" }))?.state).toBe("sent");
    // With --json, acpmux's error object says it failed.
    const json = "acpmux send --json lane hi | jq .";
    const refused = '{"error":{"code":"no_session","message":"no session matches lane"}}';
    expect(acpmuxSendCall(bash(json, { exitCode: 0, output: refused }))?.state).toBe("failed");
  });

  test("its state: running, sent, or failed on a nonzero exit", () => {
    const line = "acpmux send --no-wait coord-deputy 'Merged.'";
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
