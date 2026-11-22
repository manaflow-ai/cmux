// l10n-allow-file: test fixture replies, not shipped UI.
// Ordering map O19 (design/chat-animation-ordering-map.md): a row mounted mid-reveal (streaming)
// unmounts when the reader scrolls it out of the window and mounts again when they come back.
// Leo, 2026-11-21: "some animations i think are still a bit... off. like, you finish some sort of tool
// call, things happen, things fold, stuff comes in at different times"; "i srolled up and then bac k
// down and it replayed an animation". The remount starts a new reveal from the whole text it holds
// (RM:71 `initial: displayText`): the words show at once, with no fade and no catch-up.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { RevealedMarkdown } from "./RevealedMarkdown";
import { revealFrames } from "./revealedMarkdownModel";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];
const savedFrames = { ...revealFrames };
let queued: ((now: number) => void)[] = [];

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
  });
  for (const key of KEYS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  container = dom.window.document.getElementById("root")!;
  queued = [];
  revealFrames.request = (callback) => queued.push(callback);
  revealFrames.cancel = () => {};
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  Object.assign(revealFrames, savedFrames);
  // fixed-wait: teardown only; React's scheduled work runs before its window closes
  await new Promise((resolve) => setTimeout(resolve, 20));
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  dom?.window.close();
  dom = undefined;
});

/// Runs display frames 16 ms apart from `from`, returning the reply's text after each.
function frames(from: number, count: number): string[] {
  const seen: string[] = [];
  for (let index = 0; index < count; index++) {
    const pending = queued;
    queued = [];
    act(() => {
      for (const callback of pending) callback(from + index * 16);
    });
    seen.push(container.querySelector(".cv-md")?.textContent ?? "");
  }
  return seen;
}

const render = (text: string, streaming: boolean, artifactIdentity?: string, messageAt?: number) =>
  act(() => {
    root!.render(
      <RevealedMarkdown text={text} streaming={streaming} artifactIdentity={artifactIdentity} messageAt={messageAt} />,
    );
  });

test("O19: a reply scrolled out mid-reveal and back shows whole at once, with no fade and no frames to wait for", () => {
  const reply = "The checks on the merged head are green and the release notes are ready to send now";
  root = createRoot(container);
  render("", true);
  render(reply, true);
  // Mid-reveal: some of it shows and the rest is still to come.
  const partial = frames(0, 3).at(-1)!;
  expect(partial.length).toBeLessThan(reply.length);
  act(() => root!.unmount());
  queued = [];
  root = createRoot(container);
  render(reply, true);
  expect(container.querySelector(".cv-md")?.textContent).toBe(reply);
  expect(container.querySelectorAll(".cv-fresh").length).toBe(0);
  // Settled: nothing waits for a frame to draw the rest.
  expect(queued.length).toBe(0);
  // Text that streams on after the remount still flows in whole words.
  render(`${reply} and more words after`, true);
  const next = frames(1000, 3).at(-1)!;
  expect(next.startsWith(reply)).toBe(true);
});
