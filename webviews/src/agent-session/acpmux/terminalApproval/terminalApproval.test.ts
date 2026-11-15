import { describe, expect, test } from "bun:test";
import {
  parseTerminalApproval,
  setTerminalApproval,
  terminalApproval,
  terminalApprovalAnswer,
  terminalApprovalPermission,
} from "./terminalApproval";

/// What the host pushes for Claude Code's Bash dialog (cmux-window-rules tabs::approval).
const claude = {
  id: "6f1c2a9e0b4d7735",
  question: "Do you want to proceed?",
  header: "Bash command",
  command: "touch /tmp/w4i-perm",
  detail: ["Create an empty marker file"],
  options: [
    { key: 1, label: "Yes", hint: null, kind: "allow_once", selected: true },
    { key: 2, label: "Yes, and don't ask again for touch commands in /private/tmp", kind: "allow_always" },
    { key: 3, label: "No, and tell Claude what to do differently", hint: "esc", kind: "reject_once" },
  ],
  harness: "claude",
};

describe("terminalApproval", () => {
  test("a terminal's dialog reads as the chat's permission card, its options by number", () => {
    const approval = parseTerminalApproval(claude)!;
    const permission = terminalApprovalPermission(approval);
    expect(permission.title).toBe("Bash command");
    expect(permission.description).toBe("Create an empty marker file");
    expect(permission.command).toBe("touch /tmp/w4i-perm");
    expect(permission.kind).toBe("execute");
    expect(permission.pending).toBe(true);
    expect(permission.options).toEqual([
      { id: "1", name: "Yes", allow: true, kind: "allow_once" },
      {
        id: "2",
        name: "Yes, and don't ask again for touch commands in /private/tmp",
        allow: true,
        kind: "allow_always",
      },
      { id: "3", name: "No, and tell Claude what to do differently", allow: false, kind: "reject_once" },
    ]);
    // A click sends the option and the dialog the card showed, so the host checks the screen still shows it.
    expect(terminalApprovalAnswer(approval, "3")).toEqual({
      key: 3,
      label: "No, and tell Claude what to do differently",
      id: "6f1c2a9e0b4d7735",
    });
    expect(terminalApprovalAnswer(approval, "9")).toBeNull();
  });

  test("Codex's reason is what the call does; a dialog without a heading is titled by its question", () => {
    const approval = parseTerminalApproval({
      id: "a03e5d7c912b4f60",
      question: "Would you like to run the following command?",
      command: "touch /tmp/w4i-perm",
      detail: ["Reason: Create the marker file outside the workspace"],
      options: [
        { key: 1, label: "Yes, proceed", kind: "allow_once" },
        { key: 2, label: "No, and tell Codex what to do differently", kind: "reject_once" },
      ],
    })!;
    const permission = terminalApprovalPermission(approval);
    expect(permission.title).toBe("Would you like to run the following command?");
    expect(permission.description).toBe("Create the marker file outside the workspace");
  });

  test("a new dialog is a new card; anything malformed or null clears it", () => {
    setTerminalApproval(claude);
    const first = terminalApprovalPermission(terminalApproval()!).permissionId;
    // The same question about another command is another dialog: its id differs.
    setTerminalApproval({ ...claude, id: "0d4c6b2a19e87f53", command: "rm -rf ~/work" });
    expect(terminalApprovalPermission(terminalApproval()!).permissionId).not.toBe(first);
    setTerminalApproval({ id: "1", question: "Proceed?", options: [{ key: 1, label: "Yes" }] });
    expect(terminalApproval()).toBeNull();
    setTerminalApproval({ ...claude, id: "" });
    expect(terminalApproval()).toBeNull();
    setTerminalApproval(claude);
    setTerminalApproval(null);
    expect(terminalApproval()).toBeNull();
    expect(parseTerminalApproval({ id: "1", question: "", options: claude.options })).toBeNull();
    expect(
      parseTerminalApproval({
        ...claude,
        options: [
          { key: 0, label: "Yes" },
          { key: 2, label: "" },
        ],
      }),
    ).toBeNull();
  });
});
