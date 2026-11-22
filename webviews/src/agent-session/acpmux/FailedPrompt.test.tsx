import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { FailedPrompt } = await import("./FailedPrompt");
const { translate } = await import("./i18n");

async function render(row: Record<string, unknown>) {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () =>
    root.render(createElement(FailedPrompt, { row: { id: "local-p1", version: 1, at: 1, kind: "user", ...row } })),
  );
  return { container, unmount: () => act(async () => root.unmount()) };
}

/// A prompt that was not sent never stays a bubble with no reply: its row says why and offers
/// Retry, which sends that row's prompt again through the page's action.
test("a failed prompt's bubble says why and Retry sends it again", async () => {
  const retried: unknown[] = [];
  (dom.window as unknown as Record<string, unknown>).cmuxAcpmuxActions = {
    "chat.retryPrompt": async (params: Record<string, unknown>) => retried.push(params),
  };
  const { container, unmount } = await render({
    text: "hello",
    failed: true,
    error: translate("prompt.notSentGesture"),
  });
  const status = container.querySelector(".cv-user__status--failed")!;
  expect(status.textContent).toContain(translate("prompt.notSentGesture"));
  const retry = status.querySelector<HTMLButtonElement>("button")!;
  expect(retry.textContent).toBe(translate("turn.retry"));
  await act(async () => retry.click());
  expect(retried).toEqual([{ rowId: "local-p1" }]);
  await unmount();
});

test("a prompt that was sent shows no failure", async () => {
  const { container, unmount } = await render({ text: "hello", pending: true });
  expect(container.querySelector(".cv-user__status--failed")).toBeNull();
  await unmount();
});
