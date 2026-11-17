import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { WorkedFor } from "../conversation/TurnRows";
import { PullRequestChip } from "../header/PullRequestChip";
import type { HeaderPullRequest } from "../header/headerState";
import type { AcpmuxRow } from "../model";
import { endFinishMoment, startFinishMoment } from "./finishMoments";
import { settleReact } from "../../../../test/support/domTeardown";

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
// Each global as it was before the test, or absent: a global the test added is deleted afterwards, not
// set to undefined, so the next file starts with none (test/support/leakDetector.ts).
const saved = new Map<string, { value: unknown } | undefined>();

beforeEach(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  for (const key of KEYS) saved.set(key, key in scope ? { value: scope[key] } : undefined);
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

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  act(() => endFinishMoment());
  await settleReact();
  dom.window.close();
  for (const key of KEYS) {
    const before = saved.get(key);
    if (before) scope[key] = before.value;
    else delete scope[key];
  }
});

const draw = (node: React.ReactNode) => {
  root ??= createRoot(dom.window.document.getElementById("root")!);
  act(() => root!.render(node));
  return dom.window.document;
};

const worked = (id: string, at: number) =>
  ({ id, version: 1, at, kind: "worked", durationMs: 45_000, status: "completed" }) as unknown as AcpmuxRow;

test("a long turn's end draws no done flash on its Worked for row, as Codex draws none (Lucas, 2026-11-14)", () => {
  const doc = draw(<WorkedFor row={worked("new", 499_500)} expanded={false} onToggle={() => undefined} />);
  act(() => void startFinishMoment({ kind: "turn", session: "s", turnStartedAt: 500_000 }, true));
  const row = doc.querySelector(".cv-worked")!;
  expect(row.hasAttribute("data-finish")).toBe(false);
  expect(row.querySelector("svg:not(.cv-worked__chevron)")).toBeNull();
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
