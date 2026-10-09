// Play steps: a variant's `play(ctx)` drives the real, mounted page into an interactive state
// (an open menu, a hover card, a typed prompt, a press-drag-release) before the stage is ready and
// before the matrix screenshots it. The same function runs in the shell (on open and on Replay)
// and in the matrix runner. Each ctx action is one step; around each step the stage measures:
//   - anchors: the entry's named elements; one the step did NOT target must not move or resize;
//   - layout shift: the CLS sum of the step and each shift with its source node;
//   - long frames: Long Animation Frames where the engine has them (Chromium), else rAF intervals;
//     frames over 16.7 ms are reported, and a frame over 33 ms fails ONLY from Long Animation
//     Frames data. rAF timing (headless WebKit on a CPU-only VM: software rendering) measures the
//     machine, not the page, so it only warns (coordinator 2026-10-07); real WebKit frame timing
//     comes from the native app on a fleet Mac.
// An entry may loosen a threshold only with a written `reason` (format.ts `checks`).
//
// Targets resolve on the real DOM: by role and accessible name, by test id, by text, or by a CSS
// selector. Input goes through a driver: the matrix runner installs `window.cmuxGalleryInput`
// (Playwright's trusted mouse and keyboard at the element's page coordinates); elsewhere the stage
// dispatches DOM events itself. Waiting is on events (DOM mutations, animation and transition ends,
// frames), never on a fixed time; a wait that never resolves fails at its cap.

export type PlayTarget =
  | { role: string; name?: string | RegExp }
  | { testId: string }
  | { text: string | RegExp }
  | { selector: string }
  /** A CSS selector matched in the document and in every open shadow root (a web component's rows). */
  | { deep: string };

export type PlayContext = {
  click(target: PlayTarget): Promise<void>;
  hover(target: PlayTarget): Promise<void>;
  focus(target: PlayTarget): Promise<void>;
  /** Moves a scroll container to an absolute offset or one of its edges. */
  scroll(target: PlayTarget, position: number | "top" | "bottom"): Promise<void>;
  /** Selects the rendered text inside a real component, as a user drag would. */
  selectText(target: PlayTarget): Promise<void>;
  /** Types into the focused element (or `target`, focused first). */
  type(text: string, target?: PlayTarget): Promise<void>;
  /** One key: `Enter`, `Escape`, `ArrowDown`, `Meta+k`. */
  press(key: string): Promise<void>;
  /** The press-drag-release gesture of macOS menus, in three steps. */
  pointer: {
    down(target: PlayTarget): Promise<void>;
    move(target: PlayTarget): Promise<void>;
    up(target: PlayTarget): Promise<void>;
  };
  /** Resolves when `condition` holds, re-checked on each DOM mutation and frame; part of the step before it. */
  waitFor(condition: () => boolean | Element | null | undefined, options?: { capMs?: number }): Promise<void>;
  /** Resolves `target` now (throws when it is not there). */
  find(target: PlayTarget): Element;
  document: Document;
};

export type Play = (ctx: PlayContext) => Promise<void>;

/** Strict by default; loosening a check needs a written reason. */
export type PlayChecks = {
  anchorMovePx?: { value: number; reason: string };
  longFrameFailMs?: { value: number; reason: string };
  layoutShiftMax?: { value: number; reason: string };
};

/** The interactions whose action-to-settled latency is useful in a gallery report. */
export type PlayAction = "click" | "key" | "press-drag" | "hover" | "focus" | "type" | "scroll" | "select";

export const DEFAULT_CHECKS = {
  anchorMovePx: 0,
  longFrameReportMs: 16.7,
  longFrameFailMs: 33,
  layoutShiftMax: 0,
} as const;

export type Rect = { x: number; y: number; width: number; height: number };
export type Shift = { value: number; sources: string[] };
export type StepReport = {
  step: string;
  /** The interaction that produced this step. Pointer down, move and up share press-drag. */
  action: PlayAction;
  /** Wall time from dispatching the action until the page settles. */
  settleMs: number;
  anchorMoves: { anchor: string; before: Rect | null; after: Rect | null; delta: number }[];
  layoutShift: number;
  shifts: Shift[];
  /** Durations in ms of the frames over 16.7 ms. */
  longFrames: number[];
  frameSource: "long-animation-frame" | "raf";
  status: "pass" | "warn" | "fail";
  problems: string[];
};
export type PlayReport = { status: "pass" | "warn" | "fail" | "none"; steps: StepReport[]; error?: string };

// ---- Pure rules (unit tested) ----

export function rectDelta(before: Rect | null, after: Rect | null): number {
  if (!before || !after) return before === after ? 0 : Number.POSITIVE_INFINITY;
  return Math.max(
    Math.abs(before.x - after.x),
    Math.abs(before.y - after.y),
    Math.abs(before.width - after.width),
    Math.abs(before.height - after.height),
  );
}

