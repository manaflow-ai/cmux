// A commit subject or release line as a person reads it (Leo on nightly 3913596493801,
// 2026-10-18): no bead ids, no "cmux NEXT perf-split:" work-stream prefix, internal work set
// apart, and a title never cut mid-sentence. A port of summary_entry and short_title in
// scripts/cmux-next/release-notes.py, so notes published before those rules read the same; the
// page test runs both on every subject of a real span and compares.

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
/** Scopes of fix/feat commits that are about the pipeline or plumbing, not the app. */
const INTERNAL_SCOPES = new Set([
  "ci",
  "nightly",
  "fleet",
  "release",
  "build",
  "tests",
  "test",
  "gallery",
  "crash",
  "lint",
  "docs",
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
  "cmux-git",
  "cmux-tui-core",
]);
/** Subject words that mark internal work even without a type. */
const INTERNAL_WORDS = new RegExp(
  String.raw`\b(red|unit tests?|tests?|godfile|crash ratchet|baseline|index_subscript|int_conversion|lint|repin|re-pin|pin|` +
    String.raw`canary|fleet|review findings|move-only|ci|testbox|bisect|fixture|snapshot tests?|tree key|r2|ffi pin|budget|` +
    String.raw`isolated|wiring|socket|daemon|capabilit\w*|struct|type|owner|protocol|schema|sdk|refactor|smoke|acpmux|optchat-chief|` +
    String.raw`e2e|gallery|release notes?|publish\w*|pipeline|workflow|telemetry|crash reporting|exception reporting|benchmark|` +
    String.raw`frame budget|osc \d+|terminal host|seed|record\w*|nightly|headless|ffi|rust|regenerate|decode|renderer|texture|` +
    String.raw`machine code|scene captures?|policy log|host log|force unwrap|store intent|property model|false positive|inventory|` +
    String.raw`boundary|on the wire|debug reports?|dom events?|keybind actions?|main actor|shims?|` +
    String.raw`consumers?|metrics|review fixes|byte limit)\b`,
  "i",
);
/** Product names whose casing is not code. */
const BRANDS =
  /\b(?:macOS|iOS|iPadOS|iCloud|iPhone|iPad|GitHub|YouTube|SwiftUI|WebKit|JavaScript|TypeScript|ChatGPT|OpenAI)\b/g;
