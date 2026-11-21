// Every time, duration and length label in the agent chat is one line (Leo, 2026-11-14: "these
// times are still bad and going to next lines!", of a sent video's "0:01" broken into "0:0" over
// "1"). The detector for the class: it finds every class in the chat's CSS whose name says it is a
// time, a duration or a length, and fails on one that no rule keeps on one line, so a new label is
// caught where it is added, not when Leo sees it wrap.
import { expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

const CHAT = path.resolve(import.meta.dir, "../src/agent-session/acpmux");

function cssFiles(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const full = path.join(dir, name);
    if (statSync(full).isDirectory()) out.push(...cssFiles(full));
    else if (name.endsWith(".css")) out.push(full);
  }
  return out;
}

/// The chat's own surfaces: the transcript, its media, the composer's attachments, subagents and
/// background tasks.
const SURFACES = [
  "conversation",
  "chips",
  "subagents",
  "backgroundTasks",
  "composerAttachments.css",
  "composerStates.css",
];

const files = SURFACES.flatMap((name) => {
  const full = path.join(CHAT, name);
  return statSync(full).isDirectory() ? cssFiles(full) : [full];
});

/// `{ selectors, body }` for each plain rule, comments dropped.
function rules(css: string): { selectors: string; body: string }[] {
  const text = css.replace(/\/\*[\s\S]*?\*\//g, "");
  const out: { selectors: string; body: string }[] = [];
  for (const match of text.matchAll(/([^{}]+)\{([^{}]*)\}/g)) out.push({ selectors: match[1]!, body: match[2]! });
  return out;
}

// A class named for a time, a duration or a length: `.cv-turn-time`, `.cv-media__duration`,
// `.cv-user__video-length`.
const LABEL = /\.((?:cv|acpmux)-[\w-]*?(?:[_-]time|[_-]duration|video-length))(?![\w-])/g;

test("every time, duration and length label in the chat stays on one line", () => {
  const all = files.flatMap((file) => rules(readFileSync(file, "utf8")));
  const labels = new Set<string>();
  for (const rule of all) for (const match of rule.selectors.matchAll(LABEL)) labels.add(match[1]!);
  // The detector sees the labels Leo saw wrap and their kin.
  for (const known of ["cv-user__video-length", "cv-turn-time", "cv-worked__time", "cv-media__duration"])
    expect(labels).toContain(known);
  const oneLine = new Set<string>();
  for (const rule of all) {
    if (!/white-space:\s*nowrap/.test(rule.body)) continue;
    for (const selector of rule.selectors.split(",")) {
      // The rule's subject: the selector's last compound, so `.x .cv-turn-time` counts and
      // `.cv-turn-time .y` does not.
      const subject =
        selector
          .trim()
          .split(/\s+|>|~|\+/)
          .at(-1) ?? "";
      for (const match of subject.matchAll(LABEL)) oneLine.add(match[1]!);
    }
  }
  const wraps = [...labels].filter((label) => !oneLine.has(label)).sort();
  expect(wraps).toEqual([]);
});
