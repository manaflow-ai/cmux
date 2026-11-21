// Waiting on me (useWaitingDay.ts): a home that went away while its read was out never writes that
// late reply over the day a newer home read since; the next home draws the newer day.
import { afterAll, beforeAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { useWaitingDay } from "../src/agent-session/acpmux/waiting/useWaitingDay";
import { localMidnight } from "../src/agent-session/acpmux/waiting/waitingModel";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=a></div><div id=b></div><div id=c></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  jest.useFakeTimers();
});

afterAll(() => {
  jest.useRealTimers();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

function dayOf(blockedMs: number) {
  const since = localMidnight(Date.now());
  return { since, until: Date.now(), workingMs: 0, blockedMs, lanes: [] };
}

test("a gone home's late reply does not overwrite a newer home's day", async () => {
  const replies: Array<(value: unknown) => void> = [];
  const read = () => new Promise<unknown>((resolve) => replies.push(resolve));
  const seen: Record<string, number | undefined> = {};
  function Probe({ name }: { name: string }) {
    seen[name] = useWaitingDay(read, "k", true)?.blockedMs;
    return null;
  }
  const mount = async (id: string): Promise<Root> => {
    const root = createRoot(document.getElementById(id) as HTMLElement);
    await act(async () => root.render(<Probe name={id} />));
    // The first read goes out on the next tick; the midnight timer stays far away.
    await act(async () => jest.advanceTimersByTime(1));
    return root;
  };
  const first = await mount("a");
  await act(async () => first.unmount());
  const second = await mount("b");
  expect(replies.length).toBe(2);
  await act(async () => replies[1]?.(dayOf(60_000)));
  expect(seen.b).toBe(60_000);
  // The first home's read comes back last, after that home is gone.
  await act(async () => replies[0]?.(dayOf(5_000)));
  expect(seen.b).toBe(60_000);
  await act(async () => second.unmount());
  const third = await mount("c");
  expect(seen.c).toBe(60_000);
  await act(async () => third.unmount());
});
