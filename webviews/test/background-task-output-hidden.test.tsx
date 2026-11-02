// A hidden page reads nothing (plans/cmux-next/resource-efficiency-DESIGN.md section 9, row 4): an
// open background task tray row read its process tail every 1.2 s for the row's life, hidden pages
// included. It now stops while the page is hidden and reads once when it shows again.
import { afterAll, beforeAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createElement } from "react";
import { createRoot } from "react-dom/client";

const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let visibility: "visible" | "hidden" = "visible";

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => visibility });
});

afterAll(() => {
  for (const [key, had, value] of saved)
    if (had) scope[key] = value;
    else delete scope[key];
  dom.window.close();
});

const { BackgroundTaskOutputContext, useLiveBackgroundTaskOutput } =
  await import("../src/agent-session/acpmux/conversation/backgroundTaskOutput");

// The cadence is the behavior, so the clock is fake: advance it, then let the reads' replies land.
async function advance(ms: number): Promise<void> {
  await act(async () => {
    jest.advanceTimersByTime(ms);
    for (let i = 0; i < 5; i += 1) await Promise.resolve();
  });
}

function setVisibility(next: "visible" | "hidden"): void {
  visibility = next;
  dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
}

test("an open tray row stops reading while the page is hidden and reads again once shown", async () => {
  jest.useFakeTimers();
  let lists = 0;
  const source = {
    listProcesses: async () => {
      lists += 1;
      return { processes: [{ id: "p1", toolCallId: "t1", state: "running" }] };
    },
    tailProcess: async () => ({ content: "out\n" }),
  };
  function Row() {
    useLiveBackgroundTaskOutput("t1", undefined, true);
    return null;
  }
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => {
    root.render(
      createElement(BackgroundTaskOutputContext.Provider, { value: { source, sessionId: "s1" } }, createElement(Row)),
    );
  });
  await advance(0);
  expect(lists).toBe(1);
  await advance(1_200);
  expect(lists).toBe(2);

  setVisibility("hidden");
  await advance(12_000);
  expect(lists).toBe(2);

  setVisibility("visible");
  await advance(1_200);
  expect(lists).toBe(3);

  await act(async () => root.unmount());
  await advance(12_000);
  expect(lists).toBe(3);
  jest.useRealTimers();
});
