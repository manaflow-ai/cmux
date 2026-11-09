// l10n-allow-file: test fixtures.
// Follow-ups to the composer hat holding still (#39142): a subagent that ended with no end time stops
// its clock where it ended instead of counting on forever, and the composer's Cloud environment pick
// keeps its identity across renders, so a pane event no longer draws the composer again through it.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";

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
afterAll(() => {
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
  // Two of the page clock's seconds go by: each would have drawn a running time again.
  const { subscribePageSecond } = await import("../src/ui/pageClock");
  await act(
    async () =>
      new Promise<void>((resolve) => {
        let seconds = 0;
        const stop = subscribePageSecond(() => {
          if (++seconds < 2) return;
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
