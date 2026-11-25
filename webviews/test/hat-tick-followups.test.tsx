// l10n-allow-file: test fixtures.
// Follow-ups to the composer hat holding still (#39142): a subagent that ended with no end time stops
// its clock where it ended instead of counting on forever, and the composer's Cloud environment pick
// keeps its identity across renders, so a pane event no longer draws the composer again through it.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { settleReact } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "Node",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  for (const key of keys)
    if (key !== "IS_REACT_ACT_ENVIRONMENT") scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
});
afterAll(async () => {
  await settleReact();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

const mount = async (node: React.ReactNode): Promise<{ root: Root; host: HTMLElement }> => {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  await act(async () => root.render(node));
  return { root, host };
};

test("an ended time with no end time stops where it ended", async () => {
  const { Elapsed } = await import("../src/agent-session/acpmux/subagents/Elapsed");
  const start = Date.now() - 5_000;
  let setEnded: (ended: boolean) => void = () => {};
  function Probe() {
    const [ended, set] = useState(false);
    setEnded = set;
    return <Elapsed since={start} ended={ended} />;
  }
  const { root, host } = await mount(<Probe />);
  await act(async () => setEnded(true));
  const stopped = host.textContent;
  expect(stopped).toBeTruthy();
  // Two of the page clock's seconds go by: each would have drawn a running time again. (A subscriber
  // is called once at once, with the clock's last sample: that call is not a second.)
  const { subscribePageSecond } = await import("../src/ui/pageClock");
  await act(
    async () =>
      new Promise<void>((resolve) => {
        let calls = 0;
        const stop = subscribePageSecond(() => {
          if (++calls < 3) return;
          stop();
          resolve();
        });
      }),
  );
  expect(host.textContent, "an ended subagent's time kept counting").toBe(stopped);
  await act(async () => root.unmount());
});

test("the environment pick is the same object until the chat or the pick changes", async () => {
  const { useChatCloudEnvironment } = await import("../src/agent-session/acpmux/CloudEnvironmentChip");
  const picks: unknown[] = [];
  let rerender: () => void = () => {};
  function Probe({ chat }: { chat: string }) {
    const [, set] = useState(0);
    rerender = () => set((n) => n + 1);
    picks.push(useChatCloudEnvironment(chat).pick);
    return null;
  }
  const { root } = await mount(<Probe chat="a" />);
  await act(async () => rerender());
  await act(async () => rerender());
  expect(new Set(picks).size, "a pane render made a new pick").toBe(1);
  await act(async () => root.render(<Probe chat="b" />));
  expect(new Set(picks).size).toBeGreaterThan(1);
  await act(async () => root.unmount());
});

test("a time that mounts between two ticks shows the same now as the times already there", async () => {
  const { usePageNow } = await import("../src/ui/pageClock");
  const shown = new Map<string, number>();
  function Now({ name }: { name: string }) {
    const now = usePageNow(true);
    shown.set(name, now);
    return String(now);
  }
  let open: (on: boolean) => void = () => {};
  function Probe() {
    const [opened, set] = useState(false);
    open = set;
    // The hat's header ticks; its lines mount when it opens, between two of the clock's seconds.
    return (
      <>
        <Now name="header" />
        {opened ? <Now name="line" /> : null}
      </>
    );
  }
  const { root } = await mount(<Probe />);
  const { subscribePageSecond } = await import("../src/ui/pageClock");
  // One second goes by, then part of the next: a fresh read now would be a later time than the header's.
  await act(
    async () =>
      new Promise<void>((resolve) => {
        let calls = 0;
        const stop = subscribePageSecond(() => {
          if (++calls < 2) return;
          stop();
          // Frames go by until the wall clock is 50 ms past the tick.
          const tick = Date.now();
          const frame = () => (Date.now() - tick >= 50 ? resolve() : requestAnimationFrame(frame));
          frame();
        });
      }),
  );
  await act(async () => open(true));
  expect(shown.get("line"), "a line that opened between ticks read a later now than its header").toBe(
    shown.get("header"),
  );
  await act(async () => root.unmount());
});
