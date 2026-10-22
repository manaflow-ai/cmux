// Leo 2026-10-21: "let's get rid of the blinking dot asap", "we need to guarantee the breathing dot
// doesnt come back". A status dot is still: it says what state a chat is in by its colour (and,
// under Static status indicators, its shape), never by fading or pulsing. Agent work that needs
// motion is the spinner (#23776).
//
// This reads every stylesheet the web views ship (webviews/src, not the prototypes) and lists each
// animation that repeats forever and fades (opacity), blinks (visibility) or pulses (scale). Each one
// must be on the list below, with the reason it is not a status dot. A new breathing or blinking
// dot, under any class name, fails here until someone deletes it or argues it onto the list.
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { describe, expect, test } from "bun:test";

const src = path.resolve(import.meta.dir, "../src");

type Loop = { file: string; keyframes: string; selector: string; props: string[] };

/** The loops a stylesheet may keep: file, keyframes, a piece of the rule's selector, and why. */
const ALLOWED: { file: string; keyframes: string; selector: string; why: string; goneWith?: string }[] = [
  {
    file: "agent-session/acpmux/conversation/conversation.css",
    keyframes: "cmux-breathe",
    selector: ".cv-spinner[data-working]",
    why: "the Debug Breathing Dot working look, not the default since #23776",
    goneWith: "#23870, which deletes the look and guards it in static-status-loops.test.ts",
  },
  {
    file: "agent-session/acpmux/conversation/conversation.css",
    keyframes: "acpmux-jump-latest-dot",
    selector: ".acpmux-jump-latest",
    why: "Jump to latest's three working dots (#21800); Static and Reduce Motion still them",
  },
  {
    file: "agent-session/acpmux/inspector/inspector.css",
    keyframes: "acpmux-chat-inspector-breathe",
    selector: ".cv-subagent-avatar",
    why: "a running subagent's avatar picture in the Inspector, not a status dot",
  },
  {
    file: "agent-session/acpmux/styles.css",
    keyframes: "acpmux-mic-wait",
    selector: ".acpmux-mic",
    why: "the mic button while dictation starts",
  },
  {
    file: "agent-session/acpmux/newtab/screen.css",
    keyframes: "nt-player-level",
    selector: ".nt-player-levels",
    why: "the music player's level bars",
  },
  {
    file: "pages/apps/styles.css",
    keyframes: "cmux-breathe",
    selector: ".apps-skeleton",
    why: "the Apps page's loading skeleton",
  },
  {
    file: "pages/apps/styles.css",
    keyframes: "cmux-skeleton-pulse",
    selector: ".apps-skeleton",
    why: "the Apps page's loading skeleton (its name once #23870 lands)",
    goneWith: "not yet: #23870 renames cmux-breathe here",
  },
  {
    file: "pages/cloud/styles.css",
    keyframes: "cloud-store-packet",
    selector: ".cloud-store-art-packet",
    why: "the Cloud store illustration's moving packets",
  },
  {
    file: "pages/home-channels/styles.css",
    keyframes: "hc-writing",
    selector: ".hc-writing",
    why: 'Home\'s "writing" word, text rather than a dot',
  },
];

function stylesheets(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir).sort()) {
    const full = path.join(dir, name);
    if (statSync(full).isDirectory()) {
      // Design prototypes, never loaded by the app.
      if (path.relative(src, full) !== "prototypes") stylesheets(full, out);
    } else if (name.endsWith(".css")) out.push(full);
  }
  return out;
}

type Rule = { selector: string; body: string };

/** Style rules (nested in @media, @supports or CSS nesting included) and @keyframes bodies. */
export function parseStylesheet(css: string): { rules: Rule[]; keyframes: Map<string, string> } {
  const text = css.replace(/\/\*[\s\S]*?\*\//g, "");
  const rules: Rule[] = [];
  const keyframes = new Map<string, string>();
  const heads: string[] = [];
  const bodies: string[] = [];
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === "{") {
      const head = text.slice(start, i).trim();
      const named = /^@(?:-webkit-)?keyframes\s+([\w-]+)/.exec(head);
      if (named) {
        let depth = 1;
        let j = i + 1;
        for (; j < text.length && depth > 0; j++) {
          if (text[j] === "{") depth++;
          else if (text[j] === "}") depth--;
        }
        keyframes.set(named[1]!, (keyframes.get(named[1]!) ?? "") + text.slice(i + 1, j - 1));
        i = j - 1;
        start = j;
        continue;
      }
      // Declarations before a nested rule belong to the enclosing rule; the selector follows them.
      const cut = head.lastIndexOf(";");
      if (bodies.length && cut >= 0) bodies[bodies.length - 1] += `${head.slice(0, cut + 1)}`;
      heads.push(head.slice(cut + 1).trim());
      bodies.push("");
      start = i + 1;
    } else if (c === "}") {
      const head = heads.pop();
      const body = (bodies.pop() ?? "") + text.slice(start, i);
      if (head !== undefined && !head.startsWith("@")) {
        const outer = heads.filter((h) => !h.startsWith("@")).join(" ");
        rules.push({ selector: outer ? `${outer} ${head}` : head, body });
      }
      start = i + 1;
    }
  }
  return { rules, keyframes };
}