/** Code-looking text: backticks, dotted names, snake_case, versioned ids, camelCase, {placeholders}. */
const CODE_LIKE =
  /`|\b[A-Za-z_]\w*\.[A-Za-z_]\w*\b|\w_\w|\w-v\d\b|\[cx-|\b[a-z]+[A-Z]\w*|\b[A-Z][a-z]+[A-Z]\w*|\b[A-Z]{2,}(?:-[A-Z]+)+\b|\{\w+\}/;
const CONVENTIONAL = /^(?<type>[A-Za-z-]+)(?:\((?<scope>[^)]*)\))?!?:\s*(?<rest>.+)$/;
/** "area words: rest" after the conventional type: "cmux NEXT perf-split: review: …", "cmux-next strip: …". */
const LABEL = /^(?<area>[A-Za-z][\w-]*(?: [A-Za-z][\w-]*){0,2})(?:\((?<scope>[^)]*)\))?!?:\s+(?<rest>\S.*)$/;
/** Work streams that measure or check the app (perf-split, perf-gate, motion-record, strip-scroll-check). */
const INTERNAL_AREA_SHAPE =
  /^(?:perf-[\w-]+|[\w-]+-(?:check|record|gate|bench|probe)|motion-record|review|gate|base-red)$/i;
const PRODUCT_WORDS = new Set(["cmux", "next", "cmux-next", "cmuxnext"]);
const AREA_PREFIX =
  /^(cmux-next(?: \w+){0,2}|cmuxnext|cmux next|acpmux|apps?|browser|gallery|release notes?|cx-[\w.]+|feed [\d.]+|cmux-tui)\s*:\s*/i;
/** "(#123)", "(cx-abc)", "(cx-2y2 items 6, 10)", "(red)", and a bead reference cut off at the end. */
const REFS = /\s*\((?:[^()]*\bcx-[\w.]+[^()]*|#\d+|red)\)|\s*\((?:[^()]*\b)?cx-[\w.]*$/gi;
/** The product's own label at the start of a human title: "cmux NEXT: …". */
const PRODUCT_LABEL = /^(?:cmux[- ]?next|cmuxnext)\s*:\s*/i;

export type ChangeGroup = "new" | "fixed" | "changed";

export interface ReadableChange {
  title: string;
  /** CI, tests, refactors, perf measurement and other work no user sees. */
  internal: boolean;
  group: ChangeGroup;
}

function capitalized(text: string): string {
  return text.charAt(0).toUpperCase() + text.slice(1);
}

function strip(text: string): string {
  return text
    .replace(REFS, "")
    .trim()
    .replace(/^[\s.]+|[\s.]+$/gu, "");
}

/** A machine-made line (a commit subject, or a summary line made from one) as summary_entry reads it. */
export function readableChange(subject: string): ReadableChange {
  let text = subject.split(/\s+/).filter(Boolean).join(" ");
  const internal = (title: string): ReadableChange => ({
    title: capitalized(strip(title)),
    internal: true,
    group: "changed",
  });
  if (!text || /^(merge |revert |bead:)/i.test(text)) return internal(text);
  let group: ChangeGroup = "changed";
  for (;;) {
    const match = CONVENTIONAL.exec(text)?.groups;
    if (!match) break;
    const kind = match.type!.toLowerCase();
    const scopes = (match.scope ?? "").toLowerCase().split(",");
    if (INTERNAL_TYPES.has(kind) || scopes.some((s) => INTERNAL_SCOPES.has(s.trim()))) return internal(match.rest!);
    if (kind !== "feat" && kind !== "fix" && kind !== "perf") {
      if (kind !== "cmux-next" && kind !== "cmuxnext") return internal(match.rest!);
      text = match.rest!;
      continue;
    }
    group = kind === "feat" ? "new" : kind === "fix" ? "fixed" : "changed";
    text = match.rest!;
    break;
  }
  for (let label = LABEL.exec(text)?.groups; label; label = LABEL.exec(text)?.groups) {
    const words = label
      .area!.toLowerCase()
      .split(" ")
      .filter((w) => !PRODUCT_WORDS.has(w));
    const scopes = (label.scope ?? "")
      .toLowerCase()
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean);
    // "acpmux test: …", "sidebar ci: …": a label that names test or CI work is internal too.
    if ([...words, ...scopes].some((w) => INTERNAL_AREA_SHAPE.test(w) || INTERNAL_TYPES.has(w)))
      return internal(label.rest!);
    text = label.rest!;
  }
  text = strip(text.replace(AREA_PREFIX, ""));
  if (!text || INTERNAL_WORDS.test(text) || CODE_LIKE.test(text.replace(BRANDS, ""))) return internal(text);
  if (group === "changed" && /^(add|adds|new|introduce|support|show)\b/i.test(text)) group = "new";
  else if (group === "changed" && /^(fix|fixes|repair|stop|keep)\b/i.test(text)) group = "fixed";
  return { title: capitalized(text), internal: false, group };
}

/** A human-written title (a reviewed What's New entry, a highlight): only bead ids and the
    product's own label come off; nothing is judged internal. */
export function tidyTitle(title: string): string {
  return capitalized(strip(title.replace(PRODUCT_LABEL, "")));
}

/** The subject a `Revert "…"` commit undoes, else undefined. */
export function revertedSubject(subject: string): string | undefined {
  return /^Revert "(.+)"(?:\s*\(#\d+\))?$/.exec(subject.trim())?.[1];
}

const CLAUSE = /,|;| —| - | \(| so | because | while /g;
const DANGLING = /\b(?:a|an|the|and|or|but|to|of|in|on|for|with|by|even|so|that|which|its|their)$/i;

/** A title of at most `limit` characters: the text when it fits, else its first clause when that
    fits, has three words and does not end on a joining word, else undefined. Never a cut word or
    a trailing "…". */
export function shortTitle(text: string, limit = 60): string | undefined {
  const clean = text.trim().replace(/[\s.]+$/u, "");
  if (clean.length <= limit) return clean;
  for (const match of clean.matchAll(CLAUSE)) {
    const head = clean.slice(0, match.index).replace(/[\s,;:—-]+$/u, "");
    if (head.length > limit) return undefined;
    if (head.split(" ").length >= 3 && !DANGLING.test(head)) return head;
  }
  return undefined;
}

/** What follows `title` in `full`, as a summary: "so a column scrolled in is never blank". */
export function titleTail(full: string, title: string): string {
  return full
    .slice(title.length)
    .replace(/^[\s,;:—-]+/u, "")
    .replace(/^\((.*)\)$/u, "$1")
    .trim();
}

/** The area a commit subject names, lowercased: "sidebar" from "cmux-next sidebar: …" or
    "fix(sidebar): …", undefined when it names none (the product's own label is not an area).
    The Updated card groups an update's changes by it (updateSummary.ts). */
export function changeArea(subject: string): string | undefined {
  let text = subject.split(/\s+/).filter(Boolean).join(" ");
  let area: string | undefined;
  for (let match = CONVENTIONAL.exec(text)?.groups; match; match = CONVENTIONAL.exec(text)?.groups) {
    const kind = match.type!.toLowerCase();
    if (kind !== "cmux-next" && kind !== "cmuxnext") {
      const scope = (match.scope ?? "").split(",")[0]?.trim().toLowerCase();
      area = scope && !PRODUCT_WORDS.has(scope) ? scope : undefined;
      text = match.rest!;
      break;
    }
    text = match.rest!;
  }
  for (let label = LABEL.exec(text)?.groups; label; label = LABEL.exec(text)?.groups) {
    const words = label
      .area!.toLowerCase()
      .split(" ")
      .filter((w) => !PRODUCT_WORDS.has(w));
    if (words.length) area = words.join(" ");
    text = label.rest!;
  }
  return area;
}
