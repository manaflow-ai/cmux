// l10n-allow-file: test fixture subagent tasks, commands and session titles, not shipped UI.
// The running tray's header counts each kind (trayHeadKinds.ts; Leo, 2026-11-03: "the top should be
// able to split per background task/scheduled wait/subagent/subsession? ... the top bit aka what the
// collapsed area shows i think can show much more interesting stuf fthan it does now"): what runs,
// kind by kind, then what ended in the list and its failures, and the mark of a subagent of another
// model family than the chat's.
import { describe, expect, test } from "bun:test";
import { translatorFor } from "../src/agent-session/acpmux/i18n";
import type { TrayItem } from "../src/agent-session/acpmux/subagents/runningTray";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import { endedCounts, trayHead, type TrayHeadKindsArm } from "../src/agent-session/acpmux/subagents/trayHeadKinds";
import type { StartedSession } from "../src/agent-session/acpmux/started/startedSessions";

const t = translatorFor("en");

const agent = (id: string, state: string, harness?: string): TrayItem => ({
  kind: "agent",
  id,
  depth: 0,
  agent: { id, parent: null, name: id, task: id, state, startedAt: 1_000, ...(harness && { harness }) } as Subagent,
});
// A plain command (trayCommandKinds.ts counts tests, builds and waits apart).
const command = (id: string, line = `ls ${id}`): TrayItem => ({
  kind: "command",
  id,
  command: { id, command: line, state: "running", startedAt: 1_000 },
});
const chat = (id: string, state: StartedSession["state"], harness = "claude"): TrayItem => ({
  kind: "session",
  id,
  session: { sessionId: id, title: id, state, harness, subsession: true },
});

const head = (
  items: TrayItem[],
  finished: TrayItem[],
  {
    arm = "kinds" as TrayHeadKindsArm,
    working = true,
    chatHarness = "claude",
    waiting = new Set<string>(),
    separator = undefined as string | undefined,
  } = {},
) => trayHead(t, { items, finished, waiting, working, chatHarness, arm, separator });

describe("the running tray header counts each kind", () => {
  test("Leo's tray: four commands and a finished subagent", () => {
    const counts = head([command("a"), command("b"), command("c"), command("d")], [agent("done", "completed")]);
    // What ended is the open list's "1 finished" line while anything runs, never a count up here.
    expect(counts.text).toBe("4 commands");
    expect(counts.failed).toBe(0);
  });

  test("every kind: subagents, a session, what waits, commands, then done and failed", () => {
    const counts = head(
      [
        agent("r1", "running"),
        agent("r2", "running", "codex"),
        agent("w", "running"),
        chat("s", "running"),
        command("c"),
      ],
      [agent("d", "completed"), agent("f", "failed"), agent("x", "cancelled")],
      { waiting: new Set(["w"]) },
    );
    expect(counts.text).toBe("2 subagents running · 1 session · 1 waiting · 1 command");
    expect(counts.failed).toBe(1);
    // The parts, most telling first: the failures come before the commands, so they stay longer.
    expect(counts.parts.map((part) => part.text)).toEqual([
      "2 subagents running",
      "1 session",
      "1 waiting",
      "1 failed",
      "1 command",
    ]);
    expect(counts.parts.find((part) => part.failed)?.text).toBe("1 failed");
    // A Codex subagent under a Claude chat is named by its mark; the chat's own family is not.
    expect(counts.marks).toEqual(["codex"]);
  });

  test("nothing runs: a session that ended counts with the done ones; a mix reads N done", () => {
    expect(head([], [agent("d", "completed"), chat("s", "idle")]).text).toBe("2 done");
    expect(head([command("c")], [chat("s", "failed")]).failed).toBe(1);
  });

  test("between turns it says the work runs in the background", () => {
    expect(head([agent("r", "running"), command("c")], [], { working: false }).text).toBe(
      "Running in background · 1 subagent · 1 command",
    );
  });

  test("the arms: no marks, sessions as subagents, and only what runs", () => {
    const items = [agent("r", "running", "codex"), chat("s", "running"), command("c")];
    const finished = [agent("d", "completed"), agent("f", "failed")];
    expect(head(items, finished, { arm: "plain" }).marks).toEqual([]);
    expect(head(items, finished, { arm: "sub" }).text).toBe("2 subagents running · 1 command");
    const running = head(items, finished, { arm: "running" });
    expect(running.text).toBe("2 subagents running · 1 command");
    expect(running.failed).toBe(0);
    expect(running.marks).toEqual([]);
  });

  // Leo, 2026-11-04: "the top of the bar not having anything is weird", over a list of stopped ones
  // that headed only "Subagents".
  test("what was stopped is counted, never a bare Subagents", () => {
    expect(head([], [agent("a", "cancelled"), agent("b", "disconnected")]).text).toBe("2 stopped");
    expect(head([], [agent("d", "completed"), agent("a", "cancelled")]).text).toBe("1 subagent done · 1 stopped");
  });

  test("only failures ended and nothing runs: no empty words before the count", () => {
    const counts = head([], [agent("f", "failed")]);
    expect(counts.text).toBe("");
    expect(counts.failed).toBe(1);
    expect(counts.parts).toEqual([{ key: "failed", text: "1 failed", failed: true }]);
  });
});

