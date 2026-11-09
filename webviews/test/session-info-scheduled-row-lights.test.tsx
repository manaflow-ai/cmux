// l10n-allow-file: test fixture wakeups and commands, not shipped UI.
// A wakeup or cron job in Session Info's Background tasks lights on hover as its sibling command rows
// do (Leo, 2026-11-06: "it is kind of weird that there is this, what is it, so-called fallback
// heartbeat, and it doesn't get highlighted in the same way that the other ones do"). A row lights
// when it takes a click: the native panel only for a row with an action, the page only for a row
// that is a button. A scheduled item is the call that made it, so while the loaded transcript holds
// that call its row shows it, in both panels; with no call to show it stays plain, as a command with
// nothing to open does.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import { translate } from "../src/agent-session/acpmux/i18n";
import { NativeInfoActions } from "../src/agent-session/acpmux/session-info/native/model";
import { tasksSection, type TasksSectionInput } from "../src/agent-session/acpmux/session-info/native/tasks";
import { TasksSection } from "../src/agent-session/acpmux/session-info/TasksSection";
import type { SummaryWakeup } from "../src/agent-session/acpmux/summary/sessionSummary";

const NOW = 1_800_000_000_000;
const heartbeat: SummaryWakeup = {
  id: "toolu_heartbeat",
  kind: "wakeup",
  text: "Fallback heartbeat; the local check runs",
  startedAt: NOW - 60_000,
  dueAt: NOW + 20 * 60_000,
};
const command = {
  id: "proc-1",
  processId: "proc-1",
  toolCallId: "toolu_cmd",
  command: "cd /tmp; timeout 3000 reach r",
  state: "running" as const,
  startedAt: NOW - 30_000,
};
const input = (overrides: Partial<TasksSectionInput> = {}): TasksSectionInput => ({
  open: true,
  processes: [],
  transcriptTasks: [],
  listed: true,
  scheduled: [heartbeat],
  workflows: [],
  local: true,
  now: NOW,
  ...overrides,
});

test("native: a wakeup whose call is loaded takes an action that shows the call", async () => {
  const actions = new NativeInfoActions();
  const shown: string[] = [];
  const section = tasksSection(
    input({
      calls: new Set([heartbeat.id]),
      onShowCall: (id) => {
        shown.push(id);
        return true;
      },
    }),
    actions,
    translate,
  )!;
  const row = section.rows.find((entry) => entry.id === `scheduled:${heartbeat.id}`)!;
  expect(row.action).toBeDefined();
  expect(actions.run(row.action!)).toBe(true);
  await Promise.resolve();
  await Promise.resolve();
  expect(shown).toEqual([heartbeat.id]);
});

test("native: a wakeup whose call is not loaded stays plain", () => {
  const section = tasksSection(
    input({ calls: new Set(), onShowCall: () => true }),
    new NativeInfoActions(),
    translate,
  )!;
  expect(section.rows.find((entry) => entry.id === `scheduled:${heartbeat.id}`)!.action).toBeUndefined();
});

test("page: a wakeup whose call is loaded is a button like its sibling command row", () => {
  const html = renderToStaticMarkup(
    <TasksSection
      commands={[command]}
      scheduled={[heartbeat]}
      calls={new Set([heartbeat.id, command.toolCallId])}
      onShowCall={() => true}
    />,
  );
  const page = new JSDOM(html).window.document;
  const rows = [...page.querySelectorAll("li.acpmux-session-info-task")];
  expect(rows).toHaveLength(2);
  const [commandRow, wakeupRow] = rows;
  // Both rows are the same lit button (sessionInfo.css `.acpmux-session-info-task__open:hover`).
  expect(commandRow!.querySelector(":scope > button.acpmux-session-info-task__open")).not.toBeNull();
  const button = wakeupRow!.querySelector(":scope > button.acpmux-session-info-task__open");
  expect(button).not.toBeNull();
  expect(button!.hasAttribute("disabled")).toBe(false);
  expect(button!.textContent).toContain("Fallback heartbeat");
});

test("page: a wakeup whose call is not loaded stays plain text", () => {
  const html = renderToStaticMarkup(<TasksSection commands={[]} scheduled={[heartbeat]} calls={new Set()} />);
  const page = new JSDOM(html).window.document;
  expect(page.querySelector("li.acpmux-session-info-task button")).toBeNull();
});
