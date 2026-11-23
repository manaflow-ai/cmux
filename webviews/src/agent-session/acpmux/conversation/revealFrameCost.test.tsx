// l10n-allow-file: bench fixture replies, not shipped UI.
// What a reveal frame costs (transcript-motion-model.md step 6, "Typing"): with one 20,000-word
// reply streaming a word a frame, the milliseconds a frame takes. The same harness runs on any tree
// that has RevealedMarkdown and revealFrames, so it gives before and after numbers.
// REVEAL_COST=1 prints them.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, Profiler } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { RevealedMarkdown } from "./RevealedMarkdown";
import { revealFrames } from "./revealedMarkdownModel";
import { streamedReply } from "../loadFixture";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];
const savedFrames = { ...revealFrames };
let queued: ((now: number) => void)[] = [];
let requests = 0;
let commits = 0;

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
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
  queued = [];
  revealFrames.request = (callback) => {
    requests += 1;
    return queued.push(callback);
  };
  revealFrames.cancel = () => {};
  root = createRoot(dom.window.document.getElementById("root")!);
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

const show = (texts: string[]) =>
  act(() => {
    root!.render(
      <Profiler id="replies" onRender={() => (commits += 1)}>
        {texts.map((text, index) => (
          <RevealedMarkdown key={index} text={text} streaming artifactIdentity={`reply-${index}`} />
        ))}
      </Profiler>,
    );
  });

/// Runs one display frame at `now`; returns the frame callbacks it requested and the commits it made.
function frame(now: number): { requests: number; commits: number; ms: number } {
  const pending = queued;
  queued = [];
  requests = 0;
  commits = 0;
  const start = performance.now();
  act(() => {
    for (const callback of pending) callback(now);
  });
  return { requests, commits, ms: performance.now() - start };
}

const report = (name: string, value: unknown) => {
  if (process.env.REVEAL_COST) console.log(`REVEAL-COST ${name} ${JSON.stringify(value)}`);
};

test("a 20,000-word reply growing a word a frame: a frame's cost", () => {
  let text = "";
  for (let turn = 1; text.split(" ").length < 20_000; turn += 1) text += streamedReply(turn, 400);
  show([text]);
  // Let the whole reply reveal (the backlog shows fast), then time frames that each add a word.
  for (let now = 16; queued.length && now < 120_000; now += 16) frame(now);
  let now = 200_000;
  const ms: number[] = [];
  for (let index = 0; index < 40; index += 1) {
    text += index % 10 === 9 ? "\n\nA new paragraph" : " word";
    show([text]);
    now += 16;
    ms.push(frame(now).ms);
  }
  ms.sort((a, b) => a - b);
  report("reply-20k", { chars: text.length, frame_ms_p50: +ms[20]!.toFixed(2), frame_ms_p90: +ms[36]!.toFixed(2) });
  expect(ms.length).toBe(40);
});
