// l10n-allow-file: test fixture row ids, not shipped UI.
// The turn's end fold never plays across a message the person sent: when the swap takes away work
// drawn above one of their messages (a steer, a prompt waiting under the turn), or one of their
// messages, it applies in the frame it renders. Leo, 2026-11-22: "it tries to fold and it folds up
// past my [...] steer ... the way i see that [...] passing over my [...] message is so dumb."
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { foldCrossesPerson, type TurnEndCapture } from "./turnEndFold";
import { LIVE_THINKING } from "./turns";

const drawn = (id: string, top: number, extra: { person?: boolean; gone?: boolean } = {}) => ({
  id,
  top,
  height: 30,
  ...(extra.person && { person: true }),
  ...(extra.gone && { copy: {} as HTMLElement }),
});
const capture = (...rows: ReturnType<typeof drawn>[]): TurnEndCapture => ({ rows, scrollTop: 0 });

test("a fold plays only under the person's newest message: never across one, never taking one", () => {
  // A turn's end with the prompt over its work: the fold plays.
  expect(
    foldCrossesPerson(
      capture(drawn("prompt", 0, { person: true }), drawn("run", 40, { gone: true }), drawn("answer", 80)),
    ),
  ).toBe(false);
  // Work above a steer goes with the work under it: the swap applies at once.
  expect(
    foldCrossesPerson(
      capture(
        drawn("prompt", 0, { person: true }),
        drawn("run-1", 40, { gone: true }),
        drawn("steer", 80, { person: true }),
        drawn("run-2", 120, { gone: true }),
        drawn("answer", 160),
      ),
    ),
  ).toBe(true);
  // The work above the steer stays as drawn, only the work under it goes: the fold plays.
  expect(
    foldCrossesPerson(
      capture(
        drawn("prompt", 0, { person: true }),
        drawn("run-1", 40),
        drawn("steer", 80, { person: true }),
        drawn("run-2", 120, { gone: true }),
        drawn("answer", 160),
      ),
    ),
  ).toBe(false);
  // A prompt queued under the running turn: the work above it goes at once.
  expect(
    foldCrossesPerson(
      capture(
        drawn("prompt", 0, { person: true }),
        drawn("run", 40, { gone: true }),
        drawn("next", 80, { person: true }),
      ),
    ),
  ).toBe(true);
  // The person's message itself leaving is never faded away.
  expect(foldCrossesPerson(capture(drawn("prompt", 0, { person: true, gone: true }), drawn("answer", 80)))).toBe(true);
  expect(foldCrossesPerson(capture(drawn("run", 40, { gone: true }), drawn("answer", 80)))).toBe(false);
});

// The same read off rows as the transcript draws them (VirtualTranscript.tsx `acpmux-row
// acpmux-<kind>`, with `acpmux-row--line` on another agent's message): a steered turn's end draws no
// copy and starts no animation; the same turn without the steer folds.
for (const steered of [true, false])
  test(`a turn's end ${steered ? "with a steer plays nothing" : "with no steer folds"}, read off the drawn rows`, async () => {
    const { JSDOM } = await import("jsdom");
    const { captureTurnEnd, playTurnEnd, settleTurnEnd } = await import("./turnEndFold");
    const dom = new JSDOM("<!doctype html><main></main>", { pretendToBeVisual: true });
    const thread = dom.window.document.querySelector<HTMLElement>("main")!;
    const proto = dom.window.HTMLElement.prototype;
    Object.defineProperty(proto, "offsetTop", {
      get() {
        return Number.parseFloat(this.style.top) || 0;
      },
    });
    Object.defineProperty(proto, "offsetHeight", {
      get() {
        return Number.parseFloat(this.style.height) || 0;
      },
    });
    proto.getBoundingClientRect = function () {
      const top = this.offsetTop;
      const height = this.offsetHeight;
      return { top, bottom: top + height, height, left: 0, right: 100, width: 100, x: 0, y: top, toJSON() {} };
    };
    let animations = 0;
    proto.animate = function () {
      animations += 1;
      return { cancel() {}, finish() {} } as Animation;
    };
    let top = 0;
    const draw = (id: string, kind: string, height: number, line = false) => {
      const node = dom.window.document.createElement("article");
      node.className = `acpmux-row acpmux-${kind}${line ? " acpmux-row--line" : ""}`;
      node.dataset.rowId = id;
      node.style.top = `${top}px`;
      node.style.height = `${height}px`;
      top += height;
      thread.append(node);
      return node;
    };
    const row = (id: string, kind: AcpmuxRow["kind"]): AcpmuxRow => ({ id, version: 1, at: 1, kind });
    draw("u", "user", 40);
    draw("working-u", "working", 34);
    draw("run-1", "activity", 60);
    // Another agent's message is a line, not the person's bubble: it never stops a fold.
    draw("in-1", "user", 24, true);
    if (steered) draw("s", "user", 40);
    draw("run-2", "activity", 60);
    draw("answer", "assistant", 50);
    draw(LIVE_THINKING, "thinking", 22);
    const after = [
      row("u", "user"),
      row("worked-u", "worked"),
      ...(steered ? [row("s", "user"), row("worked-s", "worked")] : []),
      row("answer", "assistant"),
    ];
    const capture = captureTurnEnd(thread, thread, after, "chat")!;
    expect(capture.rows.filter((entry) => entry.person).map((entry) => entry.id)).toEqual(steered ? ["u", "s"] : ["u"]);
    expect(foldCrossesPerson(capture)).toBe(steered);
    thread.replaceChildren();
    top = 0;
    for (const entry of after)
      draw(entry.id, entry.kind, entry.kind === "worked" ? 34 : entry.kind === "user" ? 40 : 50);
    const fold = playTurnEnd(thread, capture, "chat");
    try {
      if (steered) {
        expect(fold).toBeUndefined();
        expect(animations).toBe(0);
        expect(thread.querySelectorAll("[data-row-id]").length).toBe(after.length);
        expect(thread.hasAttribute("data-turn-end-folding")).toBe(false);
      } else {
        expect(fold).toBeDefined();
        expect(animations).toBeGreaterThan(0);
      }
    } finally {
      if (fold) settleTurnEnd(thread, fold);
      dom.window.close();
    }
  });
