// A commit subject or release line as a person reads it (Leo on nightly 3913596493801,
// 2026-10-18): no bead ids, no "cmux NEXT perf-split:" work-stream prefix, internal work set
// apart, and a title never cut mid-sentence. The same rules as summary_entry and short_title in
// scripts/cmux-next/release-notes.py, so notes published before those rules read the same.

/** Conventional types that never reach a person. */
const INTERNAL_TYPES = new Set([
  "ci",
  "test",
  "tests",
  "refactor",
  "docs",
  "doc",
  "chore",
  "style",
  "build",
  "lint",
  "release-note",
  "release-notes",
  "revert",
  "merge",
  "bench",
  "gallery",
]);
/** Scopes and area words about the pipeline or plumbing, not the app. */
const INTERNAL_AREAS = new Set([
  ...INTERNAL_TYPES,
  "nightly",
  "fleet",
  "release",
  "crash",
  "feat-cmux-next",
  "browser-parity",
  "first-party-apps",
  "browser-automation",
  "automation",
  "daemon",
  "protocol",
  "sdk",
  "cmux-tui",
  "app-ffi",
  "backend",
  "nightly-next",
  "e2e",
  "harness",
  "deps",
  "review",
  "gate",
  "base-red",
]);
/** Work streams that measure or check the app: perf-split, perf-gate, motion-record, strip-scroll-check. */
const INTERNAL_AREA_SHAPE = /^(?:perf-[\w-]+|[\w-]+-(?:check|record|gate|bench|probe)|motion-record)$/i;
/** The product's own name, which every NEXT line would otherwise repeat. */
const PRODUCT_WORDS = new Set(["cmux", "next", "cmux-next", "cmuxnext"]);
/** "area words: rest", "type(scope)!: rest". Up to three area words. */
const LABEL = /^(?<area>[A-Za-z][\w-]*(?: [A-Za-z][\w-]*){0,2})(?:\((?<scope>[^)]*)\))?!?:\s+(?<rest>\S.*)$/;
/** "(cx-8w027.14)", "(review, cx-8w027.14)", "(red)", and a reference cut off at the end. */
const REFS = /\s*\((?:[^()]*\bcx-[\w.]+[^()]*|red)\)|\s*\((?:[^()]*\b)?cx-[\w.]*$/gi;
/** Code-looking text: backticks, dotted or snake_case names, camelCase. */
const CODE_LIKE = /`|\b\w+\.\w+\b|\w_\w|\b[a-z]+[A-Z]\w*|\b[A-Z][a-z]+[A-Z]\w*/;

export interface ReadableChange {
  title: string;
  /** CI, tests, refactors, perf measurement and other work no user sees. */
  internal: boolean;
}

function internalArea(words: string[]): boolean {
  return words.some((word) => INTERNAL_AREAS.has(word) || INTERNAL_AREA_SHAPE.test(word));
}

export function readableChange(subject: string): ReadableChange {
  let text = subject.split(/\s+/).filter(Boolean).join(" ").replace(REFS, "").trim();
  if (/^(merge|revert)\b/i.test(text) || /^bead:/i.test(text)) return { title: text, internal: true };
  let internal = false;
  for (let match = LABEL.exec(text); match?.groups; match = LABEL.exec(text)) {
    const words = match.groups.area!.toLowerCase().split(" ");
    const scopes = (match.groups.scope ?? "")
      .toLowerCase()
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean);
    const named = words.filter((word) => !PRODUCT_WORDS.has(word));
    internal ||= internalArea(named) || internalArea(scopes);
    text = match.groups.rest!;
  }
  text = text.replace(/[\s.]+$/u, "");
  internal ||= !text || CODE_LIKE.test(text);
  return { title: text.charAt(0).toUpperCase() + text.slice(1), internal };
}

/** A title of at most `limit` characters: the text when it fits, else its first clause when that
    fits and says something on its own, else undefined. Never a cut word or a trailing "…". */
export function shortTitle(text: string, limit = 60): string | undefined {
  const clean = text.trim().replace(/[\s.]+$/u, "");
  if (clean.length <= limit) return clean;
  const clauses = /(?:,|;| —| -| \(| so | while | until | because | when )/g;
  let best: string | undefined;
  for (let match = clauses.exec(clean); match; match = clauses.exec(clean)) {
    const head = clean.slice(0, match.index).replace(/[\s,;:—-]+$/u, "");
    if (head.length > limit) break;
    if (head.split(" ").length >= 3) best = head;
  }
  return best;
}
