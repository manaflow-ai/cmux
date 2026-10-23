// A queue a failed turn paused says why (the turn's error) and offers one Resume; the prompts it
// holds never claim they send after this turn, because they wait for Resume (Leo hit a paused
// queue that held every message silently, 2026-10-21). The rows carry no header either way: the
// queue is one muted line per prompt (Leo, 2026-10-21), and the paused note above them is what says
// they wait.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { translatorFor } from "../src/agent-session/acpmux/i18n";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { queuePauseReason } from "../src/agent-session/acpmux/queuePause";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "ResizeObserver", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM(
    "<!doctype html><div class=acpmux-main><div class=acpmux-composer-box id=root></div></div>",
  );
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    ResizeObserver: (window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const queued = [
  { id: "q1", prompt: "Also update the comment above the retry loop" },
  { id: "q2", prompt: "Then run the tests" },
];

async function draw(paused: boolean, reason?: string) {
  const { createRoot } = await import("react-dom/client");
  const { ComposerQueue } = await import("../src/agent-session/acpmux/ComposerQueue");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <ComposerQueue
        queue={queued as never}
        paused={paused}
        {...(reason ? { pauseReason: reason } : {})}
        t={translatorFor("en")}
        onRemove={async () => true}
        onChange={async () => true}
      />,
    ),
  );
}

test("a paused queue says the turn's error over its prompts and offers one Resume", async () => {
  await draw(true, "429 rate limited");
  const note = host.querySelector(".acpmux-queue-paused");
  expect(note?.textContent).toContain("Paused after an error: 429 rate limited");
  expect(host.querySelectorAll(".acpmux-queue-resume").length).toBe(1);
  expect(host.textContent).not.toContain("Sends after this turn");
  expect(host.querySelector(".acpmux-queue-header")).toBeNull();
  // The note comes first, over the prompts it holds.
  expect(host.querySelector(".acpmux-composer-queue > li")?.className).toBe("acpmux-queue-paused");
});

test("a paused queue with no error to name still says it paused", async () => {
  await draw(true);
  expect(host.querySelector(".acpmux-queue-paused")?.textContent).toContain("Paused after an error");
  expect(host.textContent).not.toContain("Sends after this turn");
});

test("a queue that is not paused shows no note, no Resume and no header", async () => {
  await draw(false);
  expect(host.querySelector(".acpmux-queue-paused")).toBeNull();
  expect(host.querySelectorAll(".acpmux-queue-resume").length).toBe(0);
  expect(host.querySelector(".acpmux-queue-header")).toBeNull();
  expect(host.querySelectorAll(".acpmux-queued").length).toBe(2);
});

test("the reason is the error of the chat's latest failed turn", () => {
  const row = (id: string, kind: string, status?: string, error?: string) =>
    ({ id, version: 1, at: 1, kind, ...(status ? { status } : {}), ...(error ? { error } : {}) }) as AcpmuxRow;
  expect(
    queuePauseReason([
      row("a", "turnSummary", "failed", "old failure"),
      row("b", "turnSummary", "failed", "overloaded"),
    ]),
  ).toBe("overloaded");
  // A prompt sent meanwhile ran and ended well; the queue stays held for the earlier failure.
  expect(
    queuePauseReason([row("a", "turnSummary", "failed", "old failure"), row("b", "turnSummary", "completed")]),
  ).toBe("old failure");
  expect(queuePauseReason([row("a", "turnSummary", "failed", "  network down \n"), row("b", "assistant")])).toBe(
    "network down",
  );
  expect(queuePauseReason([row("a", "turnSummary", "failed")])).toBeUndefined();
  expect(queuePauseReason([])).toBeUndefined();
});
