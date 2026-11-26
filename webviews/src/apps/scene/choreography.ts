// `Particles {choreography}` (cmux-app-host js/ABI.md "Particles choreography"): the player that turns
// a `cmux.particles/1` document into dot positions at a time. Pure numbers, no DOM, so it is tested on
// its own and the canvas loop (SceneParticles.tsx) only asks it where the dots are. The host's Rust
// validator (cmux-app-host src/particles.rs) refuses an invalid document before it reaches here; the
// parse below still reads defensively and gives up (null) on anything it does not understand.
//
// Playback rules (the same in the native renderer, AppSceneChoreography.swift):
// - A frame's `dots` are `[x, y, scale]`, points from the node's centre (+y down); a dot keeps its
//   index across frames and phases, and a dot a frame does not list sits hidden at the centre.
// - Between two frames the renderer eases by the later frame's `ease`, else the phase's, else linear.
// - The first phase ever played starts on its first frame. A phase that follows another starts from
//   where the dots are: its first segment eases from the on-screen dots instead of from its frame at 0
//   (a phase whose frames all sit at 0 eases into them over its whole duration).
// - A generated phase (`sites`, `spawn`, `lifeFrames`) births a dot every `spawn.every` ms at the next
//   site of `order`; each lives `life` ms through `lifeFrames` (`centre`, `site`, or `between`, the
//   midpoint of the two). Repeating itself, it carries its live dots over; after another phase it
//   starts with none alive while the previous dots ease into the centre over the first spawn interval.
// - What plays: `phase` (that phase, looped) wins over `trigger` (`triggers[trigger]`, else
//   `triggers.cycle`, else the document's first phase looped). A list loops; `{intro, loop}` plays the
//   intro once, then loops `loop`. The trigger is read only when a phase ends: unchanged, the program
//   advances; changed, the dots hand off through the `lone` phase (when the document has one) and the
//   new program starts.

export type ChoreoDot = { x: number; y: number; s: number };

type Bezier = readonly [number, number, number, number];
type Spring = { response: number; dampingFraction: number };
export type ChoreoEase = { bezier: Bezier } | { spring: Spring } | "linear";

type Frame = { at: number; dots: ChoreoDot[]; ease?: ChoreoEase };
type LifeFrame = {
  at: number;
  pos: "centre" | "site" | "between";
  offset: [number, number];
  s: number;
  ease?: ChoreoEase;
};
type Generator = { sites: [number, number][]; every: number; order: number[]; life: number; lifeFrames: LifeFrame[] };
export type ChoreoPhase = { name: string; duration: number; ease?: ChoreoEase; frames: Frame[]; generator?: Generator };
type Program = { intro: string[]; loop: string[] };

export type Choreography = {
  shape: "circle" | "square";
  size: number;
  color: string;
  max: number;
  phases: Map<string, ChoreoPhase>;
  firstPhase: string;
  triggers: Map<string, Program>;
};

/** What the node asks to play: a phase by name (looped), or an acpmux tool kind or session state. */
export type ChoreoRequest = { phase?: string; trigger?: string };

const MAX_DOTS = 16;
const HIDDEN: ChoreoDot = { x: 0, y: 0, s: 0 };

// The curves of the Motion vocabulary (motionProps.ts CURVES, the CSS steps), as control points.
const NAMED_CURVES: Record<string, Bezier> = {
  easeIn: [0.42, 0, 1, 1],
  easeOut: [0, 0, 0.58, 1],
  easeInOut: [0.42, 0, 0.58, 1],
  smooth: [0.42, 0, 0.58, 1],
  snappy: [0, 0, 0.58, 1],
};

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);
const finite = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);

function parseEase(value: unknown): ChoreoEase | undefined | null {
  if (value === undefined) return undefined;
  if (value === "linear") return "linear";
  if (typeof value === "string") return NAMED_CURVES[value] ? { bezier: NAMED_CURVES[value] } : null;
  if (!isRecord(value)) return null;
  if (Array.isArray(value.bezier) && value.bezier.length === 4 && value.bezier.every(finite)) {
    return { bezier: value.bezier as unknown as Bezier };
  }
  if (isRecord(value.spring) && finite(value.spring.response)) {
    const damping = finite(value.spring.dampingFraction) ? value.spring.dampingFraction : 1;
    return { spring: { response: value.spring.response, dampingFraction: damping } };
  }
  return null;
}

