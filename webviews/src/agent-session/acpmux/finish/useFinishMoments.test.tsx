import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { setChatDisplay } from "../chatDisplay";
import type { HeaderPullRequest } from "../header/headerState";
import type { AcpmuxRow } from "../model";
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
// The header's pull request is the chat's own read unless a test says it is still the last chat's.
const render = (props: Props) => {
  root ??= createRoot(dom.window.document.getElementById("root")!);
  act(() => root!.render(<Probe pullRequestSession={props.session} {...props} />));
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

test("a long turn the person stopped ends with no moment and no sound (review F2)", () => {
  setChatDisplay({ [FINISH_SOUND_KEY]: true });
  render({ session: "s", working: true, turnStartedAtMs: Date.now() - 60_000 });
  render({ session: "s", working: true, turnStartedAtMs: Date.now() - 60_000, stopping: true });
  render({ session: "s", working: false });
  expect(finishMoment()).toBeUndefined();
  expect(sounds).toEqual([]);
  // The next turn, not stopped, has its moment again.
  render({ session: "s", working: true, turnStartedAtMs: Date.now() - 40_000 });
  render({ session: "s", working: false });
  expect(finishMoment()?.kind).toBe("turn");
});

test("a refused Stop leaves the turn running, and its later end has its moment", () => {
  setChatDisplay({ [FINISH_SOUND_KEY]: true });
  const start = Date.now() - 60_000;
  render({ session: "s", working: true, turnStartedAtMs: start });
  render({ session: "s", working: true, turnStartedAtMs: start, stopping: true });
  render({ session: "s", working: true, turnStartedAtMs: start });
  render({ session: "s", working: false });
  expect(finishMoment()?.kind).toBe("turn");
  expect(sounds).toEqual([{ kind: "turn" }]);
});

test("another chat on the same pull request starts from its own first read", () => {
  render({ session: "s", working: false, pullRequest: pr("open", "pending") });
  render({ session: "t", working: false, pullRequest: pr("merged", "passing") });
  expect(finishMoment()).toBeUndefined();
});

test("the last chat's pull request, still in the header after a switch, is no baseline (review 4 F1)", () => {
  setChatDisplay({ [FINISH_SOUND_KEY]: true });
  render({ session: "s", working: false, pullRequest: pr("open", "pending") });
  // Switched to t: the header shows s's read until t's tab state lands.
  render({ session: "t", working: false, pullRequest: pr("open", "pending"), pullRequestSession: "s" });
  // t's own read of the same pull request, merged: its first read, no transition.
  render({ session: "t", working: false, pullRequest: pr("merged", "passing") });
  expect(finishMoment()).toBeUndefined();
  expect(sounds).toEqual([]);
  // From there t's reads compare with its own.
  render({ session: "t", working: false, pullRequest: { ...pr("open", "passing"), url: "https://github.com/o/r/pull/8" } });
  render({ session: "t", working: false, pullRequest: { ...pr("merged", "passing"), url: "https://github.com/o/r/pull/8" } });
  expect(finishMoment()?.kind).toBe("merged");
});

test("a long turn that failed ends with no moment and no sound (review 4 F2)", () => {
  setChatDisplay({ [FINISH_SOUND_KEY]: true });
  const start = Date.now() - 60_000;
  const summary = (at: number, status: string) =>
    ({ id: `summary-${at}`, version: 1, at, kind: "turnSummary", status }) as unknown as AcpmuxRow;
  // An older turn's success is not this turn's end.
  const rows = [summary(start - 90_000, "completed"), summary(start + 59_000, "failed")];
  render({ session: "s", working: true, turnStartedAtMs: start, rows: rows.slice(0, 1) });
  render({ session: "s", working: false, rows });
  expect(finishMoment()).toBeUndefined();
  expect(sounds).toEqual([]);
  // No summary row of its own yet reads as a success.
  render({ session: "s", working: true, turnStartedAtMs: Date.now() - 40_000, rows: rows.slice(0, 1) });
  render({ session: "s", working: false, rows: rows.slice(0, 1) });
  expect(finishMoment()?.kind).toBe("turn");
});

test("a turn's end under a merge still showing leaves the sound to the merge", () => {
  setChatDisplay({ [FINISH_SOUND_KEY]: true });
  render({ session: "s", working: true, turnStartedAtMs: Date.now() - 60_000, pullRequest: pr("open", "pending") });
  render({ session: "s", working: true, turnStartedAtMs: Date.now() - 60_000, pullRequest: pr("merged", "passing") });
  render({ session: "s", working: false, pullRequest: pr("merged", "passing") });
  expect(finishMoment()?.kind).toBe("merged");
  expect(sounds).toEqual([{ kind: "merged" }]);
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
