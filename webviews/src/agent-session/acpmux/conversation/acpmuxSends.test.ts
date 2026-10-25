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
    // Two sends are two messages: the command row keeps both.
    expect(acpmuxSend("acpmux send a x; acpmux send b y")).toBeUndefined();
  });

  test("only a command in command position: not an echoed or quoted mention, not another subcommand", () => {
    expect(acpmuxSend('echo "acpmux send x y"')).toBeUndefined();
    expect(acpmuxSend("grep -n 'acpmux send' notes.md")).toBeUndefined();
    expect(acpmuxSend("acpmux ls")).toBeUndefined();
    expect(acpmuxSend("acpmux sessions send x")).toBeUndefined();
    expect(acpmuxSend("acpmux dispatch --brief b.md --target auto")).toBeUndefined();
    expect(acpmuxSend("cat <<'EOF' > note.md\nacpmux send x y\nEOF")).toBeUndefined();
    expect(acpmuxSend("cmux send --surface s 'hi'")).toBeUndefined();
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
  });
});

test("Background tasks and the tray name a background send as its row does", () => {
  const t = ((key: string, values: { target: string }) => `${key}:${values.target}`) as unknown as Translate;
  const command = "timeout 100 acpmux send --no-wait huge-blue/lane 'hi'";
  expect(sendLabel(t, { command, state: "running" })).toBe("send.sending:huge-blue/lane");
  expect(sendLabel(t, { command, state: "completed" })).toBe("send.sent:huge-blue/lane");
  expect(sendLabel(t, { command, state: "failed" })).toBe("send.failed:huge-blue/lane");
  expect(sendLabel(t, { command: "bun test", state: "running" })).toBeUndefined();
});
