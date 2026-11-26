// `Particles {choreography}` (ABI.md "Particles choreography"): the player plays a document of our
// own frame by frame. The fixture is a three-dot glyph shaped like a working indicator (a big middle dot
// between two small ones; the ends grow and spread while the middle shrinks; then back), plus a
// hand-off dot, a one-frame hide, a count-up intro and a generated two-site orbit.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  builtInFormation,
  ChoreographyPlayer,
  easeProgress,
  parseChoreography,
  samplePhase,
  type ChoreoDot,
  type Choreography,
} from "./choreography";

const FIXTURE = {
  $schema: "cmux.particles/1",
  particle: { shape: "circle", size: 4, color: "accent", max: 4 },
  phases: {
    lone: {
      duration: 400,
      ease: "easeInOut",
      frames: [
        { at: 0, dots: [[0, 0, 0.5]] },
        { at: 1, dots: [[0, 0, 0.5]] },
      ],
    },
    none: { duration: 200, frames: [{ at: 0, dots: [] }] },
    trade: {
      duration: 1000,
      ease: "easeInOut",
      frames: [
        {
          at: 0,
          dots: [
            [-6, 0, 0.6],
            [0, 0, 1.2],
            [6, 0, 0.6],
          ],
        },
        {
          at: 0.25,
          dots: [
            [-6, 0, 0.6],
            [0, 0, 1.2],
            [6, 0, 0.6],
          ],
        },
        {
          at: 0.5,
          dots: [
            [-8, 0, 1],
            [0, 0, 0.5],
            [8, 0, 1],
          ],
        },
        {
          at: 0.75,
          dots: [
            [-6, 0, 0.8],
            [0, 0, 0.8],
            [6, 0, 0.8],
          ],
          ease: "linear",
        },
        {
          at: 1,
          dots: [
            [-6, 0, 0.6],
            [0, 0, 1.2],
            [6, 0, 0.6],
          ],
        },
      ],
    },
    count: {
      duration: 400,
      ease: "linear",
      frames: [
        { at: 0, dots: [[0, 0, 0.5]] },
        {
          at: 0.5,
          dots: [
            [-3, 0, 1],
            [3, 0, 1],
          ],
        },
        { at: 1, formation: "row" },
      ],
    },
    orbit: {
      duration: 800,
      sites: [
        [-6, 0],
        [6, 0],
      ],
      spawn: { every: 400, order: [0, 1], life: 800 },
      lifeFrames: [
        { at: 0, pos: "centre", s: 0.2 },
        { at: 0.5, pos: "site", s: 1 },
        { at: 1, pos: "between", s: 0 },
      ],
    },
  },
  triggers: {
    read: ["orbit"],
    execute: ["trade"],
    sendMessage: { intro: ["count"], loop: ["trade"] },
    idle: ["none"],
    cycle: ["trade", "lone", "orbit", "lone"],
  },
};

const doc = (): Choreography => {
  const parsed = parseChoreography(FIXTURE);
  if (!parsed) throw new Error("fixture did not parse");
  return parsed;
};
const phase = (d: Choreography, name: string) => d.phases.get(name)!;
const close = (actual: ChoreoDot[], expected: [number, number, number][], digits = 3) => {
  expect(actual.length).toBe(expected.length);
  expected.forEach(([x, y, s], index) => {
    expect(actual[index]!.x).toBeCloseTo(x, digits);
    expect(actual[index]!.y).toBeCloseTo(y, digits);
    expect(actual[index]!.s).toBeCloseTo(s, digits);
  });
};
const inOut = (u: number) => easeProgress({ bezier: [0.42, 0, 0.58, 1] }, u, 0);

describe("easing", () => {
  test("curves pass through their ends and the standard ease-in-out is symmetric", () => {
    expect(easeProgress("linear", 0.3, 100)).toBeCloseTo(0.3, 6);
    expect(inOut(0)).toBe(0);
    expect(inOut(1)).toBe(1);
    expect(inOut(0.5)).toBeCloseTo(0.5, 4);
    expect(inOut(0.25) + inOut(0.75)).toBeCloseTo(1, 4);
    expect(inOut(0.25)).toBeLessThan(0.25);
    // A spring follows time, not the share: a short segment ends before it settles and snaps at 1.
    const spring = { spring: { response: 0.3, dampingFraction: 1 } } as const;
    expect(easeProgress(spring, 0.5, 2000)).toBeGreaterThan(0.99);
    expect(easeProgress(spring, 0.5, 100)).toBeLessThan(0.5);
    expect(easeProgress(spring, 1, 100)).toBe(1);
  });
});

