// Every spinner turns at one period (Leo 2026-11-07, of a reference app's spinner: "Let's
// have all our spinners go at that speed."): `spinner` in schemas/motion-scale/motion-scale.json,
// written by scripts/cmux-next/gen-motion-scale.py as `--cmux-spinner-period`. This reads the page
// code (webviews/src, gallery included, and the agent-chat sidecar), no browser, and fails on
// - a full turn (`rotate(360deg)`, `1turn`) anywhere but the shared keyframes, so a new spinner can
//   not bring its own;
// - a spinner animation whose time is not `var(--cmux-spinner-period)` (a fallback, if any, must be
//   the token's own value);
// - `--cmux-spinner-period` set anywhere but its generated lines.
// The native spinners read the same period (`MotionScale.spinnerPeriod`, `Motion.period(.spinner)`);
// the ast-grep rule no-ad-hoc-spinner keeps their rotations in Motion+AppKit.swift.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { SPINNER_PERIOD_MS } from "../src/motion/scale.generated";
import { SCALE_JSON, SRC } from "./motion-scale";

const ROOT = path.resolve(import.meta.dir, "../..");
const AGENT_CHAT = path.join(ROOT, "agent-chat");
/** The keyframes allowed to turn: the pages' `cmux-spin`, and agent-chat's stepped pinwheel. */
const SPIN_KEYFRAMES = new Set(["cmux-spin", "pinwheelSpin"]);
const HOMES: Record<string, string> = {
  "cmux-spin": "webviews/src/pages/shared/desktop.css",
  pinwheelSpin: "agent-chat/public/app.css",
};
const GENERATED_PERIOD = /--cmux-spinner-period: (\d+)ms;/;
const TOKEN = new RegExp(`^var\\(--cmux-spinner-period(?:,\\s*${SPINNER_PERIOD_MS}ms)?\\)$`);
const FULL_TURN = /rotate\(\s*-?(?:360deg|1turn|2turn)\s*\)|rotate:\s*["']?-?(?:360deg|1turn)/g;
const KEYFRAMES = /@keyframes\s+([\w-]+)\s*\{/g;
const ANIMATION = /(?<![\w-])animation(-name|-duration)?\s*:\s*([^;{}"'`]*)/g;

export interface SpinnerViolation {
  file: string;
  line: number;
  text: string;
}

function files(dir: string, skip = new Set(["node_modules", "generated"])): string[] {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return skip.has(entry.name) ? [] : files(full, skip);
    if (!/\.(css|tsx?)$/.test(entry.name) || entry.name.endsWith(".d.ts")) return [];
    return /\.(test|spec)\.[^.]+$/.test(entry.name) ? [] : [full];
  });
}

const lineAt = (text: string, offset: number) => text.slice(0, offset).split("\n").length;
const blankComments = (text: string) =>
  text.replace(/\/\*[\s\S]*?\*\/|(?<![:"'`\\])\/\/[^\n]*/g, (comment) => comment.replace(/[^\n]/g, " "));

/** The keyframes block a position falls inside, by name. */
function enclosingKeyframes(text: string, offset: number): string | undefined {
  let found: string | undefined;
  for (const match of text.matchAll(KEYFRAMES)) {
    if (match.index! > offset) break;
    let depth = 0;
    let end = match.index! + match[0].length - 1;
    for (; end < text.length; end++) {
      if (text[end] === "{") depth++;
      else if (text[end] === "}" && --depth === 0) break;
    }
    if (offset < end) found = match[1];
  }
  return found;
}

export function scanSpinnerText(file: string, raw: string): SpinnerViolation[] {
  const text = blankComments(raw);
  const out: SpinnerViolation[] = [];
  const add = (offset: number, message: string) => out.push({ file, line: lineAt(text, offset), text: message });
  for (const match of text.matchAll(FULL_TURN)) {
    const name = enclosingKeyframes(text, match.index!);
    if (name === undefined || !SPIN_KEYFRAMES.has(name) || HOMES[name] !== file)
      add(match.index!, `${match[0]}: a spinner turns with cmux-spin (pages/shared/desktop.css), not its own turn`);
  }
  for (const match of text.matchAll(ANIMATION)) {
    const [, kind, value] = match;
    for (const layer of value!.split(/,(?![^(]*\))/)) {
      const tokens = layer.trim().split(/\s+(?![^(]*\))/);
      if (kind === "-duration") continue; // read with its name below
      if (!tokens.some((token) => SPIN_KEYFRAMES.has(token))) continue;
      if (kind === "-name") {
        add(match.index!, `${match[0].trim()}: write the spinner as one \`animation\` with var(--cmux-spinner-period)`);
        continue;
      }
      const time = tokens.find((token) => /^-?\d*\.?\d+m?s$/.test(token) || token.startsWith("var("));
      if (!time || !TOKEN.test(time))
        add(match.index!, `${match[0].trim()}: a spinner turns once per var(--cmux-spinner-period)`);
    }
  }
  for (const match of text.matchAll(/--cmux-spinner-period\s*:/g)) {
    const line = raw.split("\n")[lineAt(text, match.index!) - 1] ?? "";
    const generated = GENERATED_PERIOD.exec(line);
    if (!generated || Number(generated[1]) !== SPINNER_PERIOD_MS || !generatedHome(file, raw, match.index!))
      add(match.index!, "--cmux-spinner-period is set only by scripts/cmux-next/gen-motion-scale.py");
  }
  return out;
}

function generatedHome(file: string, raw: string, offset: number): boolean {
  if (file === "webviews/src/pages/shared/desktop.css") {
    const begin = raw.indexOf("/* motion-scale:begin.");
    return begin >= 0 && begin < offset && offset < raw.indexOf("/* motion-scale:end */", begin);
  }
  return (
    file === "agent-chat/public/app.css" &&
    /GENERATED by scripts\/cmux-next\/gen-motion-scale\.py/.test(raw.slice(offset, raw.indexOf("\n", offset)))
  );
}

export function scanSpinners(): SpinnerViolation[] {
  return [...files(SRC), ...files(path.join(AGENT_CHAT, "public")), ...files(path.join(AGENT_CHAT, "src"))].flatMap(
    (full) => scanSpinnerText(path.relative(ROOT, full).split(path.sep).join("/"), fs.readFileSync(full, "utf8")),
  );
}

const finds = (file: string, text: string) => scanSpinnerText(file, text).map((violation) => violation.line);

describe("spinner period", () => {
  test("every spinner turns on --cmux-spinner-period", () => {
    expect(scanSpinners().map((v) => `${v.file}:${v.line} ${v.text}`)).toEqual([]);
  });

  test("the period is the JSON's, in every copy", () => {
    const json = JSON.parse(fs.readFileSync(SCALE_JSON, "utf8"));
    expect(SPINNER_PERIOD_MS).toBe(json.spinner.ms);
    const desktop = fs.readFileSync(path.join(SRC, "pages/shared/desktop.css"), "utf8");
    expect(desktop).toContain(`--cmux-spinner-period: ${SPINNER_PERIOD_MS}ms;`);
    const swift = fs.readFileSync(
      path.join(ROOT, "Packages/macOS/CmuxNext/Sources/CmuxNextDesignTokens/Motion/MotionScale.generated.swift"),
      "utf8",
    );
    expect(swift).toContain(`spinnerPeriod: TimeInterval = ${SPINNER_PERIOD_MS / 1000}`);
    const tokens = JSON.parse(
      fs.readFileSync(path.join(ROOT, "plans/cmux-next/spec-proposals/visuals/design-tokens.json"), "utf8"),
    );
    expect(tokens.motion.loops.spinner.value).toBe(SPINNER_PERIOD_MS / 1000);
  });

  test("a new spinner with its own turn or period fails", () => {
    expect(
      finds(
        "a.css",
        ".a { animation: mt-spin 800ms linear infinite; }\n@keyframes mt-spin { to { transform: rotate(360deg); } }",
      ),
    ).toEqual([2]);
    expect(finds("a.css", ".a { animation: cmux-spin 900ms linear infinite; }")).toEqual([1]);
    expect(finds("a.css", ".a { animation: cmux-spin var(--cmux-spinner-period, 900ms) linear infinite; }")).toEqual([
      1,
    ]);
    expect(finds("a.css", ".a { animation: cmux-spin var(--cmux-motion-large) linear infinite; }")).toEqual([1]);
    expect(finds("a.css", ".a { animation-name: cmux-spin; animation-duration: 1s; }")).toEqual([1]);
    expect(finds("a.css", ":root { --cmux-spinner-period: 1200ms; }")).toEqual([1]);
    expect(
      finds("a.tsx", 'el.animate([{ transform: "rotate(0)" }, { transform: "rotate(1turn)" }], { duration: 700 });'),
    ).toEqual([1]);
    expect(finds("a.css", "@keyframes turn {\n  to { rotate: 360deg; }\n}")).toEqual([2]);
  });

  test("the token, its own fallback and comments pass", () => {
    expect(finds("a.css", ".a { animation: cmux-spin var(--cmux-spinner-period) linear infinite; }")).toEqual([]);
    expect(
      finds("a.css", `.a { animation: cmux-spin var(--cmux-spinner-period, ${SPINNER_PERIOD_MS}ms) linear infinite; }`),
    ).toEqual([]);
    expect(finds("a.css", "/* @keyframes old { to { transform: rotate(360deg); } } */")).toEqual([]);
    expect(finds("a.css", ".a { transform: rotate(90deg); animation: breathe 2.4s ease infinite; }")).toEqual([]);
  });
});
