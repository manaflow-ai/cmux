// Review by doing (cmuxterm-hq#23817): a reviewer's interaction with a running candidate, kept as a
// small JSON file that replays against any head and becomes a regression test.
//
// A recording is pinned to the exact head it was made on (`sha`) and names the surface it ran on: a
// gallery entry and variant, the same real component with fixture data the gallery and its health
// check use (src/gallery/ENTRIES.md). Steps use the gallery's play targets (src/gallery/play.ts
// `PlayTarget`): by role and accessible name, test id, text or CSS selector, never coordinates, so a
// recording survives layout changes that keep the meaning. `expect` is the reviewer's point: what
// should be true after the steps. The reviewer edits it; nothing else in the file is free text.
//
// Privacy: `type` steps keep only fixture text the reviewer typed into the candidate. The recorder
// (recorder.js) never reads password fields and records no navigation or page outside the stage.

export const RECORDING_SCHEMA = "cmux.review-recording.v1";

export type Target =
  | { role: string; name?: string; exact?: boolean }
  | { testId: string }
  | { text: string }
  | { selector: string };

export type Step =
  | { click: Target }
  | { hover: Target }
  | { type: string; into?: Target }
  | { press: string }
  /**
   * A press, a move by (dx, dy) in CSS px, and a release: a resize grip or a slider. `from` presses
   * just inside that edge or corner of the target (a popup's resize edge) instead of its center.
   */
  | { drag: Target; dx: number; dy: number; from?: Edge };

export const EDGES = [
  "top",
  "bottom",
  "left",
  "right",
  "top-left",
  "top-right",
  "bottom-left",
  "bottom-right",
] as const;
export type Edge = (typeof EDGES)[number];

export type Expectation = {
  target: Target;
  /** Default `visible`. `absent` means no element matches (or none is visible). */
  state?: "visible" | "absent";
  /** The element's text contains this. */
  text?: string;
  /** Attribute values the element must carry. */
  attr?: Record<string, string>;
  /** Its rendered box, CSS px, inclusive. */
  box?: { minWidth?: number; maxWidth?: number; minHeight?: number; maxHeight?: number };
};

export type Recording = {
  schema: typeof RECORDING_SCHEMA;
  /** One line: what the reviewer saw wrong, in their words. */
  title: string;
  /** The exact head it was recorded on (40 hex). Replays elsewhere are refused unless allowed. */
  sha: string;
  surface: {
    entry: string;
    variant?: string;
    opts?: string;
    width?: number;
    height?: number;
    colorScheme?: "light" | "dark";
  };
  steps: Step[];
  expect: Expectation[];
  /** Optional: the PR or session the observation goes to. */
  route?: { pr?: string; session?: string };
};

const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

function readTarget(value: unknown, where: string): Target {
  if (!isObject(value)) throw new Error(`${where}: a target is an object`);
  if (typeof value.role === "string")
    return {
      role: value.role,
      ...(typeof value.name === "string" ? { name: value.name } : {}),
      ...(value.exact === true ? { exact: true } : {}),
    };
  if (typeof value.testId === "string") return { testId: value.testId };
  if (typeof value.text === "string") return { text: value.text };
  if (typeof value.selector === "string") return { selector: value.selector };
  throw new Error(`${where}: a target names role, testId, text or selector`);
}

function readStep(value: unknown, index: number): Step {
  const where = `steps[${index}]`;
  if (!isObject(value)) throw new Error(`${where}: a step is an object`);
  if ("click" in value) return { click: readTarget(value.click, where) };
  if ("hover" in value) return { hover: readTarget(value.hover, where) };
  if (typeof value.type === "string")
    return { type: value.type, ...(value.into ? { into: readTarget(value.into, where) } : {}) };
  if (typeof value.press === "string") return { press: value.press };
  if ("drag" in value && typeof value.dx === "number" && typeof value.dy === "number")
    return {
      drag: readTarget(value.drag, where),
      dx: value.dx,
      dy: value.dy,
      ...((EDGES as readonly unknown[]).includes(value.from) ? { from: value.from as Edge } : {}),
    };
  throw new Error(`${where}: one of click, hover, type, press, drag`);
}

/** A recording from parsed JSON, or a thrown error naming the first bad field. */
export function readRecording(value: unknown): Recording {
  if (!isObject(value) || value.schema !== RECORDING_SCHEMA) throw new Error(`not a ${RECORDING_SCHEMA} file`);
  if (typeof value.sha !== "string" || !/^[0-9a-f]{40}$/.test(value.sha)) throw new Error("sha: 40 hex digits");
  const surface = value.surface;
  if (!isObject(surface) || typeof surface.entry !== "string") throw new Error("surface.entry: a gallery entry id");
  if (!Array.isArray(value.steps)) throw new Error("steps: a list");
  if (!Array.isArray(value.expect) || value.expect.length === 0) throw new Error("expect: at least one");
  return {
    schema: RECORDING_SCHEMA,
    title: typeof value.title === "string" ? value.title : "",
    sha: value.sha,
    surface: surface as Recording["surface"],
    steps: value.steps.map(readStep),
    expect: value.expect.map((item, index) => {
      if (!isObject(item)) throw new Error(`expect[${index}]: an object`);
      return { ...(item as Expectation), target: readTarget(item.target, `expect[${index}]`) };
    }),
    ...(isObject(value.route) ? { route: value.route as Recording["route"] } : {}),
  };
}

/**
 * Whether a recording may replay on `head`. A recording says what was wrong on one head; on another
 * it is a different claim, so a replay names the head it means (`allow`: the candidate's new head,
 * or the base it is compared with). Returns the refusal, or undefined.
 */
export function headRefusal(recording: Recording, head: string, allow: string[] = []): string | undefined {
  if (head === recording.sha || allow.includes(head)) return undefined;
  return `stale head: recorded on ${recording.sha.slice(0, 12)}, this is ${head.slice(0, 12)}; pass --head ${head.slice(0, 12)} to replay it here on purpose`;
}
