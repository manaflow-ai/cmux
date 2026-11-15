// A commit subject or release line as a person reads it (Leo on nightly 3913596493801,
// 2026-10-18): no bead ids, no "cmux NEXT perf-split:" work-stream prefix, internal work set
// apart, and a title never cut mid-sentence. A port of summary_entry and short_title in
// scripts/cmux-next/release-notes.py, so notes published before those rules read the same; the
// page test runs both on every subject of a real span and compares.

/** Conventional types that never reach a person. */
export const INTERNAL_TYPES = new Set([
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
/** Scopes of fix/feat commits that are about the pipeline or plumbing, not the app; the release
    notes and the feed too (nightly 4037632091801 read "Fixed: validate release headings within their
    day", #25533). */
export const INTERNAL_SCOPES = new Set([
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
  "release-notes",
  "appcast",
]);
/** Subject words that mark internal work even without a type. */
export const INTERNAL_WORDS = new RegExp(
  String.raw`\b(red|unit tests?|tests?|godfile|crash ratchet|baseline|index_subscript|int_conversion|lint|repin|re-pin|pin|` +
    String.raw`canary|fleet|review findings|move-only|ci|testbox|bisect|fixtures?|snapshot tests?|tree key|r2|ffi pin|budget|` +
    String.raw`isolated|wiring|socket|daemon|capabilit\w*|struct|type|owner|protocol|schema|sdk|refactor|smoke|acpmux|optchat-chief|` +
    String.raw`e2e|gallery|release notes?|publish\w*|pipeline|workflow|telemetry|crash reporting|exception reporting|benchmark|` +
    String.raw`frame budget|osc \d+|terminal host|seed|record\w*|nightly|headless|ffi|rust|regenerate|decode|renderer|texture|` +
    String.raw`machine code|scene captures?|policy log|host log|force unwrap|store intent|property model|false positive|inventory|` +
    String.raw`boundary|on the wire|debug reports?|dom events?|keybind actions?|main actor|shims?|` +
    String.raw`consumers?|metrics|review fixes|base reds?|feat-cmux-next|compile fix(?:es)?|byte limit|` +
    String.raw`fits the validator|validates? release headings|release[- ]notary|notes check|ad hoc builds?|superseded runs?|counted as failing)\b`,
  "i",
);
/** Product names whose casing is not code ("MacOS": a title capitalized before LEADING_BRAND). */
/** Backend and provider plumbing stays in the collapsed Under the hood section. */
const INTERNAL_BACKEND =
  /\b(?:postgres(?:ql)?|vitess|snapshot cutoff|env(?:ironment)? projection|projection (?:read|write|shadow)|provider allocations?|cloud-3|credential plumbing|credential recovery|keyring credentials)\b/i;
const BRANDS =
  /\b(?:[Mm]acOS|[Ii]OS|[Ii]PadOS|[Ii]Cloud|[Ii]Phone|[Ii]Pad|GitHub|YouTube|SwiftUI|WebKit|JavaScript|TypeScript|ChatGPT|OpenAI)\b/g;
/** Code-looking text: backticks, dotted names, snake_case, versioned ids, bead ids, camelCase,
    {placeholders}. */
const CODE_LIKE =
  /`|\b[A-Za-z_]\w*\.[A-Za-z_]\w*\b|\w_\w|\w-v\d\b|\[cx-|\bcx-[a-z0-9]{3,}|\b[a-z]+[A-Z]\w*|\b[A-Z][a-z]+[A-Z]\w*|\b[A-Z]{2,}(?:-[A-Z]+)+\b|\{\w+\}/;
/** Work no user sees by its shape (review of #22099, ASCII like release-notes.py): a tool name of
    three or more hyphenated parts ("export-backdrop-art"; not "two-finger-swipe", "cmd-shift-t",
    "up-to-date" or "per-tab-zoom"), a pull request number ("#21369", "#N"; not "#1") and a repair
    after a squash ("lost in the Chief Dock squash"; not "squash commits from the review pane"). */
const TOOL_NAME =
  /(?<!\S)(?!(?:[a-z0-9]+-)*(?:to|by|of|and|in|the|a|an|on|for|or|at|with|up|not|per|one|two|three|four|five|six|seven|eight|nine|ten|cmd|command|shift|ctrl|control|alt|option|opt|fn|[a-z]|\d+)(?![a-z0-9]))[a-z][a-z0-9]*(?:-[a-z0-9]+){2,}(?=[\s,.;:!?)]|$)/i;
const PR_NUMBER = /(?<!\S)#(?:N|\d{3,})(?![\w-])/;
const SQUASH_REPAIR = /\bsquash(?:ed)? (?:merge|commit)\b|\bsquash$/i;
const CONVENTIONAL = /^(?<type>[A-Za-z-]+)(?:\((?<scope>[^)]*)\))?!?:\s*(?<rest>.+)$/;
/** "area words: rest" after the conventional type: "cmux NEXT perf-split: review: …", "cmux-next strip: …". */
const LABEL = /^(?<area>[A-Za-z][\w-]*(?: [A-Za-z][\w-]*){0,2})(?:\((?<scope>[^)]*)\))?!?:\s+(?<rest>\S.*)$/;
/** Work streams that measure or check the app (perf-split, perf-gate, motion-record, strip-scroll-check). */
const INTERNAL_AREA_SHAPE =
  /^(?:perf-[\w-]+|[\w-]+-(?:check|record|gate|bench|probe)|motion-record|review|gate|base-red)$/i;
const PRODUCT_WORDS = new Set(["cmux", "next", "cmux-next", "cmuxnext"]);
const AREA_PREFIX =
  /^(cmux-next(?: \w+){0,2}|cmuxnext|cmux next|acpmux|apps?|browser|gallery|release notes?|cx-[\w.]+|feed [\d.]+|cmux-tui)\s*:\s*/i;
/** "(#123)", "(hq#45)", "(cx-abc)", "(cx-2y2 items 6, 10)", "(red)", "(review)", and a bead
    reference cut off at the end. */
const REFS =
  /\s*\((?:[^()]*\bcx-[\w.]+[^()]*|[\p{L}\p{N}_-]*#\d+|red|review)\)|\s*\((?:[^()]*\b)?cx-[\w.]*$|\s*\([au]\d+(?:\s*[,/]\s*[au]?\d+)*\)/giu;
/** Internal work-stream codes no person can read (Leo 2026-11-02, on a What's New page of rows like
    "P0 RESIZE KEYS K4: …", "… (SWITCH FRAMES SF-5 B)", "… size and scale (REOPEN-F7 part A2)" and
    "P0 RESIZE F1 part 1 of 2": "the 0 information density one"): a leading priority code and its
    capitalized stream words, a parenthesis that holds a stream code, and "part N of M" or "part A2".
    The same pattern as release-notes.py WORK_CODES. */
export const WORK_CODES = new RegExp(
  [
    String.raw`^P[0-3](?:\s+[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)*\b)+(?:\s+part\s+(?:\d+\s+of\s+\d+|[A-Z]?\d+[A-Z]?\d*))?\s*(?::\s*|$|(?=\())`,
    String.raw`\s*\((?=[^()]*\b(?:[A-Z]{2,}-)?[A-Z]{1,3}-?\d+[A-Z]?\d*\b)(?=[^()]*(?:\b[A-Z]{2,}\b[^()]*\b[A-Z]{2,}|\b[A-Z]{2,}-[A-Z]\d|\bpart\s))[^()]*\)`,
    String.raw`\s*\bpart\s+(?:\d+\s+of\s+\d+|[A-Z]\d+)\b`,
  ].join("|"),
  "g",
);
/** "Cmux NEXT agent pane: …", "Cmux link sync push: …", "Cmux-tui + app: …": the product and up to
    three area words as a label, longer than LABEL takes (release-notes.py CMUX_AREA). */
const CMUX_AREA = /^cmux(?:[- ]?next)?(?:[ -][\w-]+){0,3}(?:\s*\+\s*[\w-]+)?\s*:\s+(?=\S)/i;

/** The text without its work-stream codes (WORK_CODES), spaces tidied: "Size and scale (REOPEN-F7)."
    reads "Size and scale.". */
export function withoutWorkCodes(text: string): string {
  return text
    .replace(WORK_CODES, " ")
    .replace(/\s+/gu, " ")
    .replace(/ ([.,;:!?])/gu, "$1")
    .trim();
}

/** The product's own label at the start of a human title: "cmux NEXT: …". */
const PRODUCT_LABEL = /^(?:cmux[- ]?next|cmuxnext)\s*:\s*/i;

/** A release line without work-stream codes (WORK_CODES) or a "cmux …:" label (CMUX_AREA), capitalized
    ("" when only codes were there): a human-written title, or a line read as one key. */
export function plainLine(text: string): string {
  const out = withoutWorkCodes(text)
    .replace(CMUX_AREA, "")
    .replace(/^[\s:;,—-]+|[\s:;,—-]+$/gu, "");
  return out ? capitalized(out) : "";
}

export type ChangeGroup = "new" | "fixed" | "changed";

export interface ReadableChange {
  title: string;
  /** CI, tests, refactors, perf measurement and other work no user sees. */
  internal: boolean;
  group: ChangeGroup;
}

/** A brand that starts lowercase keeps its casing at the start of a title: "macOS 26 …". */
const LEADING_BRAND = /^(?:macOS|iOS|iPadOS|iCloud|iPhone|iPad)\b/;

function capitalized(text: string): string {
  return LEADING_BRAND.test(text) ? text : text.charAt(0).toUpperCase() + text.slice(1);
}

function strip(text: string): string {
  return withoutWorkCodes(text)
    .replace(REFS, "")
    .trim()
    .replace(/^[\s.]+|[\s.]+$/gu, "");
}

/** A machine-made line (a commit subject, or a summary line made from one) as summary_entry reads it. */
export function readableChange(subject: string): ReadableChange {
  let text = withoutWorkCodes(subject);
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
  text = strip(text.replace(AREA_PREFIX, "").replace(CMUX_AREA, ""));
  if (
    !text ||
    INTERNAL_WORDS.test(text) ||
    INTERNAL_BACKEND.test(text) ||
    CODE_LIKE.test(text.replace(BRANDS, "")) ||
    TOOL_NAME.test(text) ||
    PR_NUMBER.test(text) ||
    SQUASH_REPAIR.test(text)
  )
    return internal(text);
  if (group === "changed" && /^(add|adds|new|introduce|support|show)\b/i.test(text)) group = "new";
  else if (group === "changed" && /^(fix|fixes|repair|stop|keep)\b/i.test(text)) group = "fixed";
  return { title: capitalized(text), internal: false, group };
}

/** A human-written title (a reviewed What's New entry, a highlight): only bead ids and the
    product's own label come off; nothing is judged internal. */
export function tidyTitle(title: string): string {
  return capitalized(plainLine(strip(title.replace(PRODUCT_LABEL, ""))));
}

/** The subject a `Revert "…"` commit undoes, else undefined. */
export function revertedSubject(subject: string): string | undefined {
  return /^Revert "(.+)"(?:\s*\(#\d+\))?$/.exec(subject.trim())?.[1];
}

const CLAUSE = /,|;| —| - | \(| so | because | while /g;
const DANGLING = /\b(?:a|an|the|and|or|but|to|of|in|on|for|with|by|even|so|that|which|its|their)$/i;

/** A title of at most `limit` characters: the text when it fits, else its first clause when that
    fits, has three words and does not end on a joining word, else undefined. Never a cut word, a
    trailing "…" or a cut inside parentheses ("Routing follow-ups (trim recovered route" was one). */
export function shortTitle(text: string, limit = 60): string | undefined {
  const clean = text.trim().replace(/[\s.]+$/u, "");
  if (clean.length <= limit) return clean;
  for (const match of clean.matchAll(CLAUSE)) {
    if (openParens(clean.slice(0, match.index)) > 0) continue;
    const head = clean.slice(0, match.index).replace(/[\s,;:—-]+$/u, "");
    if (head.length > limit) return undefined;
    if (head.split(" ").length >= 3 && !DANGLING.test(head)) return head;
  }
  return undefined;
}

/** How many "(" in `text` no ")" closes yet. */
export function openParens(text: string): number {
  let depth = 0;
  for (const char of text) {
    if (char === "(") depth++;
    else if (char === ")" && depth > 0) depth--;
  }
  return depth;
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

// What a change means for the person, for the Updated popover beside the sidebar (Leo 2026-11-14,
// on "Redesign Cloud connection gates with human targets" and "The plan's Loading... waits 1 s, as
// the page's first read does": "theese are kinda crappy looking icons and stuff"). A reviewed title
// or a pull request's changelog line can still say how the app is built rather than what changed;
// here it reads as a plain sentence about what changed ("Cloud connects with clearer status",
// "Plans no longer flash a loading state"), or, when nothing a person sees changed, it folds into
// the popover's one "Maintenance and fixes" line. English only: another language's line is a
// reviewed translation and stays as written.

/** Words that name how the app is built, not what a person sees: a line with one is maintenance. */
export const JARGON = new RegExp(
  String.raw`\b(?:gates?|targets?|first read|occlusion|pathspecs?|provenance|watchdogs?|evidence|pager|tunables?|rim|` +
    String.raw`wash|rhythm|rails?|coalesc\w*|bridges?|index(?:es|ed)?|cache[ds]?|caching|snapshots?|immutable|` +
    String.raw`normali[sz]ed|receipts?|lifecycle|persist\w*|daemons?|orphan|grace|respawn\w*|probes?|parity|diagnostics?|` +
    String.raw`stage log|hitch(?:es)?|frame check|gpu|measured|scans?|pushes|hydrat\w*|reconcil\w*|debounc\w*|` +
    String.raw`throttl\w*|seams?|carriers?|lanes?|ops|payloads?|endpoints?|handshakes?|idempotent\w*|mutex\w*|` +
    String.raw`regressions?|fallbacks?|plumbing|expectations?|keep-alive|insets?|spawn\w*|harness\w*|` +
    String.raw`verification|revisions?|superseded|redundant|inputs?|state (?:sync|machine)|re-?maps?|re-?runs?|` +
    String.raw`cells?|surfaces? (?:degraded|coverage)|coverage|tab strips?|traffic[- ]lights?|lays out|subject box|` +
    String.raw`(?:pre)?warm(?:s|ed|ing)?|spare (?:windows?|process\w*)|signals?|chunks?|idle moments)\b`,
  "i",
);
/** "chrome" in its UI-builder sense ("Align composer control chrome"), not the browser. */
const JARGON_CASED = /\bchrome\b/;
/** Apple UI names a person knows, camel-cased like code ("VoiceOver"): plain words to the judgment. */
const UI_NAMES =
  /\b(?:VoiceOver|FaceTime|AirDrop|AirPlay|AirPods|TestFlight|QuickTime|QuickLook|FileVault|TouchID|FaceID|CarPlay|SharePlay|AppleScript)\b/g;
/** A pull request named anywhere in a parenthesis ("(#20706 slice 1)"): the whole parenthesis is a ref. */
const PR_PAREN = /\s*\([^()]*#\d{2,}[^()]*\)/gu;

/** readableChange's judgment of `text`, with Apple UI names read as plain words. */
function judged(text: string): ReadableChange {
  return readableChange(text.replace(UI_NAMES, "Apple"));
}

/** Builder verbs a title can open with that never describe a change a person sees. */
const BUILDER_VERB =
  /^(?:avoid|expose|fail closed|refresh|release|stabili[sz]e|coalesce|index|cache|preserve|skip|carry|persist|drop|surface|paint|theme|respawn|align|wire|plumb|route|gate|hoist|inline|split out|extract|rename|bump|tune)\b/i;
/** A measured time outside quotes ("waits 1 s", "after 8 s", "350 ms"); a quoted UI string
    ("Thought for 12s") is what a person reads, so it stays. */
const TIMING = /\b\d+(?:\.\d+)?\s?(?:ms|s|sec|seconds?)\b/i;
/** A UI string quoted with its own punctuation ("Loading...", "Loading…"), which reads as a label. */
const LOADING_LABEL = /["“]?\bloading(?:\.\.\.|…)["”]?/i;
/** Words that say a connection's state was made clearer. */
const CLEARER = /\b(?:redesign\w*|rework\w*|rewrit\w*|clarif\w*|humani[sz]\w*|human|plain|clearer|readable)\b/i;
const CONNECTION = /\b(?:connection|connects?|connecting|reconnect\w*|offline)\b/i;
const CONNECTED_THING = /\b(Cloud|Remote|iPhone|iOS|SSH)\b/i;
const REDESIGN = /^(?:redesign|rework|restyle|refresh the look of)\s+(.+)$/i;
const POSSESSIVE_LOADING = /^(?:the |a |an )?([\p{L} -]+?)['’]s\s+["“]?loading\b/iu;

export interface PlainChange {
  title: string;
  /** What the description adds, when it reads as plainly as the title; undefined when it does not. */
  detail?: string;
}

/** `noun` as a plural a sentence can start with: "plan" → "Plans", "gallery" → "Galleries". */
function pluralNoun(noun: string): string {
  const word = noun.trim();
  const plural = /s$/i.test(word) ? word : /[^aeiou]y$/i.test(word) ? `${word.slice(0, -1)}ies` : `${word}s`;
  return capitalized(plural);
}

/** Whether `text` says how the app is built rather than what a person sees. */
export function isJargon(text: string): boolean {
  const unquoted = text.replace(/["“][^"”]*["”]/gu, "");
  return (
    JARGON.test(unquoted) ||
    JARGON_CASED.test(unquoted) ||
    BUILDER_VERB.test(unquoted) ||
    TIMING.test(unquoted) ||
    LOADING_LABEL.test(text) ||
    judged(unquoted).internal
  );
}

/** A known shape of builder's line said the way a person notices it, else undefined. */
function rewritten(text: string): string | undefined {
  if (CONNECTION.test(text) && CLEARER.test(text)) {
    const thing = CONNECTED_THING.exec(text)?.[1];
    return `${thing ? capitalized(thing.toLowerCase() === "ios" ? "iOS" : thing) : "cmux"} connects with clearer status`;
  }
  if (/\bloading\b/i.test(text) && (TIMING.test(text) || /\b(?:waits?|flash\w*|flicker\w*)\b/i.test(text))) {
    const noun = POSSESSIVE_LOADING.exec(text)?.[1];
    return `${noun ? pluralNoun(noun) : "Pages"} no longer flash a loading state`;
  }
  const redesigned = REDESIGN.exec(text)?.[1];
  if (redesigned && !isJargon(redesigned)) return `${capitalized(redesigned)} has a new design`;
  return undefined;
}

/** A change's title and detail as the popover says them (see above), or undefined when nothing a
    person sees changed: the line folds into "Maintenance and fixes". `past` puts an imperative
    title's verb in the past tense, as the popover's release notes read; the card's line keeps the
    page's own words. */
export function plainChange(
  title: string,
  detail: string | undefined,
  language: string,
  past = true,
): PlainChange | undefined {
  if (!/^en\b/i.test(language)) return { title, ...(detail ? { detail } : {}) };
  const raw = strip(plainLine(title.replace(PR_PAREN, "")));
  if (!raw) return undefined;
  const plain = rewritten(raw);
  // The line without its area label ("Agent pane: …"): the popover heads it with its area.
  const text = readableChange(raw).title || raw;
  if (plain) return { title: plain };
  if (judged(raw).internal || isJargon(text)) return undefined;
  // The detail keeps its own sentence punctuation; only refs and stream codes come off.
  const line = detail ? plainLine(detail.replace(PR_PAREN, "").replace(REFS, "")).trim() : "";
  return {
    title: past ? pastTense(capitalized(text)) : capitalized(text),
    ...(line && !isJargon(line) ? { detail: capitalized(line) } : {}),
  };
}

/** An imperative title's leading verb in the past tense, as release notes say what changed ("Fix the
    tab bar" reads "Fixed the tab bar"; Leo's reference, 2026-11-14). Only verbs whose past form
    always reads right; "Show …", "Undo …" and "Go …" name what a person can do and stay. */
const PAST: Record<string, string> = {
  add: "Added",
  fix: "Fixed",
  keep: "Kept",
  stop: "Stopped",
  remove: "Removed",
  restore: "Restored",
  improve: "Improved",
  change: "Changed",
  rename: "Renamed",
  reduce: "Reduced",
  update: "Updated",
  hide: "Hid",
  move: "Moved",
  allow: "Allowed",
  enable: "Enabled",
  support: "Added support for",
  speed: "Sped",
};

/** `text` with its leading imperative verb in the past tense (PAST), else as it is. */
export function pastTense(text: string): string {
  const match = /^([A-Za-z]+)\b/.exec(text);
  const past = match ? PAST[match[1]!.toLowerCase()] : undefined;
  return past ? past + text.slice(match![1]!.length) : text;
}