/** The built-in formations, in units of the particle size (README of the schema: `row`, `pair`, ...). */
export function builtInFormation(name: string, size: number): ChoreoDot[] | undefined {
  const u = size;
  const dot = (x: number, y: number, s = 1): ChoreoDot => ({ x: x * u, y: y * u, s });
  switch (name) {
    case "row":
      return [dot(-2.2, 0), dot(0, 0), dot(2.2, 0)];
    case "pair":
      return [dot(-1.1, 0), dot(1.1, 0)];
    case "triangle":
      return [dot(0, -1.3), dot(-1.1, 0.65), dot(1.1, 0.65)];
    case "diagonal":
      return [dot(-1.1, -1.1), dot(1.1, 1.1)];
    case "grid2x2":
      return [dot(-1.45, -1.45), dot(1.45, -1.45), dot(-1.45, 1.45), dot(1.45, 1.45)];
    case "lone":
      return [dot(0, 0, 0.7)];
    case "satellites":
      return [dot(0, 0, 1.2), dot(-2, 0, 0.6), dot(2, 0, 0.6)];
    default:
      return undefined;
  }
}

function parseDots(value: unknown): ChoreoDot[] | null {
  if (!Array.isArray(value) || value.length > MAX_DOTS) return null;
  const dots: ChoreoDot[] = [];
  for (const entry of value) {
    if (!Array.isArray(entry) || entry.length !== 3 || !entry.every(finite)) return null;
    dots.push({ x: entry[0], y: entry[1], s: Math.max(0, entry[2]) });
  }
  return dots;
}

function parseProgram(value: unknown, phases: Map<string, ChoreoPhase>): Program | null {
  const names = (list: unknown): string[] | null =>
    Array.isArray(list) && list.every((name) => typeof name === "string" && phases.has(name))
      ? (list as string[])
      : null;
  if (Array.isArray(value)) {
    const loop = names(value);
    return loop && loop.length ? { intro: [], loop } : null;
  }
  if (!isRecord(value)) return null;
  const intro = value.intro === undefined ? [] : names(value.intro);
  const loop = names(value.loop);
  return intro && loop && loop.length ? { intro, loop } : null;
}

/** Reads a validated `cmux.particles/1` document, or null when it is not one. */
export function parseChoreography(value: unknown): Choreography | null {
  if (!isRecord(value) || value.$schema !== "cmux.particles/1") return null;
  const particle = isRecord(value.particle) ? value.particle : {};
  const size = finite(particle.size) && particle.size > 0 ? particle.size : null;
  if (size === null) return null;
  const max = finite(particle.max) ? Math.min(Math.max(Math.round(particle.max), 1), MAX_DOTS) : MAX_DOTS;
  const formations = isRecord(value.formations) ? value.formations : {};
  if (!isRecord(value.phases)) return null;
  const phases = new Map<string, ChoreoPhase>();
  for (const [name, raw] of Object.entries(value.phases)) {
    if (!isRecord(raw) || !finite(raw.duration) || raw.duration <= 0) return null;
    const ease = parseEase(raw.ease);
    if (ease === null) return null;
    const frames: Frame[] = [];
    if (raw.frames !== undefined) {
      if (!Array.isArray(raw.frames)) return null;
      for (const entry of raw.frames) {
        if (!isRecord(entry) || !finite(entry.at)) return null;
        const frameEase = parseEase(entry.ease);
        if (frameEase === null) return null;
        let dots: ChoreoDot[] | null | undefined;
        if (typeof entry.formation === "string") {
          dots =
            formations[entry.formation] !== undefined
              ? parseDots(formations[entry.formation])
              : builtInFormation(entry.formation, size);
        } else dots = parseDots(entry.dots);
        if (!dots) return null;
        frames.push({ at: entry.at, dots: dots.slice(0, max), ease: frameEase });
      }
    }
    let generator: Generator | undefined;
    if (raw.spawn !== undefined || raw.sites !== undefined || raw.lifeFrames !== undefined) {
      const spawn = isRecord(raw.spawn) ? raw.spawn : null;
      const sites = Array.isArray(raw.sites) ? raw.sites : null;
      const life = Array.isArray(raw.lifeFrames) ? raw.lifeFrames : null;
      if (!spawn || !sites || !life || !finite(spawn.every) || !finite(spawn.life) || !Array.isArray(spawn.order))
        return null;
      if (!sites.length || !sites.every((s) => Array.isArray(s) && s.length === 2 && s.every(finite))) return null;
      const order = spawn.order as unknown[];
      if (!order.length || !order.every((i) => finite(i) && i >= 0 && i < sites.length)) return null;
      const lifeFrames: LifeFrame[] = [];
      for (const entry of life) {
        if (!isRecord(entry) || !finite(entry.at) || !finite(entry.s)) return null;
        if (entry.pos !== "centre" && entry.pos !== "site" && entry.pos !== "between") return null;
        const offset =
          Array.isArray(entry.offset) && entry.offset.length === 2 && entry.offset.every(finite)
            ? ([entry.offset[0], entry.offset[1]] as [number, number])
            : ([0, 0] as [number, number]);
        const lifeEase = parseEase(entry.ease);
        if (lifeEase === null) return null;
        lifeFrames.push({ at: entry.at, pos: entry.pos, offset, s: entry.s, ease: lifeEase });
      }
      if (!lifeFrames.length || spawn.every <= 0) return null;
      generator = {
        sites: sites as [number, number][],
        every: spawn.every,
        order: order as number[],
        life: spawn.life,
        lifeFrames,
      };
    }
    if (!frames.length && !generator) return null;
    phases.set(name, { name, duration: raw.duration, ease, frames, generator });
  }
  const firstPhase = phases.keys().next().value;
  if (firstPhase === undefined) return null;
  const triggers = new Map<string, Program>();
  if (isRecord(value.triggers)) {
    for (const [kind, raw] of Object.entries(value.triggers)) {
      const program = parseProgram(raw, phases);
      if (!program) return null;
      triggers.set(kind, program);
    }
  }
  return {
    shape: particle.shape === "square" ? "square" : "circle",
    size,
    color: typeof particle.color === "string" ? particle.color : "accent",
    max,
    phases,
    firstPhase,
    triggers,
  };
}

