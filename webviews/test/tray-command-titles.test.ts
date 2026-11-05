// l10n-allow-file: test fixture commands, not shipped UI.
// A running tray command line is never a clipped word (Leo, 2026-11-04, on lines reading "Command
// hold" and "Command review result": "wtf are these holds"). The commands are the Claude Monitor
// calls from that tray: `sleep 840; echo t` named "hold" and a wait for a file named "review result".
import { describe, expect, test } from "bun:test";
import { setPaneLanguage, translate } from "../src/agent-session/acpmux/i18n";
import { commandRead } from "../src/agent-session/acpmux/session-info/commandRules";
import { trimRawCommand } from "../src/agent-session/acpmux/conversation/shortCommand";
import { backgroundCommands, processesOf } from "../src/agent-session/acpmux/session-info/processes";
import { trayItems } from "../src/agent-session/acpmux/subagents/runningTray";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";

setPaneLanguage("en");
const t = (key: Parameters<typeof translate>[0], values?: Parameters<typeof translate>[1]) =>
  translate(key, values, "en");
const label = (command: string, description?: string) =>
  commandRead(t, description === undefined ? { command } : { command, description }).label;

const WAIT_FILE =
  "until [ -s /private/tmp/claude-501/x/tasks/b0luhqojj.output ]; do sleep 5; done; cat /private/tmp/claude-501/x/tasks/b0luhqojj.output";
const words = (text: string) => text.split(/\s+/).filter(Boolean).length;

describe("a tray command line says what runs", () => {
  test("its dim activity keeps the real shell steps while trimming only its width", () => {
    expect(trimRawCommand("sleep 299; echo t")).toBe("sleep 299; echo t");
    expect(trimRawCommand("sleep 299; echo t", 12)).toBe("sleep 299;…");
  });

  test("a description of a word or two follows what the command does", () => {
    expect(label("sleep 840; echo t", "hold")).toBe("Waiting 14m · hold");
    expect(label(WAIT_FILE, "review result")).toBe("Waiting for b0luhqojj.output · review result");
  });

  test("no line from Leo's tray is a single word or just the description", () => {
    for (const [command, description] of [
      ["sleep 840; echo t", "hold"],
      [WAIT_FILE, "review result"],
    ] as const) {
      const line = label(command, description);
      expect(words(line)).toBeGreaterThan(words(description));
      expect(line).not.toBe(description);
    }
  });

  test("a long description stays whole", () => {
    expect(label("gh pr view 3119 --json body | grep HOLD", "Check PR #3119 for a HOLD line")).toBe(
      "Check PR #3119 for a HOLD line",
    );
  });

  test("a short description that is the command reading, or the only words known, stays once", () => {
    // Claude named the task only by its description: the registry's command is that description.
    expect(label("hold", "hold")).toBe("hold");
    expect(label("sleep 60", "Waiting 1m")).toBe("Waiting 1m");
  });

  test("no description reads from the program", () => {
    expect(label("sleep 840; echo t")).toBe("Waiting 14m");
    expect(label(WAIT_FILE)).toBe("Waiting for b0luhqojj.output");
    expect(label("while ! test -f /tmp/done.txt; do sleep 1; done")).toBe("Waiting for done.txt");
  });
});

describe("a subagent's command names its subagent", () => {
  const reviewer: Subagent = {
    id: "root/toolu_reviewer",
    parent: null,
    name: "Reviewer",
    state: "running",
    background: true,
    startedAt: 1,
  };

  test("the registry's subagentSessionId reaches the tray item as its owner", () => {
    const processes = processesOf(
      {
        processes: [
          {
            id: "root/b1",
            sessionId: "root",
            command: "sleep 840; echo t",
            description: "hold",
            subagentSessionId: reviewer.id,
            state: "running",
            startedAt: 2,
          },
          { id: "root/b2", sessionId: "root", command: "bun run dev", state: "running", startedAt: 3 },
        ],
      },
      "root",
    );
    const items = trayItems([reviewer], backgroundCommands(processes, [], true), [], false);
    const commands = items.flatMap((item) => (item.kind === "command" ? [item] : []));
    expect(commands.find((item) => item.command.id === "root/b1")?.owner?.name).toBe("Reviewer");
    expect(commands.find((item) => item.command.id === "root/b2")?.owner).toBeUndefined();
  });
});
