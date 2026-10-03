import { describe, expect, test } from "bun:test";
import type { AcpmuxActivity } from "../model";
import { agentMessage, commandMessage, mailboxRecipient, shellSteps, shellWords } from "./agentMessages";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const tool = (fields: Partial<Tool>): Tool => ({ id: "t", title: "", status: "completed", ...fields });

describe("agent messages", () => {
  test("tell-coordinator names its recipient and sender; the default recipient is the coordinator", () => {
    expect(commandMessage(`tell-coordinator --from cc-pane-transcript "PR #17081 is green"`)).toEqual({
      channel: "coordinator",
      to: "coordinator",
      from: "cc-pane-transcript",
      text: "PR #17081 is green",
    });
    expect(commandMessage(`tell-coordinator --to cc-next-ci --re 42 'Rebased; please re-run'`)).toEqual({
      channel: "coordinator",
      to: "cc-next-ci",
      text: "Rebased; please re-run",
    });
  });

  test("a message read from stdin takes the here-document's body", () => {
    const command = `tell-coordinator --from cc-pane-transcript - <<'EOF'\nLanded #17079.\nNext: P0 items 4+5.\nEOF`;
    expect(commandMessage(command)?.text).toBe("Landed #17079.\nNext: P0 items 4+5.");
  });

  test("cmux send types into another terminal; a path to the CLI also counts", () => {
    expect(commandMessage(`cmux send --workspace workspace:2 --surface surface:5 "run the tests"`)).toEqual({
      channel: "terminal",
      to: "surface:5",
      text: "run the tests",
    });
    expect(commandMessage(`cd ~/x && /usr/local/bin/cmux send --workspace workspace:3 hi`)?.to).toBe("workspace:3");
    expect(commandMessage(`cmux list-workspaces`)).toBeUndefined();
  });

  test("a shell write into a mailbox names the mailbox", () => {
    expect(commandMessage(`echo "ready for review" >> ~/.cache/coordinator-inbox/leo.jsonl`)).toEqual({
      channel: "mailbox",
      to: "leo",
      text: "ready for review",
    });
    expect(commandMessage(`echo "ready for review" >> ~/inbox/leo/coordinator`)).toBeUndefined();
    expect(mailboxRecipient("/home/a/.cache/coordinator-inbox/leoli-24.jsonl")).toBe("leoli-24");
    expect(mailboxRecipient("src/inboxes/x.ts")).toBeUndefined();
    expect(commandMessage(`cat README.md > out.txt`)).toBeUndefined();
  });

  test("Claude Code's SendMessage and file edits into a mailbox", () => {
    expect(
      agentMessage(
        tool({
          title: "SendMessage",
          inputSummary: JSON.stringify({ to: "cc-pane-composer", message: "Batch 2 is yours" }),
        }),
      ),
    ).toEqual({ channel: "agent", to: "cc-pane-composer", text: "Batch 2 is yours" });
    expect(
      agentMessage(
        tool({
          kind: "edit",
          title: "Write",
          diffs: [{ path: "/h/.cache/coordinator-inbox/leo.jsonl", newText: "Done\n" }],
        }),
      ),
    ).toEqual({ channel: "mailbox", to: "leo", text: "Done" });
    expect(agentMessage(tool({ kind: "execute", title: "ls", command: "ls -la" }))).toBeUndefined();
    expect(agentMessage(tool({ title: "Read", inputSummary: JSON.stringify({ to: "x" }) }))).toBeUndefined();
  });

  test("shell words follow quotes and stop at a redirect", () => {
    expect(shellWords(`a "b c" 'd e' f\\ g > out`)).toEqual(["a", "b c", "d e", "f g"]);
    expect(shellWords(`say "it's \\"fine\\""`)).toEqual(["say", `it's "fine"`]);
  });
});

describe("shell steps", () => {
  test("split outside quotes only", () => {
    expect(shellSteps(`cd x && tell-coordinator 'a; b && c' ; ls | wc -l`)).toEqual([
      "cd x",
      "tell-coordinator 'a; b && c'",
      "ls",
      "wc -l",
    ]);
  });
});