/** A step's verdict under the entry's checks. */
export function judgeStep(
  measured: Omit<StepReport, "status" | "problems">,
  checks: PlayChecks = {},
): Pick<StepReport, "status" | "problems"> {
  const problems: string[] = [];
  const movePx = checks.anchorMovePx?.value ?? DEFAULT_CHECKS.anchorMovePx;
  const failMs = checks.longFrameFailMs?.value ?? DEFAULT_CHECKS.longFrameFailMs;
  const shiftMax = checks.layoutShiftMax?.value ?? DEFAULT_CHECKS.layoutShiftMax;
  for (const move of measured.anchorMoves)
    if (move.delta > movePx) problems.push(`anchor ${move.anchor} moved ${move.delta.toFixed(1)} px (limit ${movePx})`);
  const failing = measured.longFrames.filter((ms) => ms > failMs);
  // Only Long Animation Frames data gates; rAF timing on a software-rendered VM only warns.
  if (failing.length && measured.frameSource === "long-animation-frame")
    problems.push(`${failing.length} frame(s) over ${failMs} ms (longest ${Math.max(...failing).toFixed(1)} ms)`);
  if (measured.layoutShift > shiftMax)
    problems.push(`layout shift ${measured.layoutShift.toFixed(4)} (limit ${shiftMax})`);
  const warn = measured.longFrames.some((ms) => ms > DEFAULT_CHECKS.longFrameReportMs);
  return { status: problems.length ? "fail" : warn ? "warn" : "pass", problems };
}

/** Every loosened check names its reason (an entry file states why). */
export function checkReasons(checks: PlayChecks | undefined): string[] {
  return Object.entries(checks ?? {})
    .filter(([, value]) => !value || typeof value.reason !== "string" || value.reason.trim().length < 12)
    .map(([key]) => `${key}: a loosened check needs a written reason`);
}

export function overall(steps: StepReport[]): PlayReport["status"] {
  if (!steps.length) return "none";
  return steps.some((step) => step.status === "fail")
    ? "fail"
    : steps.some((step) => step.status === "warn")
      ? "warn"
      : "pass";
}

// ---- Target resolution ----

const IMPLICIT_ROLES: Record<string, string> = {
  BUTTON: "button",
  A: "link",
  TEXTAREA: "textbox",
  SELECT: "combobox",
  H1: "heading",
  H2: "heading",
  H3: "heading",
  DIALOG: "dialog",
  NAV: "navigation",
  MAIN: "main",
  LI: "listitem",
  UL: "list",
  OL: "list",
};

export function roleOf(element: Element): string | undefined {
  const explicit = element.getAttribute("role");
  if (explicit) return explicit.split(/\s+/)[0];
  if (element.tagName === "INPUT") {
    const type = (element.getAttribute("type") ?? "text").toLowerCase();
    return type === "checkbox" ? "checkbox" : type === "radio" ? "radio" : type === "search" ? "searchbox" : "textbox";
  }
  if (element.tagName === "A" && !element.hasAttribute("href")) return undefined;
  if ((element as HTMLElement).isContentEditable && element.getAttribute("contenteditable") !== null) return "textbox";
  return IMPLICIT_ROLES[element.tagName];
}

export function accessibleName(element: Element): string {
  const label = element.getAttribute("aria-label");
  if (label) return label.trim();
  const labelledBy = element.getAttribute("aria-labelledby");
  if (labelledBy) {
    const text = labelledBy
      .split(/\s+/)
      .map((id) => element.ownerDocument.getElementById(id)?.textContent ?? "")
      .join(" ")
      .trim();
    if (text) return text;
  }
  const text = (element.textContent ?? "").replace(/\s+/g, " ").trim();
  return text || (element.getAttribute("title") ?? element.getAttribute("placeholder") ?? "").trim();
}

const nameMatches = (name: string, wanted: string | RegExp | undefined) =>
  wanted === undefined || (typeof wanted === "string" ? name === wanted : wanted.test(name));

export function describeTarget(target: PlayTarget): string {
  if ("role" in target) return `${target.role}${target.name === undefined ? "" : ` "${String(target.name)}"`}`;
  if ("testId" in target) return `[data-testid=${target.testId}]`;
  if ("text" in target) return `text "${String(target.text)}"`;
  if ("deep" in target) return `deep ${target.deep}`;
  return target.selector;
}

/** The first match of `selector` in `root` or in any open shadow root under it, in document order. */
export function deepQuery(root: Document | Element | ShadowRoot, selector: string): Element | null {
  const direct = root.querySelector(selector);
  if (direct) return direct;
  for (const element of root.querySelectorAll("*")) {
    const found = element.shadowRoot ? deepQuery(element.shadowRoot, selector) : null;
    if (found) return found;
  }
  return null;
}

export function resolveTarget(root: Document | Element, target: PlayTarget): Element | null {
  if ("selector" in target) return root.querySelector(target.selector);
  if ("deep" in target) return deepQuery(root, target.deep);
  if ("testId" in target) return root.querySelector(`[data-testid="${CSS.escape(target.testId)}"]`);
  const all = [...root.querySelectorAll("*")];
  if ("text" in target) {
    // The deepest element with that text: the last in document order.
    const matching = all.filter((element) =>
      nameMatches((element.textContent ?? "").replace(/\s+/g, " ").trim(), target.text),
    );
    return matching[matching.length - 1] ?? null;
  }
  return (
    all.find((element) => roleOf(element) === target.role && nameMatches(accessibleName(element), target.name)) ?? null
  );
}