// ---------------------------------------------------------------------------------------------
// Easing.

function cubic(a: number, b: number, t: number): number {
  // One axis of a cubic Bezier from (0,0) to (1,1) with control values a and b.
  const u = 1 - t;
  return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t;
}

function bezierAt(curve: Bezier, x: number): number {
  const [x1, y1, x2, y2] = curve;
  // Solve x(t) = x by bisection (monotonic in t because x1 and x2 are in [0, 1]); 24 steps is far
  // below a hundredth of a point at glyph sizes.
  let low = 0;
  let high = 1;
  let t = x;
  for (let step = 0; step < 24; step += 1) {
    const value = cubic(x1, x2, t);
    if (Math.abs(value - x) < 1e-6) break;
    if (value < x) low = t;
    else high = t;
    t = (low + high) / 2;
  }
  return cubic(y1, y2, t);
}

function springAt(spring: Spring, seconds: number): number {
  if (seconds <= 0) return 0;
  const w = (2 * Math.PI) / Math.max(spring.response, 0.001);
  const z = Math.min(Math.max(spring.dampingFraction, 0), 1);
  if (z < 1) {
    const wd = w * Math.sqrt(1 - z * z);
    return 1 - Math.exp(-z * w * seconds) * (Math.cos(wd * seconds) + ((z * w) / wd) * Math.sin(wd * seconds));
  }
  return 1 - Math.exp(-w * seconds) * (1 + w * seconds);
}

/** Progress (0 to 1, a spring may overshoot) `u` of the way through a segment `segmentMs` long. */
export function easeProgress(ease: ChoreoEase | undefined, u: number, segmentMs: number): number {
  if (u <= 0) return 0;
  if (u >= 1) return 1;
  if (!ease || ease === "linear") return u;
  if ("bezier" in ease) return bezierAt(ease.bezier, u);
  return springAt(ease.spring, (u * segmentMs) / 1000);
}

const mix = (a: number, b: number, p: number) => a + (b - a) * p;

function mixDots(from: readonly ChoreoDot[], to: readonly ChoreoDot[], p: number): ChoreoDot[] {
  const count = Math.max(from.length, to.length);
  const dots: ChoreoDot[] = [];
  for (let index = 0; index < count; index += 1) {
    const a = from[index] ?? HIDDEN;
    const b = to[index] ?? HIDDEN;
    dots.push({ x: mix(a.x, b.x, p), y: mix(a.y, b.y, p), s: Math.max(0, mix(a.s, b.s, p)) });
  }
  return dots;
}

// ---------------------------------------------------------------------------------------------
// Sampling one phase.

