import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { loopNextText, TaskGoalStrip } from "./TaskGoalStrip";

const never = async () => {
  throw new Error("a loop has no command");
};

test("a Claude Code loop shows its prompt, that it loops and when it next runs, with no controls", () => {
  const now = 1_000_000;
  const html = renderToStaticMarkup(
    <TaskGoalStrip
      goal={{ kind: "loop", status: "active", objective: "check the deploy", nextRunAt: now + 4 * 60_000 }}
      command={never}
      now={() => now}
    />,
  );
  expect(html).toContain('data-kind="loop"');
  expect(html).toContain("Looping");
  expect(html).toContain("check the deploy");
  expect(html).toContain("in 4 min.");
  // Claude Code has no way to stop or pause a loop from outside its turn: no button pretends to.
  expect(html).not.toContain("<button");
});

test("a cron loop names its schedule; a past run time shows no countdown", () => {
  const html = renderToStaticMarkup(
    <TaskGoalStrip
      goal={{ kind: "loop", status: "active", objective: "/babysit-prs", schedule: "every 5 minutes", nextRunAt: 5 }}
      command={never}
      now={() => 10}
    />,
  );
  expect(html).toContain("every 5 minutes");
  expect(html).not.toContain("acpmux-goal-next");
});

test("an autonomous loop reads as one, not as an empty prompt", () => {
  const html = renderToStaticMarkup(
    <TaskGoalStrip goal={{ kind: "loop", status: "active", objective: "", autonomous: true }} command={never} />,
  );
  expect(html).toContain("Autonomous loop");
});

test("a Codex goal keeps its Pause and Clear", () => {
  const html = renderToStaticMarkup(
    <TaskGoalStrip goal={{ objective: "Ship the fix", status: "active" }} command={never} />,
  );
  expect(html.match(/<button/g)?.length).toBe(2);
});

test("the countdown text changes at whole seconds under a minute, then at whole minutes", () => {
  expect(loopNextText(0, 45_000, "en")).toBe("in 45 sec.");
  expect(loopNextText(0, 4 * 60_000 + 1, "en")).toBe("in 4 min.");
  expect(loopNextText(0, 2 * 3_600_000, "en")).toBe("in 2 hr.");
  expect(loopNextText(10, 5, "en")).toBeUndefined();
});
