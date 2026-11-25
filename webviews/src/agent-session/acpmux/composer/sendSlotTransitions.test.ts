// Detector send-slot-transitions-complete (design/composer-send-slot.md). Leo, 2026-11-22: "idle to
// send to stop to whatever we need those to be like... known." Fails when a glyph or a state of the
// composer's send slot is added without its rows, when a reachable pair of states resolves to no
// morph, when a row's tokens leave the motion scale, or when SendSlotGlyph's morph choice
// (morphFrom) stops being what the table says. Every gallery morph set is checked the same way.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { MOTION_MS } from "../../../motion/scale.generated";
import { GAP_MS, MORPH_MS, morphFrom, SETTLE_MS, type SlotMemory } from "./sendSlotGlyphModel";
import {
  animates,
  SLOT_DRAWN,
  SLOT_GLYPHS,
  SLOT_LOOKS,
  SLOT_STATE_LIST,
  SLOT_TRANSITIONS,
  slotTransition,
  type SlotMorphSet,
} from "./sendSlotTransitions";
import { SLOT_VARIANTS } from "./sendSlotVariants";

const sorted = (values: Iterable<string>) => [...values].sort();
const sets: Array<[string, SlotMorphSet]> = [
  ["shipped", SLOT_TRANSITIONS],
  ...Object.entries(SLOT_VARIANTS).map(([id, variant]) => [`variant ${id}`, variant.set] as [string, SlotMorphSet]),
];