type Key = { at: number; dots: readonly ChoreoDot[]; ease?: ChoreoEase };

function keyframes(phase: ChoreoPhase, from: readonly ChoreoDot[] | null): Key[] {
  if (!from) return phase.frames;
  const later = phase.frames.filter((frame) => frame.at > 0);
  const keys: Key[] = [{ at: 0, dots: from }, ...later];
  if (keys.length === 1) {
    const last = phase.frames[phase.frames.length - 1]!;
    keys.push({ at: 1, dots: last.dots, ease: last.ease });
  }
  return keys;
}

function sampleKeys(keys: readonly Key[], phase: ChoreoPhase, p: number): ChoreoDot[] {
  if (!keys.length) return [];
  if (p <= keys[0]!.at) return keys[0]!.dots.map((dot) => ({ ...dot }));
  for (let index = 1; index < keys.length; index += 1) {
    const next = keys[index]!;
    if (p <= next.at) {
      const prev = keys[index - 1]!;
      const span = next.at - prev.at;
      const u = span > 0 ? (p - prev.at) / span : 1;
      return mixDots(prev.dots, next.dots, easeProgress(next.ease ?? phase.ease, u, span * phase.duration));
    }
  }
  return keys[keys.length - 1]!.dots.map((dot) => ({ ...dot }));
}

function lifeDot(generator: Generator, phase: ChoreoPhase, spawn: number, age: number): ChoreoDot {
  const frames = generator.lifeFrames;
  const site =
    generator.sites[
      generator.order[((spawn % generator.order.length) + generator.order.length) % generator.order.length]!
    ]!;
  const place = (frame: LifeFrame): ChoreoDot => {
    const [bx, by] = frame.pos === "centre" ? [0, 0] : frame.pos === "site" ? site : [site[0] / 2, site[1] / 2];
    return { x: bx + frame.offset[0], y: by + frame.offset[1], s: frame.s };
  };
  const p = age / generator.life;
  if (p <= frames[0]!.at) return place(frames[0]!);
  for (let index = 1; index < frames.length; index += 1) {
    const next = frames[index]!;
    if (p <= next.at) {
      const prev = frames[index - 1]!;
      const span = next.at - prev.at;
      const u = span > 0 ? (p - prev.at) / span : 1;
      const eased = easeProgress(next.ease ?? phase.ease, u, span * generator.life);
      return mixDots([place(prev)], [place(next)], eased)[0]!;
    }
  }
  return place(frames[frames.length - 1]!);
}

function sampleGenerated(
  phase: ChoreoPhase,
  generator: Generator,
  ms: number,
  from: readonly ChoreoDot[] | null,
  carry: boolean,
  max: number,
): ChoreoDot[] {
  const dots: ChoreoDot[] = [];
  // Spawns alive now: born at n * every, alive for `life`. Carrying over (the phase repeating
  // itself), spawns from before this pass count as if the phase had been playing all along.
  const first = carry ? Math.floor((ms - generator.life) / generator.every) + 1 : 0;
  const last = Math.floor(ms / generator.every);
  for (let spawn = Math.max(first, carry ? -Infinity : 0); spawn <= last && dots.length < max; spawn += 1) {
    const age = ms - spawn * generator.every;
    if (age < 0 || age >= generator.life) continue;
    // Spawns before this pass are the previous pass's, which used the order from its own start.
    const passSpawns = Math.max(1, Math.round(phase.duration / generator.every));
    const index = spawn >= 0 ? spawn : spawn + passSpawns * Math.ceil(-spawn / passSpawns);
    dots.push(lifeDot(generator, phase, index, age));
  }
  if (from && !carry && ms < generator.every) {
    const gathered = mixDots(
      from,
      [],
      easeProgress(phase.ease ?? { bezier: NAMED_CURVES.easeInOut! }, ms / generator.every, generator.every),
    );
    for (const dot of gathered) if (dots.length < max && dot.s > 0) dots.push(dot);
  }
  return dots;
}

/**
 * Where the dots of `phase` are `ms` into it. `from` is where the previous phase left them (null on
 * the first phase played); `carry` is true when the phase repeats itself.
 */
export function samplePhase(
  doc: Choreography,
  phase: ChoreoPhase,
  ms: number,
  from: readonly ChoreoDot[] | null,
  carry = false,
): ChoreoDot[] {
  const clamped = Math.min(Math.max(ms, 0), phase.duration);
  if (phase.generator) return sampleGenerated(phase, phase.generator, clamped, from, carry, doc.max);
  return sampleKeys(keyframes(phase, from), phase, clamped / phase.duration).slice(0, doc.max);
}