// Leo, 2026-11-12: "why are there ellipses going so fast? Like they get truncated and cut off so
// soon", on "33 subagents running · 1 test run · 7 waits · 11 commands · 292 done · 25 sto…".
describe("the header leaves what ended to its own line and orders counts to drop whole", () => {
  test("Leo's hat: what runs, the failures, then waits and commands last; no done, no stopped", () => {
    const items = [
      ...Array.from({ length: 33 }, (_, index) => agent(`r${index}`, "running")),
      command("test", "cmux-ci test -- bun test test/x.test.ts"),
      ...Array.from({ length: 7 }, (_, index) => command(`w${index}`, `glaeda-gh wait pr ${index}`)),
      ...Array.from({ length: 11 }, (_, index) => command(`c${index}`)),
    ];
    const finished = [
      ...Array.from({ length: 292 }, (_, index) => agent(`d${index}`, "completed")),
      ...Array.from({ length: 25 }, (_, index) => agent(`s${index}`, "cancelled")),
      ...Array.from({ length: 9 }, (_, index) => agent(`f${index}`, "failed")),
    ];
    const counts = head(items, finished);
    expect(counts.parts.map((part) => part.text)).toEqual([
      "33 subagents running",
      "9 failed",
      "1 test run",
      "7 waits",
      "11 commands",
    ]);
    expect(counts.text).not.toContain("done");
    expect(counts.text).not.toContain("stopped");
  });

  test("the ended line's tally: done and stopped are finished, failures apart", () => {
    const waiting = new Set<string>();
    expect(
      endedCounts(
        [agent("d", "completed"), agent("s", "cancelled"), agent("f", "failed"), chat("c", "failed")],
        waiting,
      ),
    ).toEqual({ finished: 2, failed: 2 });
    expect(endedCounts([], waiting)).toEqual({ finished: 0, failed: 0 });
  });
});

// Leo, 2026-11-03: "you can split up commands/waits/bg tasks/subagents/maybe agent sessions you
// expect something from ... so you can fit that all in counts of stuff and maybe times all in one
// line like a \ b \ c or a | b| c or a / b / c".
describe("the header counts the commands by what they do", () => {
  const coordinator = [
    agent("a", "running"),
    command("send", 'acpmux send review-lane "check it"'),
    command("review", "router-review manaflow-ai/app 12"),
    command("test", "cmux-ci test -- bun test test/x.test.ts"),
    command("build", "cmux-ci compile-check --ref abc --app"),
    command("ci", "glaeda-gh wait pr 12 --sha abc"),
    command("log", "tail -f /tmp/build.log"),
    command("server", "cd app && bun run dev"),
    command("plain", "rg -n TODO src"),
  ];

  test("each kind apart, in a fixed order, after the agents", () => {
    expect(head(coordinator, []).text).toBe(
      "1 subagent running · 1 message · 1 review · 1 test run · 1 build · 1 server · 2 waits · 1 command",
    );
  });

  test("the separator arms", () => {
    for (const separator of [" / ", " | ", " \\ "])
      expect(head(coordinator.slice(0, 3), [], { separator }).text).toBe(
        `1 subagent running${separator}1 message${separator}1 review`,
      );
  });

  test("only what runs keeps the one count of commands", () => {
    expect(head(coordinator, [], { arm: "running" }).text).toBe("1 subagent running · 8 commands");
  });
});