describe("one phase", () => {
  test("the trading phase places every dot's offset and size at its frame times and eases between", () => {
    const d = doc();
    const trade = phase(d, "trade");
    // On the frames: exact.
    close(samplePhase(d, trade, 0, null), [
      [-6, 0, 0.6],
      [0, 0, 1.2],
      [6, 0, 0.6],
    ]);
    close(samplePhase(d, trade, 250, null), [
      [-6, 0, 0.6],
      [0, 0, 1.2],
      [6, 0, 0.6],
    ]);
    close(samplePhase(d, trade, 500, null), [
      [-8, 0, 1],
      [0, 0, 0.5],
      [8, 0, 1],
    ]);
    close(samplePhase(d, trade, 1000, null), [
      [-6, 0, 0.6],
      [0, 0, 1.2],
      [6, 0, 0.6],
    ]);
    // Held between 0 and 0.25 (equal frames), eased between 0.25 and 0.5 by the phase's ease-in-out.
    close(samplePhase(d, trade, 100, null), [
      [-6, 0, 0.6],
      [0, 0, 1.2],
      [6, 0, 0.6],
    ]);
    const p = inOut(0.5); // halfway through the 0.25..0.5 segment
    close(samplePhase(d, trade, 375, null), [
      [-6 - 2 * p, 0, 0.6 + 0.4 * p],
      [0, 0, 1.2 - 0.7 * p],
      [6 + 2 * p, 0, 0.6 + 0.4 * p],
    ]);
    // A frame's own ease shapes the segment that ends at it: 0.5..0.75 is linear.
    close(samplePhase(d, trade, 625, null), [
      [-7, 0, 0.9],
      [0, 0, 0.65],
      [7, 0, 0.9],
    ]);
  });

  test("a dot a frame does not list hides at the centre, and a named formation resolves in particle sizes", () => {
    const d = doc();
    const count = phase(d, "count");
    close(samplePhase(d, count, 0, null), [[0, 0, 0.5]]);
    // Halfway to the pair: dot 0 moves out, dot 1 grows out of the centre.
    close(samplePhase(d, count, 100, null), [
      [-1.5, 0, 0.75],
      [1.5, 0, 0.5],
    ]);
    close(
      samplePhase(d, count, 400, null),
      builtInFormation("row", 4)!.map((dot) => [dot.x, dot.y, dot.s]),
    );
    expect(builtInFormation("row", 4)![2]!.x).toBeCloseTo(8.8, 6);
  });

  test("a phase after another eases from the dots on screen instead of its first frame", () => {
    const d = doc();
    const lone = phase(d, "lone");
    const from: ChoreoDot[] = [
      { x: -6, y: 0, s: 0.6 },
      { x: 0, y: 0, s: 1.2 },
      { x: 6, y: 0, s: 0.6 },
    ];
    close(samplePhase(d, lone, 0, from), [
      [-6, 0, 0.6],
      [0, 0, 1.2],
      [6, 0, 0.6],
    ]);
    const p = inOut(0.5);
    close(samplePhase(d, lone, 200, from), [
      [-6 * (1 - p), 0, 0.6 + (0.5 - 0.6) * p],
      [0, 0, 1.2 * (1 - p)],
      [6 * (1 - p), 0, 0.6 * (1 - p)],
    ]);
    close(samplePhase(d, lone, 400, from), [
      [0, 0, 0.5],
      [0, 0, 0],
      [0, 0, 0],
    ]);
    // A phase whose frames all sit at 0 eases into them over its whole duration.
    const none = phase(d, "none");
    close(samplePhase(d, none, 100, from), [
      [-3, 0, 0.3],
      [0, 0, 0.6],
      [3, 0, 0.3],
    ]);
    close(samplePhase(d, none, 200, from), [
      [0, 0, 0],
      [0, 0, 0],
      [0, 0, 0],
    ]);
  });

  test("a generated phase births each dot at the centre, flies it to its site and gathers it back", () => {
    const d = doc();
    const orbit = phase(d, "orbit");
    // First pass, nothing carried: one dot born at 0 heading to site 0.
    close(samplePhase(d, orbit, 0, null), [[0, 0, 0.2]]);
    close(samplePhase(d, orbit, 200, null), [[-3, 0, 0.6]]);
    // 400 ms: dot 0 at its site, dot 1 born for site 1.
    close(samplePhase(d, orbit, 400, null), [
      [-6, 0, 1],
      [0, 0, 0.2],
    ]);
    // 600 ms: dot 0 halfway to the midpoint of site and centre, dot 1 halfway out.
    close(samplePhase(d, orbit, 600, null), [
      [-4.5, 0, 0.5],
      [3, 0, 0.6],
    ]);
    // Repeating itself, the previous pass's dot is still alive at 0.
    close(samplePhase(d, orbit, 0, null, true), [
      [6, 0, 1],
      [0, 0, 0.2],
    ]);
  });
});

