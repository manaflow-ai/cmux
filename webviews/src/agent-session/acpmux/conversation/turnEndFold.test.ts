// A turn's end is the update that takes the running turn's line away (turnEndFold.ts): only then
// does the end-of-turn fold play.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { endsTurn, hasLiveLine, turnEndLook } from "./turnEndFold";
import { LIVE_THINKING } from "./turns";

const row = (id: string, kind: AcpmuxRow["kind"] = "assistant"): AcpmuxRow => ({ id, version: 1, at: 1, kind });

test("the running turn's line near the end marks a turn that runs", () => {
  expect(hasLiveLine([row("u", "user"), row(LIVE_THINKING, "thinking")])).toBe(true);
  expect(hasLiveLine([row(LIVE_THINKING, "thinking"), row("date", "system")])).toBe(true);
  expect(hasLiveLine([row("u", "user"), row("a")])).toBe(false);
  // Far from the end it is not the running turn's line.
  expect(hasLiveLine([row(LIVE_THINKING, "thinking"), ...Array.from({ length: 8 }, (_, i) => row(`a${i}`))])).toBe(
    false,
  );
});

test("an update ends the turn only when it takes the line away", () => {
  const running = [row("u", "user"), row("work", "activity"), row(LIVE_THINKING, "thinking")];
  const ended = [row("u", "user"), row("worked-u", "worked"), row("answer")];
  expect(endsTurn(running, ended)).toBe(true);
  expect(endsTurn(running, running)).toBe(false);
  expect(endsTurn(running, [...running.slice(0, 2), row("more", "activity"), row(LIVE_THINKING, "thinking")])).toBe(
    false,
  );
  expect(endsTurn(ended, [...ended, row("b")])).toBe(false);
  expect(endsTurn(undefined, ended)).toBe(false);
  // The transcript cut and drawn again under new ids (Edit forks before the running prompt): the
  // line goes with the prompt, and no turn ended.
  expect(endsTurn(running, [row("u2", "user"), row("worked-u2", "worked"), row("answer")])).toBe(false);
  expect(endsTurn([row("u", "user"), row("p", "user"), row(LIVE_THINKING, "thinking")], [row("u", "user")])).toBe(
    false,
  );
});

test("a user line another agent or the inbox drew is not the turn's prompt", () => {
  // An incoming message's line (model.ts `isLineRow`) after the prompt regroups under a new id as the
  // turn ends: the prompt above it stays, so the turn ended.
  const incoming: AcpmuxRow = { ...row("in-1", "user"), incoming: { kind: "message" } as AcpmuxRow["incoming"] };
  const running = [row("u", "user"), row("work", "activity"), incoming, row(LIVE_THINKING, "thinking")];
  expect(
    endsTurn(running, [row("u", "user"), row("worked-u", "worked"), row("run-in-1", "messageRun"), row("answer")]),
  ).toBe(true);
  // The prompt itself going is still a cut transcript.
  expect(endsTurn(running, [row("u2", "user"), row("worked-u2", "worked"), row("answer")])).toBe(false);
});

test("the look comes from the nearest attribute, else the shipped collapse", () => {
  const node = { closest: () => ({ getAttribute: () => "clip" }) } as unknown as Element;
  expect(turnEndLook(node)).toBe("clip");
  expect(turnEndLook({ closest: () => null } as unknown as Element)).toBe("collapse");
  // The old looks, which faded the rows that went, are gone.
  expect(turnEndLook({ closest: () => ({ getAttribute: () => "fade" }) } as unknown as Element)).toBe("collapse");
});

test("a capture from another chat plays nothing and draws nothing of it", async () => {
  const { JSDOM } = await import("jsdom");
  const { playTurnEnd } = await import("./turnEndFold");
  const dom = new JSDOM("<!doctype html><div id=thread></div>", { pretendToBeVisual: true });
  const thread = dom.window.document.getElementById("thread")!;
  const reply = dom.window.document.createElement("div");
  reply.className = "acpmux-row";
  reply.dataset.rowId = "answer";
  thread.append(reply);
  const copy = dom.window.document.createElement("div");
  const capture = {
    rows: [
      { id: LIVE_THINKING, top: 80, copy },
      { id: "answer", top: 40 },
    ],
    scrollTop: 0,
    sessionId: "chat-a",
  };
  // Another chat shown in its place: nothing of chat A is drawn over it, and nothing plays.
  expect(playTurnEnd(thread, capture, "chat-b")).toBeUndefined();
  expect(thread.contains(copy)).toBe(false);
  expect(thread.hasAttribute("data-turn-end-folding")).toBe(false);
  dom.window.close();
});

test("the fold runs on one short clock, never grown, and holds every 120 Hz frame or snaps", async () => {
  // Leo, 2026-11-11, on the fold that ran the 180 ms settle and grew to 720 ms and past for a long move:
  // "it should not be slow. It should not look like a PowerPoint transition slide fade-in." Easing is
  // fine only if it's fast and holds 120 Hz; otherwise the fold snaps.
  const { TURN_END_FOLD_MS, TURN_END_FOLD_EASE, turnEndFoldEasing, turnEndFoldFrames } = await import("./turnEndFold");
  const { bezierAt, parseBezier } = await import("../../../ui/cubicBezier");
  const { currentChatMetrics } = await import("../chatDisplay");
  const { ARRIVAL_FRAME_LINES } = await import("./followChase");
  expect(TURN_END_FOLD_MS).toBe(120);
  expect(turnEndFoldFrames()).toBe(15);
  const bound = ARRIVAL_FRAME_LINES * currentChatMetrics().lineHeight + 1e-6;
  const frame = 1000 / 120;
  const curveOf = (easing: string) => (easing === "linear" ? ([0, 0, 1, 1] as const) : parseBezier(easing)!);
  for (const px of [4, 20, 60, 100, 150, 190]) {
    const easing = turnEndFoldEasing(px);
    expect(easing).toBeDefined();
    const curve = curveOf(easing!);
    const drawn = (t: number) => px * bezierAt(curve, Math.min(1, Math.max(0, t / TURN_END_FOLD_MS)));
    for (let t = 0; t < TURN_END_FOLD_MS; t += frame / 4)
      expect(drawn(t + frame) - drawn(t)).toBeLessThanOrEqual(bound);
  }
  // A short move eases out; a move the ease-out cannot hold at 120 Hz runs straight; one the straight
  // line cannot hold snaps (undefined), never runs longer.
  expect(turnEndFoldEasing(8)).toBe(TURN_END_FOLD_EASE);
  expect(turnEndFoldEasing(150)).toBe("linear");
  expect(turnEndFoldEasing(800)).toBeUndefined();
});