describe("send-slot-transitions-complete", () => {
  test("every glyph the slot draws is drawn by GlyphIcon", () => {
    const source = readFileSync(path.join(import.meta.dir, "SendSlotGlyph.tsx"), "utf8");
    const icon = source.slice(source.indexOf("export function GlyphIcon"), source.indexOf("/// The slot's glyph."));
    // `arrow` is GlyphIcon's fallback; every other glyph has its own branch.
    for (const glyph of SLOT_GLYPHS.filter((glyph) => glyph !== "arrow"))
      expect({ glyph, drawn: icon.includes(`glyph === "${glyph}"`) }).toEqual({ glyph, drawn: true });
  });

  for (const [name, set] of sets)
    describe(name, () => {
      test("every state draws a glyph in every look", () => {
        expect(sorted(Object.keys(set.glyphs))).toEqual(sorted(SLOT_STATE_LIST));
        for (const state of SLOT_STATE_LIST) {
          expect(sorted(Object.keys(set.glyphs[state]))).toEqual(sorted(SLOT_LOOKS));
          for (const look of SLOT_LOOKS) expect(SLOT_DRAWN).toContain(set.glyphs[state][look]);
        }
      });

      test("every ordered pair of glyphs has a row, with the motion scale's tokens", () => {
        expect(sorted(Object.keys(set.morphs))).toEqual(sorted(SLOT_DRAWN));
        for (const from of SLOT_DRAWN) {
          expect(sorted(Object.keys(set.morphs[from]))).toEqual(sorted(SLOT_DRAWN));
          for (const to of SLOT_DRAWN) {
            const row = set.morphs[from][to];
            const pair = `${from} -> ${to}`;
            expect({ pair, why: row.why.length > 0 }).toEqual({ pair, why: true });
            if (from === to) {
              expect({ pair, morph: row.morph }).toEqual({ pair, morph: "none" });
              continue;
            }
            expect({ pair, same: row.morph === "none" }).toEqual({ pair, same: false });
            if (!animates(row)) continue;
            // A morph needs a button to draw in: a glyph leaving with its button is instant.
            expect({ pair, intoNothing: to === "none" }).toEqual({ pair, intoNothing: false });
            // The send slot's layers run on --agent-motion-move, the scale's standard step.
            expect({ pair, step: row.step, ms: MOTION_MS[row.step] }).toEqual({ pair, step: "standard", ms: MORPH_MS });
            expect({ pair, ease: row.ease, reduced: row.reduced }).toEqual({ pair, ease: "ease-out", reduced: "swap" });
            if (row.when === "gap") expect({ pair, gapFrom: from }).toEqual({ pair, gapFrom: "none" });
          }
        }
      });

      test("every ordered pair of states has a row; every reachable one resolves to its morph", () => {
        expect(sorted(Object.keys(set.states))).toEqual(sorted(SLOT_STATE_LIST));
        for (const from of SLOT_STATE_LIST) {
          expect(sorted(Object.keys(set.states[from]))).toEqual(sorted(SLOT_STATE_LIST));
          for (const to of SLOT_STATE_LIST) {
            const row = set.states[from][to];
            expect(row.why.length).toBeGreaterThan(0);
            if (!row.reachable) continue;
            for (const look of SLOT_LOOKS) {
              const pair = `${from} -> ${to} (${look})`;
              const transition = slotTransition(set, from, to, look);
              expect({ pair, defined: transition !== undefined }).toEqual({ pair, defined: true });
              const changes = set.glyphs[from][look] !== set.glyphs[to][look];
              expect({ pair, still: transition!.morph === "none" }).toEqual({ pair, still: !changes });
            }
          }
        }
      });

      test("into and out of unsend, where the glyph changes and stays drawn, is the un-pop", () => {
        for (const look of SLOT_LOOKS)
          for (const other of SLOT_STATE_LIST) {
            for (const [from, to] of [
              [other, "unsend"],
              ["unsend", other],
            ] as const) {
              if (!set.states[from][to].reachable) continue;
              const a = set.glyphs[from][look];
              const b = set.glyphs[to][look];
              if (a === b || b === "none") continue;
              // Out of unsend into send-ready is the same glyph; every other drawn change is the un-pop.
              const pair = `${from} -> ${to} (${look})`;
              expect({ pair, morph: slotTransition(set, from, to, look)?.morph }).toEqual({ pair, morph: "unpop" });
            }
          }
      });

      test("SendSlotGlyph's choice (morphFrom) is the table's, for every reachable pair", () => {
        const at = 10_000;
        for (const from of SLOT_STATE_LIST)
          for (const to of SLOT_STATE_LIST) {
            if (!set.states[from][to].reachable) continue;
            for (const look of SLOT_LOOKS) {
              const a = set.glyphs[from][look];
              const b = set.glyphs[to][look];
              if (b === "none") continue; // no button: nothing is drawn, so nothing chooses
              const memory: SlotMemory = { scope: "chat", since: at - SETTLE_MS - 1 };
              if (a !== "none") Object.assign(memory, { glyph: a, state: from });
              // Leaving `sending` empty is the send's gap: its draft's glyph left a moment ago.
              else if (from === "sending") {
                const left = set.glyphs["send-ready"][look];
                if (left !== "none") Object.assign(memory, { left, leftAt: at - GAP_MS / 4 });
              }
              const row = slotTransition(set, from, to, look)!;
              const expected = animates(row) && (row.when !== "gap" || from === "sending") ? row.morph : undefined;
              const found = morphFrom(memory, "chat", b, at, to, set);
              const pair = `${from} -> ${to} (${look})`;
              expect({ pair, morph: found?.transition.morph }).toEqual({ pair, morph: expected });
            }
          }
      });
    });

  test("nothing morphs within SETTLE_MS of a chat switch, or across one", () => {
    const at = 10_000;
    const fresh: SlotMemory = { scope: "chat", since: at - SETTLE_MS + 1, glyph: "return", state: "send-ready" };
    expect(morphFrom(fresh, "chat", "stop", at, "stop")).toBeUndefined();
    const other: SlotMemory = { scope: "other", since: 0, glyph: "return", state: "send-ready" };
    expect(morphFrom(other, "chat", "stop", at, "stop")).toBeUndefined();
  });

  // Stop into an empty slot fades in, the send's own and a turn started elsewhere alike: it shows only
  // once the turn held (turnPresence.ts, #51225). A Stop that left and comes back is drawn at once.
  test("Stop grows in from an empty slot; a Stop that left and comes back is drawn at once", () => {
    const at = 10_000;
    const recent: SlotMemory = { scope: "chat", since: 0, left: "return", leftAt: at - GAP_MS + 1 };
    expect(morphFrom(recent, "chat", "stop", at, "stop")?.transition.morph).toBe("enter");
    const late: SlotMemory = { scope: "chat", since: 0, left: "return", leftAt: at - GAP_MS - 1 };
    expect(morphFrom(late, "chat", "stop", at, "stop")?.transition.morph).toBe("enter");
    const back: SlotMemory = { scope: "chat", since: 0, left: "stop", leftAt: at - 50 };
    expect(morphFrom(back, "chat", "stop", at, "stop")).toBeUndefined();
  });
});
