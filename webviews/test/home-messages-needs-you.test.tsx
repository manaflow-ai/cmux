// A Chief chat's pinned Needs you on the Messages page is the Feed page's own Needs you view
// (merge of cmux#37777 with #37378): the same rows, inline answers and "N more" as the Feed's
// `#/needs-you`, its actions sent as the host's needsYou.action, and nothing read once it unmounts.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MouseEvent",
  "KeyboardEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = names.map((name) => [name, scope[name]] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/home-messages/",
    pretendToBeVisual: true,
  });
  const win = dom.window as unknown as Record<string, unknown>;
  for (const name of names) scope[name] = name === "window" ? dom.window : win[name];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  scope.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  scope.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  scope.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
});

afterAll(() => {
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

const { createRoot } = await import("react-dom/client");
const { UiProvider } = await import("../src/ui/UiProvider");
const { FeedNeedsYou, NEEDS_YOU_ACTION } = await import("../src/pages/home-messages/cards/needsYou/FeedNeedsYou");
const { MockFeedProvider, sampleFeed } = await import("../src/pages/feed/mockProvider");
const { ACTION_RUN, FeedOps } = await import("../src/pages/feed/types");
type PageClient = import("../src/pages/shared/pageClient").PageClient;

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test("the pinned section is the Feed's Needs you: rows, answers, N more, and it stops reading when it goes", async () => {
  const feed = new MockFeedProvider(sampleFeed(Date.now()));
  const sent: string[] = [];
  // The Messages page's host: needsYou.action runs the Feed page's action (HomeMessagesHost.swift).
  const host: PageClient = {
    call: (op, params) => {
      sent.push(op);
      return feed.call(op === NEEDS_YOU_ACTION ? ACTION_RUN : op, params);
    },
    subscribe: (stream, onEvent) => feed.subscribe(stream, onEvent),
    handle: (op, handler) => feed.handle(op, handler),
  };
  const node = dom.window.document.getElementById("root")!;
  const root = createRoot(node);
  await act(async () => {
    root.render(
      <UiProvider container={node}>
        <FeedNeedsYou host={host} route="#/needs-you" />
      </UiProvider>,
    );
  });
  await act(settle);
  const all = (selector: string) => [...node.querySelectorAll<HTMLElement>(selector)];
  expect(node.querySelector(".feed-page")?.getAttribute("data-view")).toBe("needs-you");
  expect(node.querySelector(".feed-needs-title")!.textContent).toBe("Needs you");
  expect(all(".feed-needs-row")).toHaveLength(3);
  expect(feed.calls.find((call) => call.op === FeedOps.viewRead)?.params).toMatchObject({ layout: "needs_you" });

  // An inline answer is the Feed's own intent.
  const deny = all(".feed-needs-answers button").find((button) => button.textContent === "Deny");
  await act(async () => deny!.click());
  await act(settle);
  expect(sent).toContain(FeedOps.intent);

  // "N more" opens the Feed through the host's needsYou.action.
  await act(async () => node.querySelector<HTMLElement>(".feed-needs-more")!.click());
  expect(sent.at(-1)).toBe(NEEDS_YOU_ACTION);
  expect(feed.calls.at(-1)).toEqual({ op: ACTION_RUN, params: { action: "feed.openItem", args: {} } });

  // Gone (the setting off, another chat): nothing listens to the Feed any more.
  expect(feed.subscriberCount).toBeGreaterThan(0);
  act(() => root.unmount());
  expect(feed.subscriberCount).toBe(0);
});