// ---------------------------------------------------------------------------------------------
// The player.

function programFor(doc: Choreography, request: ChoreoRequest): { key: string; program: Program } {
  if (request.phase && doc.phases.has(request.phase)) {
    return { key: `phase:${request.phase}`, program: { intro: [], loop: [request.phase] } };
  }
  const trigger = request.trigger && doc.triggers.has(request.trigger) ? request.trigger : "cycle";
  const program = doc.triggers.get(trigger);
  if (program) return { key: `trigger:${trigger}`, program };
  return { key: "first", program: { intro: [], loop: [doc.firstPhase] } };
}

/** The phase at position `index` of a program (intro first, then the loop forever). */
function programPhase(program: Program, index: number): string {
  if (index < program.intro.length) return program.intro[index]!;
  return program.loop[(index - program.intro.length) % program.loop.length]!;
}

/** The longest stall the player catches up phase by phase; past it, it restarts the program. */
const MAX_CATCH_UP_MS = 60_000;

export class ChoreographyPlayer {
  private request: ChoreoRequest = {};
  private key = "";
  private program: Program = { intro: [], loop: [] };
  private index = 0;
  private phase: ChoreoPhase;
  private start: number;
  private from: ChoreoDot[] | null = null;
  private carry = false;
  /** After a hand-off through `lone`, the program that starts next. */
  private pending: { key: string; program: Program } | null = null;

  constructor(
    readonly doc: Choreography,
    request: ChoreoRequest,
    now: number,
  ) {
    this.request = request;
    const next = programFor(doc, request);
    this.key = next.key;
    this.program = next.program;
    this.phase = doc.phases.get(programPhase(this.program, 0))!;
    this.start = now;
  }

  /** What the node asks for now; read only when the playing phase ends. */
  setRequest(request: ChoreoRequest): void {
    this.request = request;
  }

  /** The phase playing at the last `sample` and when it started (ms, the caller's clock). */
  get current(): { phase: string; start: number } {
    return { phase: this.phase.name, start: this.start };
  }

  /** The dots to draw at `now` (ms, the same clock as the constructor's), advancing phases as they end. */
  sample(now: number): ChoreoDot[] {
    if (now - this.start > MAX_CATCH_UP_MS) this.restart(now);
    while (now - this.start >= this.phase.duration) this.advance();
    return samplePhase(this.doc, this.phase, now - this.start, this.from, this.carry);
  }

  /** The still drawn when motion is off or reduced: the first frame of what would play. */
  still(): ChoreoDot[] {
    const { program } = programFor(this.doc, this.request);
    const phase = this.doc.phases.get(programPhase(program, 0))!;
    return samplePhase(this.doc, phase, 0, null, false);
  }

  private restart(now: number): void {
    const next = programFor(this.doc, this.request);
    this.key = next.key;
    this.program = next.program;
    this.index = 0;
    this.pending = null;
    this.phase = this.doc.phases.get(programPhase(this.program, 0))!;
    this.start = now;
    this.from = null;
    this.carry = false;
  }

  private advance(): void {
    const ended = this.phase;
    const end = this.start + ended.duration;
    const left = samplePhase(this.doc, ended, ended.duration, this.from, this.carry);
    let name: string;
    const next = programFor(this.doc, this.request);
    if (this.pending) {
      // The hand-off dot played; the waiting program starts (with the newest request).
      this.key = next.key;
      this.program = next.program;
      this.index = 0;
      this.pending = null;
      name = programPhase(this.program, 0);
    } else if (next.key === this.key) {
      this.index += 1;
      // Keep the index bounded: past the intro the loop repeats.
      const loopLength = this.program.loop.length;
      if (this.index >= this.program.intro.length + loopLength) this.index -= loopLength;
      name = programPhase(this.program, this.index);
    } else if (this.doc.phases.has("lone") && ended.name !== "lone" && programPhase(next.program, 0) !== "lone") {
      this.pending = next;
      name = "lone";
    } else {
      this.key = next.key;
      this.program = next.program;
      this.index = 0;
      name = programPhase(this.program, 0);
    }
    const phase = this.doc.phases.get(name)!;
    this.carry = phase === ended;
    this.from = left;
    this.phase = phase;
    this.start = end;
  }
}
