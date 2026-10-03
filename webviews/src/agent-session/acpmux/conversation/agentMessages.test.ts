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
    expect(commandMessage(`echo "ready for review" >> ~/inbox/leo/coordinator`)).toEqual({
      channel: "mailbox",
      to: "leo",
      text: "ready for review",
    });
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
        tool({ kind: "edit", title: "Write", diffs: [{ path: "/repo/inbox/leo/note.md", newText: "Done\n" }] }),
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
