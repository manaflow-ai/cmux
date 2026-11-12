import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { TaskGoalStrip } from "./TaskGoalStrip";
import { loopNextText } from "./taskGoalStripModel";
import { settleReact } from "../../../test/support/domTeardown";

const never = async () => {
  throw new Error("a loop has no command");
};

// cmux#38051: a self-wake's prompt is the agent's own brief (job ids, links, step lists). The chip
// says when the loop checks back and nothing of the prompt; the prompt is on demand only.
const WAKE_PROMPT =
  "Check background job b2mqa7gwr (fleet build 38051) and https://github.com/manaflow-ai/cmux/pull/1. Steps: 1. read the job log 2. if green, run the second bun run check 3. post the receipt";

test("a self-wake loop shows only when it checks back, never its wake prompt", () => {
  const now = 1_000_000;
  const html = renderToStaticMarkup(
    <TaskGoalStrip
      goal={{
        kind: "loop",
        status: "active",
        objective: WAKE_PROMPT,
        reason: "watching the fleet build",
        nextRunAt: now + 15 * 60_000,
      }}
      command={never}
      now={() => now}
    />,
  );
  const visible = new JSDOM(html).window.document.body.textContent ?? "";
  expect(html).toContain('data-kind="loop"');
  expect(visible).toBe("Checking back in 15 min.");
  expect(visible).not.toContain("b2mqa7gwr");
  // One button: it opens the prompt on demand. Claude Code has no way to stop or pause a loop from
  // outside its turn, so no button pretends to.
  expect(html.match(/<button/g)?.length).toBe(1);
  expect(html).toContain('aria-label="Loop prompt"');
  expect(html).toContain('aria-expanded="false"');
});

test("the wake prompt reads in the chip's tooltip and, opened, in full inside the details", async () => {
  const host = installDom();
  const now = 1_000_000;
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <TaskGoalStrip
        goal={{
          kind: "loop",
          status: "active",
          objective: WAKE_PROMPT,
          reason: "watching the fleet build",
          nextRunAt: now + 60_000,
        }}
        command={never}
        now={() => now}
      />,
    ),
  );
  const strip = host.querySelector<HTMLElement>(".acpmux-goal")!;
  expect(strip.querySelector(".acpmux-goal-copy")!.getAttribute("title")).toBe(
    `${WAKE_PROMPT}\n\nwatching the fleet build`,
  );
  expect(strip.querySelector(".acpmux-goal-details")).toBeNull();
  const button = strip.querySelector<HTMLButtonElement>("button")!;
  await act(async () => button.click());
  expect(button.getAttribute("aria-expanded")).toBe("true");
  const details = strip.querySelector<HTMLElement>(".acpmux-goal-details")!;
  expect(button.getAttribute("aria-controls")).toBe(details.id);
  expect(details.querySelector(".acpmux-goal-loop-prompt")!.textContent).toBe(WAKE_PROMPT);
  expect(details.textContent).toContain("watching the fleet build");
  await act(async () => button.click());
  expect(strip.querySelector(".acpmux-goal-details")).toBeNull();
});

test("a cron loop names its schedule, not a countdown, and not its prompt", () => {
  const html = renderToStaticMarkup(
    <TaskGoalStrip
      goal={{
        kind: "loop",
        status: "active",
        objective: "/babysit-prs",
        schedule: "every 5 minutes",
        nextRunAt: 90_010,
      }}
      command={never}
      now={() => 10}
    />,
  );
  const visible = new JSDOM(html).window.document.body.textContent ?? "";
  expect(visible).toBe("Repeats every 5 minutes");
  expect(visible).not.toContain("/babysit-prs");
});

test("a self-wake whose run is due reads as looping, still without its prompt", () => {
  const html = renderToStaticMarkup(
    <TaskGoalStrip
      goal={{ kind: "loop", status: "active", objective: WAKE_PROMPT, nextRunAt: 5 }}
      command={never}
      now={() => 10}
    />,
  );
  expect(new JSDOM(html).window.document.body.textContent).toBe("Looping");
});

test("an autonomous loop has no prompt to open; its tooltip says it is autonomous", () => {
  const html = renderToStaticMarkup(
    <TaskGoalStrip goal={{ kind: "loop", status: "active", objective: "", autonomous: true }} command={never} />,
  );
  expect(html).toContain('title="Autonomous loop"');
  expect(html).not.toContain("<button");
});

test("an autonomous loop with a reason can open it", () => {
  const html = renderToStaticMarkup(
    <TaskGoalStrip
      goal={{ kind: "loop", status: "active", objective: "", autonomous: true, reason: "waiting on CI" }}
      command={never}
    />,
  );
  expect(html.match(/<button/g)?.length).toBe(1);
  expect(new JSDOM(html).window.document.body.textContent).toBe("Looping");
});

test("a Codex goal keeps its Pause and Clear, gains Edit, and its line is one fold button", () => {
  const html = renderToStaticMarkup(
    <TaskGoalStrip goal={{ objective: "Ship the fix", status: "active" }} command={never} />,
  );
  expect(html.match(/<button/g)?.length).toBe(4);
  expect(html).toContain('aria-label="Pause"');
  expect(html).toContain('aria-label="Edit goal"');
  expect(html).toContain('aria-label="Clear"');
  expect(html).toContain('aria-expanded="false"');
  expect(new JSDOM(html).window.document.querySelector(".acpmux-goal-state")?.textContent).toBe("Goal running");
});

