import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { setChatDisplay } from "../chatDisplay";
import type { HeaderPullRequest } from "../header/headerState";
import { endFinishMoment, finishMoment } from "./finishMoments";
import { FINISH_SOUND_KEY, useFinishMoments } from "./useFinishMoments";

let dom: JSDOM;
let root: Root | undefined;
let sounds: unknown[] = [];
const scope = globalThis as Record<string, unknown>;
const KEYS = ["window", "document", "navigator", "HTMLElement", "Node", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = new Map<string, unknown>();

beforeEach(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  for (const key of KEYS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Node: dom.window.Node,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  sounds = [];
  (dom.window as unknown as { cmuxAcpmuxActions: Record<string, (p: unknown) => Promise<unknown>> }).cmuxAcpmuxActions =
    {
      "pane.finishSound": async (params) => void sounds.push(params),
    };
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  endFinishMoment();
  setChatDisplay({});
  dom.window.close();
  for (const key of KEYS) scope[key] = saved.get(key);
});

type Props = Parameters<typeof useFinishMoments>[0];
function Probe(props: Props) {
  useFinishMoments(props);
  return null;
}
const render = (props: Props) => {
  root ??= createRoot(dom.window.document.getElementById("root")!);
  act(() => root!.render(<Probe {...props} />));
};

const pr = (state: string, checks: string): HeaderPullRequest => ({
  url: "https://github.com/o/r/pull/7",
  number: 7,
  title: "t",
  state,
  review: "",
  mergeable: "",
  checks: { state: checks, passed: 1, total: 1 },
  checkList: [],
});

test("a long turn's end starts the turn moment for that turn, with its sound only when the setting is on", () => {
  const start = Date.now() - 45_000;
  render({ session: "s", working: true, turnStartedAtMs: start });
  // The snapshot drops the start as the turn ends; the hook kept it.
  render({ session: "s", working: false });
  expect(finishMoment()).toMatchObject({ kind: "turn", session: "s", turnStartedAt: start });
  expect(sounds).toEqual([]);

  endFinishMoment();
  setChatDisplay({ [FINISH_SOUND_KEY]: true });
  render({ session: "s", working: true, turnStartedAtMs: Date.now() - 31_000 });
  render({ session: "s", working: false });
  expect(sounds).toEqual([{ kind: "turn" }]);
});

test("a quick turn and a switch to another chat start nothing", () => {
  setChatDisplay({ [FINISH_SOUND_KEY]: true });
  render({ session: "s", working: true, turnStartedAtMs: Date.now() - 5_000 });
  render({ session: "s", working: false });
  expect(finishMoment()).toBeUndefined();
  render({ session: "s", working: true, turnStartedAtMs: Date.now() - 90_000 });
  render({ session: "t", working: false });
  expect(finishMoment()).toBeUndefined();
  expect(sounds).toEqual([]);
});

test("green checks then a merge each start their moment on the chip's pull request, with their sounds", () => {
  setChatDisplay({ [FINISH_SOUND_KEY]: true });
  render({ session: "s", working: false, pullRequest: pr("open", "pending") });
  expect(finishMoment()).toBeUndefined();
  render({ session: "s", working: false, pullRequest: pr("open", "passing") });
  expect(finishMoment()).toMatchObject({ kind: "ci", url: "https://github.com/o/r/pull/7" });
  render({ session: "s", working: false, pullRequest: pr("merged", "passing") });
  expect(finishMoment()?.kind).toBe("merged");
  expect(sounds).toEqual([{ kind: "ci" }, { kind: "merged" }]);
});

test("a hidden page gets no moment, and a turn's end there plays no sound of its own", () => {
  setChatDisplay({ [FINISH_SOUND_KEY]: true });
  Object.defineProperty(dom.window.document, "visibilityState", { value: "hidden", configurable: true });
  render({ session: "s", working: true, turnStartedAtMs: Date.now() - 60_000, pullRequest: pr("open", "pending") });
  render({ session: "s", working: false, pullRequest: pr("open", "pending") });
  expect(finishMoment()).toBeUndefined();
  expect(sounds).toEqual([]);
  // A merge still sounds: no notification covers it.
  render({ session: "s", working: false, pullRequest: pr("merged", "passing") });
  expect(finishMoment()).toBeUndefined();
  expect(sounds).toEqual([{ kind: "merged" }]);
});
