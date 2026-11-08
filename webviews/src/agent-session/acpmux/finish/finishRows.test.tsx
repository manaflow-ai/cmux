import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { WorkedFor } from "../conversation/TurnRows";
import { PullRequestChip } from "../header/PullRequestChip";
import type { HeaderPullRequest } from "../header/headerState";
import type { AcpmuxRow } from "../model";
import { endFinishMoment, startFinishMoment } from "./finishMoments";

let dom: JSDOM;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const KEYS = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = new Map<string, unknown>();

beforeEach(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  for (const key of KEYS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  act(() => endFinishMoment());
  dom.window.close();
  for (const key of KEYS) scope[key] = saved.get(key);
});

const draw = (node: React.ReactNode) => {
  root ??= createRoot(dom.window.document.getElementById("root")!);
  act(() => root!.render(node));
  return dom.window.document;
};

const worked = (id: string, at: number) =>
  ({ id, version: 1, at, kind: "worked", durationMs: 45_000, status: "completed" }) as unknown as AcpmuxRow;

test("the ended turn's Worked for row draws its check over the chevron; an older turn's row stays as it was", () => {
  const doc = draw(
    <>
      <WorkedFor row={worked("old", 100_000)} expanded={false} onToggle={() => undefined} />
      <WorkedFor row={worked("new", 499_500)} expanded={false} onToggle={() => undefined} />
    </>,
  );
  expect(doc.querySelectorAll("[data-finish]").length).toBe(0);
  act(() => void startFinishMoment({ kind: "turn", session: "s", turnStartedAt: 500_000 }, true));
  const rows = [...doc.querySelectorAll(".cv-worked")];
  expect(rows.map((row) => row.getAttribute("data-finish"))).toEqual([null, "turn"]);
  expect(rows[1]!.querySelector(".cv-finish-check")).not.toBeNull();
  expect(rows[0]!.querySelector(".cv-finish-check")).toBeNull();
  // The moment's end gives the row back exactly as it was.
  act(() => endFinishMoment());
  expect(doc.querySelectorAll("[data-finish], .cv-finish-check").length).toBe(0);
});

const pullRequest: HeaderPullRequest = {
  url: "https://github.com/o/r/pull/9",
  number: 9,
  title: "Ship it",
  state: "merged",
  review: "approved",
  mergeable: "",
  checks: { state: "passing", passed: 3, total: 3 },
  checkList: [],
};

test("a merge marks its pull request's chip and bursts from it; another pull request's moment does not", () => {
  const doc = draw(<PullRequestChip pullRequest={pullRequest} />);
  const chip = () => doc.querySelector(".acpmux-header-pr")!;
  act(() => void startFinishMoment({ kind: "merged", url: "https://github.com/o/r/pull/8" }, true));
  expect(chip().hasAttribute("data-finish")).toBe(false);
  act(() => void startFinishMoment({ kind: "merged", url: pullRequest.url }, true));
  expect(chip().getAttribute("data-finish")).toBe("merged");
  expect(chip().querySelectorAll(".acpmux-finish-burst > i").length).toBe(10);
  act(() => endFinishMoment());
  expect(chip().hasAttribute("data-finish")).toBe(false);
  expect(chip().querySelector(".acpmux-finish-burst")).toBeNull();
});

test("green checks mark the chip without a burst", () => {
  const doc = draw(<PullRequestChip pullRequest={{ ...pullRequest, state: "open" }} />);
  act(() => void startFinishMoment({ kind: "ci", url: pullRequest.url }, true));
  const chip = doc.querySelector(".acpmux-header-pr")!;
  expect(chip.getAttribute("data-finish")).toBe("ci");
  expect(chip.querySelector(".acpmux-finish-burst")).toBeNull();
});