/** `value` split at its top-level commas (not those inside var(), cubic-bezier() or :is()). */
function splitTopLevel(value: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let from = 0;
  for (let i = 0; i < value.length; i++) {
    if (value[i] === "(") depth++;
    else if (value[i] === ")") depth--;
    else if (value[i] === "," && depth === 0) {
      parts.push(value.slice(from, i));
      from = i + 1;
    }
  }
  parts.push(value.slice(from));
  return parts.map((part) => part.trim());
}

/** What a keyframes body moves that reads as fading, blinking or pulsing. */
function flicker(body: string): string[] {
  const props: string[] = [];
  if (/(^|[;{\s])opacity\s*:/.test(body)) props.push("opacity");
  if (/(^|[;{\s])visibility\s*:/.test(body)) props.push("visibility");
  if (/(^|[;{\s])scale\s*:|scale(?:3d|X|Y)?\s*\(/.test(body)) props.push("scale");
  return props;
}

/** Every rule that runs a forever-repeating animation whose keyframes fade, blink or pulse. */
export function flickerLoops(files: { file: string; css: string }[]): Loop[] {
  const parsed = files.map(({ file, css }) => ({ file, ...parseStylesheet(css) }));
  const keyframes = new Map<string, string>();
  for (const sheet of parsed)
    for (const [name, body] of sheet.keyframes) keyframes.set(name, (keyframes.get(name) ?? "") + body);
  const loops: Loop[] = [];
  for (const { file, rules } of parsed) {
    for (const { selector, body } of rules) {
      const declarations = body.split(";").map((d) => d.trim());
      const shorthand = declarations
        .filter((d) => /^animation\s*:/.test(d))
        .map((d) => d.replace(/^animation\s*:/, ""));
      const named = declarations
        .filter((d) => /^animation-name\s*:/.test(d))
        .map((d) => d.replace(/^animation-name\s*:/, ""));
      const foreverCount = declarations.some((d) => /^animation-iteration-count\s*:.*infinite/.test(d));
      const runs: string[] = [];
      for (const value of shorthand)
        for (const part of splitTopLevel(value))
          if (/\binfinite\b/.test(part) || foreverCount)
            runs.push(...part.split(/\s+/).filter((w) => keyframes.has(w)));
      if (foreverCount) for (const value of named) runs.push(...splitTopLevel(value).filter((w) => keyframes.has(w)));
      for (const name of new Set(runs)) {
        const props = flicker(keyframes.get(name)!);
        if (props.length) loops.push({ file, keyframes: name, selector: selector.replace(/\s+/g, " "), props });
      }
    }
  }
  return loops;
}

const shipped = stylesheets(src).map((full) => ({ file: path.relative(src, full), css: readFileSync(full, "utf8") }));
const loops = flickerLoops(shipped);
const allowed = (loop: Loop) =>
  ALLOWED.some((a) => a.file === loop.file && a.keyframes === loop.keyframes && loop.selector.includes(a.selector));

describe("no breathing or blinking dots", () => {
  test("the check reads the shipped stylesheets and finds their loops", () => {
    expect(shipped.length).toBeGreaterThan(50);
    // A loop it must see, so an empty result can't pass by reading nothing.
    expect(loops.some((l) => l.keyframes === "acpmux-mic-wait")).toBe(true);
  });

  test("it catches a breathing dot under any name, in a media query, by shorthand or longhands", () => {
    const css = `
      @keyframes glow { 50% { opacity: .3 } }
      @keyframes throb { to { transform: scale(1.4) } }
      @keyframes flash { 50% { visibility: hidden } }
      @keyframes turn { to { transform: rotate(1turn) } }
      @media (prefers-reduced-motion: no-preference) { .a-dot { animation: glow 2s ease-in-out infinite alternate } }
      .b-mark[data-working] { animation-name: throb; animation-iteration-count: infinite }
      .c-status { color: red; .c-inner { animation: flash 1s steps(1) infinite } }
      .d-spinner { animation: turn 900ms linear infinite }
      .e-once { animation: glow 2s ease-out 1 }`;
    const found = flickerLoops([{ file: "x.css", css }]).map(
      (l) => `${l.selector} ${l.keyframes} ${l.props.join("+")}`,
    );
    expect(found).toEqual([
      ".a-dot glow opacity",
      ".b-mark[data-working] throb scale",
      ".c-status .c-inner flash visibility",
    ]);
  });

  test("no stylesheet fades, blinks or pulses a dot forever", () => {
    const offenders = loops
      .filter((loop) => !allowed(loop))
      .map((l) => `${l.file}: ${l.selector} runs ${l.keyframes} (${l.props.join(", ")})`);
    expect(offenders).toEqual([]);
  });

  test("every allowed loop still exists, so the list can't hide a new one", () => {
    const stale = ALLOWED.filter((a) => !a.goneWith)
      .filter(
        (a) => !loops.some((l) => l.file === a.file && l.keyframes === a.keyframes && l.selector.includes(a.selector)),
      )
      .map((a) => `${a.file} ${a.keyframes}`);
    expect(stale).toEqual([]);
  });
});
