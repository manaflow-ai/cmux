// A harness's own tools read as what they do, never as their raw CamelCase name: "Scheduling a
// wakeup" while it runs, "Scheduled a wakeup" after (harnessToolLabels.ts). Leo, 2026-11-03, on a
// "ScheduleWakeup" row: "instead of this kind of thing and SendMessage, we can just... make it look
// better? Scheduled Wakeup, sending message (like the sendmessage command is different from sent...)".
import { expect, test } from "bun:test";
import { HARNESS_TOOLS } from "../src/agent-session/acpmux/harnessToolLabels";
import { isPlumbingName } from "../src/agent-session/acpmux/hiddenTools";
import type { AcpmuxActivity } from "../src/agent-session/acpmux/model";
import { toolLabel } from "../src/agent-session/acpmux/toolPaths";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const label = (name: string, status: Tool["status"], title = name) =>
  toolLabel({ id: "t", title, kind: "other", status } as Tool, name, (line) => line);

test("every known harness tool has a running and a done label that is not its raw name", () => {
  for (const name of Object.keys(HARNESS_TOOLS)) {
    const running = label(name, "in_progress");
    const done = label(name, "completed");
    expect(running, name).not.toBe(name);
    expect(done, name).not.toBe(name);
    expect(running, name).not.toBe(done);
    // A label key the table lacks reads as the key itself.
    expect(running, name).not.toContain("tools.harness.");
    expect(done, name).not.toContain("tools.harness.");
  }
});

test("the tools Leo named read as what they do", () => {
  expect(label("ScheduleWakeup", "in_progress")).toBe("Scheduling a wakeup");
  expect(label("ScheduleWakeup", "completed")).toBe("Scheduled a wakeup");
  expect(label("SendMessage", "pending")).toBe("Sending a message");
  expect(label("SendMessage", "completed")).toBe("Sent a message");
  // A call with no title yet reads by its row's text.
  expect(label("TaskStop", "completed", "")).toBe("Stopped a task");
});

test("the raw names the brief listed are each labelled or never drawn", () => {
  for (const name of ["ScheduleWakeup", "SendMessage", "TaskStop", "ToolSearch", "CronCreate", "ListAgents", "Monitor"])
    expect(name in HARNESS_TOOLS || isPlumbingName(name), name).toBe(true);
});

test("any other name keeps its title", () => {
  expect(label("Frobnicate", "completed")).toBe("Frobnicate");
});
