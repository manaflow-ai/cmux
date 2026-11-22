// l10n-allow-file: test fixture commands, not shipped UI.
// How long a tool call has run, on its own row (Lawrence, 2026-11-19, on a "Ran glaeda-gh wait …"
// row that went on in the background with nothing to say for how long: "would be useful to see how
// long it has been running for"). A running call (in the foreground past a few seconds, or in the
// background) shows its time at the row's edge, counting each second from the call's own start;
// once it ends the row draws no time (Lawrence and Lucas, 2026-11-11 standup), and its opened Shell
// card says how long it took.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity, AcpmuxBackgroundState } from "../model";
import { resetTranscriptDisclosure } from "./transcriptDisclosureModel";
import { CommandRow } from "./CommandRow";
import { ToolRow } from "./ToolRow";
import { McpCallRow } from "./McpCallRows";
import { Thinking } from "./Thinking";
import { settleReact } from "../../../../test/support/domTeardown";
import { subscribePageSecond } from "../../../ui/pageClock";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const realNow = Date.now;
const STARTED = Date.UTC(2026, 10, 19, 20, 0, 0);
let now = STARTED;

beforeEach(() => {
  now = STARTED;
  Date.now = () => now;
});

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  resetTranscriptDisclosure();
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  Date.now = realNow;
});

async function render(node: ReactNode): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

/** Resolves on the page clock's next tick (a joining listener is told the last sample at once: skipped). */
const nextSecond = () =>
  new Promise<void>((resolve) => {
    let calls = 0;
    const stop = subscribePageSecond(() => {
      if (++calls < 2) return;
      queueMicrotask(stop);
      resolve();
    });
  });

const COMMAND = "glaeda-gh wait pid 13341 --timeout 1750";

/** A shell call: in the foreground while `status` runs, or launched and gone on in the background. */
const shell = (
  status: string,
  extra: { endedAt?: number; background?: AcpmuxBackgroundState } = {},
): AcpmuxActivity => ({
  kind: "tool",
  text: COMMAND,
  tool: {
    id: "sh1",
    title: COMMAND,
    kind: "execute",
    status,
    command: COMMAND,
    startedAt: STARTED,
    ...extra,
  },
});

const time = (container: HTMLElement) => container.querySelector(".cv-command__elapsed")?.textContent ?? null;

for (const [name, Row] of [
  ["CommandRow", CommandRow],
  ["ToolRow", ToolRow],
] as const) {
  test(`${name}: a shell running in the background shows how long it has run, and counts on`, async () => {
    now = STARTED + 12 * 60_000 + 4_000;
    const container = await render(
      <Row item={shell("completed", { endedAt: STARTED + 200, background: { state: "running" } })} />,
    );
    expect(time(container)).toBe("12m 4s");
    // Seen, not on hover only: the time is the row's news while it runs.
    expect(container.querySelector(".cv-command__elapsed")!.closest(".cv-command__time")).toBeNull();
    // The page clock's next second moves it on.
    now += 61_000;
    await act(nextSecond);
    expect(time(container)).toBe("13m 5s");
  });

  test(`${name}: a shell running in the foreground shows its time once past a few seconds`, async () => {
    now = STARTED + 1_000;
    const quick = await render(<Row item={shell("in_progress")} />);
    // A quick call never flashes a time.
    expect(time(quick)).toBeNull();
    await act(async () => root!.unmount());
    root = undefined;
    now = STARTED + 41_000;
    const slow = await render(<Row item={shell("in_progress")} />);
    expect(time(slow)).toBe("41s");
  });

  test(`${name}: a finished shell draws no time on its row; its opened Shell card says how long it took`, async () => {
    now = STARTED + 60 * 60_000;
    const container = await render(
      <Row
        item={shell("completed", {
          endedAt: STARTED + 200,
          background: { state: "completed", exitCode: 0, endedAt: STARTED + 64 * 60_000 + 3_000 },
        })}
      />,
    );
    expect(time(container)).toBeNull();
    const toggle = container.querySelector<HTMLElement>("button.cv-tool")!;
    await act(async () => {
      toggle.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true }));
    });
    expect(container.querySelector(".cv-shell__time")?.textContent).toBe("1h 4m 3s");
  });
}

test("a running MCP call (a wait) shows how long it has run", async () => {
  now = STARTED + 5 * 60_000 + 30_000;
  const container = await render(
    <McpCallRow
      item={{
        kind: "tool",
        text: "run_wait",
        tool: {
          id: "mcp1",
          title: "mcp__acpmux__run_wait",
          kind: "other",
          status: "in_progress",
          inputSummary: JSON.stringify({ run: "44637914493" }),
          startedAt: STARTED,
        },
      }}
    />,
  );
  expect(time(container)).toBe("5m 30s");
});

// The running turn's line at the bottom, which names the call in flight ("Running cargo test"): with
// the turn's clock over the work ("Working for", liveTurnClock.experiment.ts `top`, the default) it
// was untimed and said nothing of how long the call had run. Seen in the real app on a fleet capture,
// 2026-11-19: "Running cargo test --workspace" with no time under "Working for 1m 44s".
test("the live line names a running call with how long that call has run, under Working for", async () => {
  now = STARTED + 2 * 60_000 + 7_000;
  const container = await render(
    <Thinking
      since={STARTED - 30_000}
      untimed
      turnTotal
      doing="cargo test --workspace"
      doingShell
      doingAt={STARTED}
      command
    />,
  );
  expect(time(container)).toBe("2m 7s");
  // Not the turn's clock: that stands over the work.
  expect(container.querySelector(".cv-worked__time")).toBeNull();
});

test("the live line says no time for a call just started, nor once nothing runs", async () => {
  now = STARTED + 1_000;
  const quick = await render(<Thinking untimed turnTotal doing="git status" doingShell doingAt={STARTED} command />);
  expect(time(quick)).toBeNull();
  await act(async () => root!.unmount());
  root = undefined;
  now = STARTED + 60_000;
  const thinking = await render(<Thinking untimed turnTotal />);
  expect(time(thinking)).toBeNull();
});