describe("what is not a message", () => {
  test("source files in a folder named inbox are edits, and so is a rewrite of a mailbox file", () => {
    const edit = (path: string, oldText: string | undefined, newText: string) =>
      agentMessage(tool({ kind: "edit", title: "Edit", diffs: [{ path, oldText, newText }] }));
    expect(edit("backend/packages/home-core/src/inbox/reducer.ts", "a\n", "b\n")).toBeUndefined();
    expect(edit("first-party-apps/inbox/README.md", undefined, "# Inbox\n")).toBeUndefined();
    expect(edit("src/inbox/components/List.tsx", undefined, "x")).toBeUndefined();
    expect(edit("first-party-apps/inbox/strings/en.json", "{\n", '{\n  "a": "b",\n')).toBeUndefined();
    expect(edit("first-party-apps/inbox/preview/x.json", undefined, "{}")).toBeUndefined();
    expect(edit("/home/a/.cache/coordinator-inbox/leo.jsonl", "first\n", "changed\n")).toBeUndefined();
    expect(edit("/home/a/.cache/coordinator-inbox/leo.jsonl", "first\n", "first\nsecond\n")).toEqual({
      channel: "mailbox",
      to: "leo",
      text: "second",
    });
  });

  test("an inbox path in quotes, a here-document or a non-mailbox redirect is not a mailbox write", () => {
    expect(commandMessage(`git commit -m "fix: append >> inbox/leo when idle"`)).toBeUndefined();
    expect(commandMessage(`grep foo bar > /tmp/inbox/out.txt`)).toBeUndefined();
    expect(
      commandMessage(`cat > first-party-apps/inbox/README.md <<'EOF'\n# Inbox\necho hi >> inbox/leo/x\nEOF`),
    ).toBeUndefined();
  });

  test("tell-coordinator --help sends nothing", () => {
    expect(commandMessage(`tell-coordinator --help`)).toBeUndefined();
  });
});

describe("shell details", () => {
  test("a descriptor before a redirect is not part of the message", () => {
    expect(commandMessage(`tell-coordinator "build done" 2>&1`)?.text).toBe("build done");
    expect(commandMessage(`tell-coordinator "build done" &>/dev/null`)?.text).toBe("build done");
  });

  test("a background & ends the step", () => {
    expect(commandMessage(`tell-coordinator "x" & wait`)?.text).toBe("x");
    expect(shellSteps(`a 2>&1 & b`)).toEqual(["a 2>&1", "b"]);
  });

  test("--name=value options", () => {
    expect(commandMessage(`cmux send --surface=surface:2 "go"`)).toEqual({
      channel: "terminal",
      to: "surface:2",
      text: "go",
    });
    // tell-coordinator has no = forms: the script takes `--to=x` as the text's first word.
    expect(commandMessage(`tell-coordinator --to=cc-next-ci "ok"`)).toMatchObject({
      to: "coordinator",
      text: "--to=cc-next-ci ok",
    });
  });

  test("tee and echo into a mailbox", () => {
    expect(commandMessage(`echo "ready" | tee -a ~/.cache/coordinator-inbox/leo.jsonl`)).toEqual({
      channel: "mailbox",
      to: "leo",
      text: "ready",
    });
    expect(commandMessage(`cat >> ~/.cache/coordinator-inbox/leoli-24.jsonl <<'EOF'\n{"text":"hi"}\nEOF`)).toEqual({
      channel: "mailbox",
      to: "leoli-24",
      text: '{"text":"hi"}',
    });
  });
});

describe("as the scripts read them", () => {
  test("tell-coordinator options end at the first word of the text", () => {
    expect(commandMessage(`tell-coordinator done, retry with --to leo`)).toMatchObject({
      to: "coordinator",
      text: "done, retry with --to leo",
    });
    expect(commandMessage(`tell-coordinator use -h for help`)?.text).toBe("use -h for help");
  });

  test("assignments before the program, and --help on cmux send", () => {
    expect(commandMessage(`CMUX_TAG=foo scripts/cmux-debug-cli.sh send --surface surface:1 "echo ok"`)).toEqual({
      channel: "terminal",
      to: "surface:1",
      text: "echo ok",
    });
    expect(commandMessage(`cmux send --help`)).toBeUndefined();
  });

  test("only Claude Code's SendMessage, and an object message as JSON", () => {
    const input = (title: string, value: unknown) =>
      agentMessage(tool({ title, inputSummary: JSON.stringify({ to: "x", message: value }) }));
    expect(input("mcp__gmail__send_message", "hi")).toBeUndefined();
    expect(input("SendMessage", { type: "shutdown" })?.text).toBe('{\n  "type": "shutdown"\n}');
  });
});

describe("commands that do more than send", () => {
  test("stay command rows, so their output stays reachable", () => {
    expect(
      commandMessage(`cd webviews && bun test | tail -5; tell-coordinator --to leo "tests: green"`),
    ).toBeUndefined();
    expect(commandMessage(`git push && tell-coordinator "pushed"`)).toBeUndefined();
    expect(commandMessage(`./scripts/reload.sh --tag x && cmux send --surface surface:1 "go"`)).toBeUndefined();
    expect(commandMessage(`tell-coordinator "done"; git status`)).toBeUndefined();
  });

  test("setup steps and piped text still make a card", () => {
    expect(commandMessage(`cd ~/x && export A=1 && tell-coordinator "hi"`)?.text).toBe("hi");
    expect(commandMessage(`echo "from a pipe" | tell-coordinator -`)).toMatchObject({ text: "from a pipe" });
    expect(commandMessage(`echo x || tell-coordinator "y"`)).toBeUndefined();
  });

  test("emptying a mailbox sends nothing", () => {
    expect(commandMessage(`: > ~/.cache/coordinator-inbox/leo.jsonl`)).toBeUndefined();
  });
});