// Leo, 2026-11-09, on a reference goal pill: "that rapid click togle on/of fand its speed too", and
// "no expansion of the goal in place either". The line opens in place and every click counts: fifteen
// clicks leave it open (odd), sixteen folded, with nothing queued behind them.
test("every click on the goal's line toggles it in place, however fast", async () => {
  const host = installDom();
  root = createRoot(host);
  const goal = { objective: "Finish the timeout fix and verify the retry behavior", status: "stalled" as const };
  await act(async () => root!.render(<TaskGoalStrip goal={goal} command={never} harness="codex" />));
  const line = host.querySelector<HTMLButtonElement>(".acpmux-goal-toggle")!;
  const section = host.querySelector<HTMLElement>(".acpmux-goal")!;
  expect(section.querySelector(".acpmux-goal-state")?.textContent).toBe("Goal stalled");
  expect(section.dataset.clamped).toBe("true");
  for (let click = 1; click <= 16; click++) {
    await act(async () => line.click());
    expect(line.getAttribute("aria-expanded")).toBe(click % 2 === 1 ? "true" : "false");
    expect(section.hasAttribute("data-open")).toBe(click % 2 === 1);
  }
});

test("Edit swaps the objective for a field in place; Return sends the new goal, Escape keeps the old", async () => {
  const host = installDom();
  root = createRoot(host);
  const sent: [string, string | undefined][] = [];
  const command = async (action: string, objective?: string) => {
    sent.push([action, objective]);
  };
  const goal = { objective: "Ship the fix", status: "active" as const, provider: "codex" as const };
  await act(async () => root!.render(<TaskGoalStrip goal={goal} command={command} />));
  const edit = () => host.querySelector<HTMLButtonElement>('[aria-label="Edit goal"]')!;
  await act(async () => edit().click());
  let field = host.querySelector<HTMLTextAreaElement>(".acpmux-goal-field")!;
  expect(field.value).toBe("Ship the fix");
  expect(host.querySelector(".acpmux-goal")?.hasAttribute("data-open")).toBe(true);
  const type = async (node: HTMLTextAreaElement, value: string) => {
    const setter = Object.getOwnPropertyDescriptor(dom!.window.HTMLTextAreaElement.prototype, "value")!.set!;
    setter.call(node, value);
    await act(async () => node.dispatchEvent(new dom!.window.Event("input", { bubbles: true })));
  };
  const key = async (node: HTMLElement, name: string) =>
    act(async () => node.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: name, bubbles: true })));
  await type(field, "Ship the fix and its test");
  await key(field, "Escape");
  expect(host.querySelector(".acpmux-goal-field")).toBeNull();
  expect(sent).toEqual([]);
  await act(async () => edit().click());
  field = host.querySelector<HTMLTextAreaElement>(".acpmux-goal-field")!;
  await type(field, "  Ship the fix and its test  ");
  await key(field, "Enter");
  expect(sent).toEqual([["edit", "Ship the fix and its test"]]);
  expect(host.querySelector(".acpmux-goal-field")).toBeNull();
});

test("the countdown text changes at whole seconds under a minute, then at whole minutes", () => {
  expect(loopNextText(0, 45_000, "en")).toBe("in 45 sec.");
  expect(loopNextText(0, 4 * 60_000 + 1, "en")).toBe("in 4 min.");
  expect(loopNextText(0, 2 * 3_600_000, "en")).toBe("in 2 hr.");
  expect(loopNextText(10, 5, "en")).toBeUndefined();
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

// Review of #34452: a parent render just after the run time, before the page clock's next tick,
// stopped the clock while its last sample was still before the deadline, so "in 2 sec." stayed up
// with no timer left to take it down.
test("a render past the run time, before the next clock tick, drops the countdown", async () => {
  const host = installDom();
  let clock = 1_000_000;
  const now = () => clock;
  const at = clock + 1_500;
  const goal = { kind: "loop" as const, status: "active" as const, objective: "check the deploy", nextRunAt: at };
  root = createRoot(host);
  await act(async () => root!.render(<TaskGoalStrip goal={goal} command={never} now={now} />));
  expect(host.querySelector(".acpmux-goal-state")?.textContent).toBe("Checking back in 2 sec.");
  clock = at + 10;
  await act(async () => root!.render(<TaskGoalStrip goal={{ ...goal }} command={never} now={now} />));
  expect(host.querySelector(".acpmux-goal-state")?.textContent).toBe("Looping");
});

// composer-typing-flicker, on cmux#39151: the goal heads the composer hat and its time ticks every
// second. A tick re-renders only the time (`GoalTime`), never the row, or the hat flickers with it.
test("a clock tick changes the goal's time and re-renders nothing else of the row", async () => {
  const host = installDom();
  root = createRoot(host);
  // The row reads its `now` once per render (its "Updated" line); the time leaf reads the page clock.
  let rowRenders = 0;
  const now = () => {
    rowRenders++;
    return Date.now();
  };
  const startedAt = Date.now() - 65_000;
  const goal = { objective: "Ship the fix", status: "active" as const, provider: "codex" as const, startedAt };
  await act(async () =>
    root!.render(<TaskGoalStrip goal={{ ...goal, updatedAt: startedAt }} command={never} now={now} />),
  );
  const time = () => host.querySelector(".acpmux-goal-time")?.textContent;
  const first = time();
  // The shared Clock holds the minute shape's widest text, so a tick never moves the chevron.
  expect(host.querySelector(".acpmux-goal-time .ui-clock")?.getAttribute("data-clock-size")).toBe("00m 00s");
  const before = rowRenders;
  await act(async () => {
    // fixed-wait: the page clock's real one-second tick is what this measures; two pass.
    await new Promise((resolve) => setTimeout(resolve, 2_100));
  });
  expect(time()).not.toBe(first);
  expect(rowRenders).toBe(before);
});