describe("the player", () => {
  test("a trigger's phase loops; a changed trigger hands off through lone when the phase ends", () => {
    const d = doc();
    const player = new ChoreographyPlayer(d, { trigger: "execute" }, 0);
    expect(player.current.phase).toBe("trade");
    player.sample(999);
    player.setRequest({ trigger: "read" });
    // Read only at the hand-off: the trade still finishes.
    close(player.sample(500), [
      [-8, 0, 1],
      [0, 0, 0.5],
      [8, 0, 1],
    ]);
    player.sample(1000);
    expect(player.current).toEqual({ phase: "lone", start: 1000 });
    close(
      player.sample(1399.9),
      [
        [0, 0, 0.5],
        [0, 0, 0],
        [0, 0, 0],
      ],
      2,
    );
    player.sample(1400);
    expect(player.current).toEqual({ phase: "orbit", start: 1400 });
    // The orbit starts with nothing alive; the lone dot gathers into the centre over the first spawn.
    const start = player.sample(1400);
    expect(start[0]).toEqual({ x: 0, y: 0, s: 0.2 });
    expect(player.sample(2200 + 400).length).toBeGreaterThan(0);
    expect(player.current.phase).toBe("orbit");
  });

  test("an unknown kind plays cycle in order, and the cycle loops", () => {
    const d = doc();
    const player = new ChoreographyPlayer(d, { trigger: "switch_mode" }, 0);
    const seen: string[] = [];
    for (let t = 0; t < 2 * (1000 + 400 + 800 + 400); t += 50) {
      player.sample(t);
      if (seen[seen.length - 1] !== player.current.phase) seen.push(player.current.phase);
    }
    expect(seen).toEqual(["trade", "lone", "orbit", "lone", "trade", "lone", "orbit", "lone"]);
  });

  test("an intro plays once, then the loop repeats; a phase request loops that phase", () => {
    const d = doc();
    const player = new ChoreographyPlayer(d, { trigger: "sendMessage" }, 0);
    const seen: string[] = [];
    for (let t = 0; t < 3500; t += 50) {
      player.sample(t);
      if (seen[seen.length - 1] !== player.current.phase) seen.push(player.current.phase);
    }
    expect(seen).toEqual(["count", "trade"]);
    expect(player.current.start).toBe(3400);
    const jump = new ChoreographyPlayer(d, { phase: "trade", trigger: "read" }, 0);
    jump.sample(5000);
    expect(jump.current).toEqual({ phase: "trade", start: 5000 });
    // Repeating itself it starts from where it ended (its last frame equals its first here).
    close(jump.sample(5500), [
      [-8, 0, 1],
      [0, 0, 0.5],
      [8, 0, 1],
    ]);
  });

  test("the still is the first frame of what would play", () => {
    const d = doc();
    close(new ChoreographyPlayer(d, { trigger: "execute" }, 0).still(), [
      [-6, 0, 0.6],
      [0, 0, 1.2],
      [6, 0, 0.6],
    ]);
    close(new ChoreographyPlayer(d, { trigger: "idle" }, 0).still(), []);
  });

  test("a stall past a minute restarts the program instead of replaying it", () => {
    const player = new ChoreographyPlayer(doc(), { trigger: "execute" }, 0);
    player.sample(10 * 60_000);
    expect(player.current).toEqual({ phase: "trade", start: 10 * 60_000 });
  });

  test("the parse refuses what is not a document", () => {
    expect(parseChoreography(null)).toBeNull();
    expect(parseChoreography({ ...FIXTURE, $schema: "cmux.particles/2" })).toBeNull();
    expect(parseChoreography({ ...FIXTURE, particle: { size: 0 } })).toBeNull();
    expect(parseChoreography({ ...FIXTURE, triggers: { read: ["missing"] } })).toBeNull();
  });
});

// A document named by CMUX_PARTICLES_DOC (a look's own, kept out of the tree) plays through every
// phase with dot counts within its limit and finite places. Skipped when unset.
const external = process.env.CMUX_PARTICLES_DOC;
describe.skipIf(!external)("an external document", () => {
  test("plays every phase and trigger", () => {
    const d = parseChoreography(JSON.parse(readFileSync(external!, "utf8")));
    expect(d).not.toBeNull();
    for (const p of d!.phases.values()) {
      for (let t = 0; t <= p.duration; t += 10) {
        for (const dot of samplePhase(d!, p, t, null)) {
          expect(Number.isFinite(dot.x + dot.y + dot.s)).toBe(true);
        }
        expect(samplePhase(d!, p, t, null).length).toBeLessThanOrEqual(d!.max);
      }
    }
    for (const trigger of d!.triggers.keys()) {
      const player = new ChoreographyPlayer(d!, { trigger }, 0);
      for (let t = 0; t < 20_000; t += 16) player.sample(t);
    }
  });
});
