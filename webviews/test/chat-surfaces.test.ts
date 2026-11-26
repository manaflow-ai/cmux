// One set of chat surface levels (Lawrence 2026-11-19, a see-through chat over a wallpaper: the
// "Edited PROPOSAL.md" card nearly clear with a faint ring, the "rate limited" error card under it a
// darker frosted fill, its icon tile and outlined buttons on yet other fills: "bgs are different, we
// need to make all bgs consistent, from first principles"). design/chat-surfaces.md has the levels.
//
// The cause: the two cards were two materials. The edit card painted the page colour (opaque in an
// opaque window, clear in a see-through one) with a 3% wash on its head and a ring in the theme's
// separator, its tile the page colour mixed with black (a dark hole over a picture); the error card
// was floating glass (`.ui-glass` with the transient veil: the theme surface at 42-55% and a 32 px
// backdrop blur) though it sits in the transcript like every tool card. Every content card now
// paints one level, the page's ink over clear: the same step over an opaque page, the window's glass,
// a wallpaper or a custom background, in light and dark.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

import designScale from "../../schemas/design-scale/design-scale.json";
import { rawChatFills, statesReplacingFilledRest, togglesOnWithPressedFill } from "../scripts/check-chat-surfaces";
import baseline from "./chat-surfaces.baseline.json";

const source = (file: string) => readFileSync(new URL(`../src/${file}`, import.meta.url), "utf8");

/// The chat's stylesheets in the order the pane loads them (build-agent-pane-web.sh).
const SHEETS = [
  "agent-session/acpmux/styles.css",
  "agent-session/acpmux/conversation/conversation.css",
  "agent-session/acpmux/conversation/EditedFilesCard.css",
  "agent-session/acpmux/turnChanges/turnChanges.css",
  "agent-session/acpmux/subagents/AgentCard.css",
];

type Rule = { sheet: string; selectors: string[]; body: string };

/// Every innermost rule: its selector list (comments stripped, split at top-level commas) and body.
function rules(): Rule[] {
  const out: Rule[] = [];
  for (const sheet of SHEETS) {
    const text = source(sheet).replace(/\/\*[\s\S]*?\*\//g, "");
    for (const match of text.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
      const selectorText = match[1]!.trim();
      if (selectorText.startsWith("@")) continue;
      const selectors: string[] = [];
      let depth = 0;
      let current = "";
      for (const char of selectorText) {
        if (char === "(") depth += 1;
        if (char === ")") depth -= 1;
        if (char === "," && depth === 0) {
          selectors.push(current.trim().replace(/\s+/g, " "));
          current = "";
        } else current += char;
      }
      selectors.push(current.trim().replace(/\s+/g, " "));
      out.push({ sheet, selectors, body: match[2]! });
    }
  }
  return out;
}

const ALL = rules();

/// The values of `property` (and its longhand -color) in every rule that names one of `selectors`.
function declarations(selectors: string[], property: RegExp): string[] {
  const out: string[] = [];
  for (const rule of ALL) {
    if (!rule.selectors.some((selector) => selectors.includes(selector))) continue;
    for (const match of rule.body.matchAll(/([\w-]+)\s*:\s*([^;]+)/g))
      if (property.test(match[1]!)) out.push(match[2]!.trim().replace(/\s+/g, " "));
  }
  return out;
}

const BACKGROUND = /^background(-color)?$/;
const RING = /^(box-shadow|border(-color)?)$/;

/// The transcript's content cards: each one's own selectors (a card's ring may be on its ::after).
const CARDS: Record<string, string[]> = {
  "edited files": [".acpmux-edited", "div.acpmux-edited", ".acpmux-edited::after"],
  "turn error": [".cv-turn-error--card"],
  "tool error": [".cv-tool-error-card"],
  "shell command": [".cv-shell"],
  "tool output": [".cv-tool-output", ".cv-tool-output__box"],
  "MCP call": [".cv-mcp-call__body"],
  "tool fields": [".cv-tool-detail__fields"],
  "permission ask": [".acpmux-ask"],
  "shell block": [".acpmux-shell-block"],
  "run elsewhere": [".cv-run-elsewhere"],
  "code block": [".cv-codeblock"],
  subagent: [".cv-agent-card"],
};

test("the edit card and the error card from the screenshot are one surface level", () => {
  const edit = CARDS["edited files"]!;
  const error = CARDS["turn error"]!;
  expect([...new Set(declarations(edit, BACKGROUND))]).toEqual(["var(--ds-surface-card)"]);
  expect(declarations(error, BACKGROUND)).toEqual(["var(--ds-surface-card)"]);
  for (const card of [edit, error]) {
    const rings = declarations(card, RING);
    expect(rings.length).toBeGreaterThan(0);
    for (const ring of rings) expect(ring).toContain("var(--ds-surface-card-line)");
    // Content is never glass: no frost and no veil of its own (design/surface-materials.md).
    expect(declarations(card, /^(-webkit-)?backdrop-filter$|^--glass-tint$/)).toEqual([]);
  }
  // The error card's card arm is not a floating glass surface.
  const rows = source("agent-session/acpmux/conversation/TurnRows.tsx");
  expect(rows).not.toMatch(/cv-turn-error--\$\{arm\}[^`]*ui-glass/);
  expect(rows).not.toContain("ui-transient-error");
  // The tile inside the edit card is the inset level, never the page colour mixed with black.
  expect(declarations([".acpmux-edited-icon", ".acpmux-edited .acpmux-edited-icon"], BACKGROUND)).toEqual([
    "var(--ds-surface-inset)",
    "var(--ds-surface-inset)",
  ]);
  // Their secondary buttons draw one outline.
  for (const button of [[".acpmux-review-changes"], [".cv-turn-auth-action"]]) {
    const rings = declarations(button, RING).filter((ring) => ring !== "0" && ring !== "none");
    expect(rings.length, button[0]).toBeGreaterThan(0);
    for (const ring of rings) expect(ring, button[0]).toContain("var(--ds-surface-control-line)");
  }
});

test("every content card in the transcript paints the card level and its line", () => {
  for (const [name, selectors] of Object.entries(CARDS)) {
    const fills = declarations(selectors, BACKGROUND);
    expect(fills.length, name).toBeGreaterThan(0);
    // A card a transcript look styles names the look's card paint (--cv-card-fill, which body maps
    // onto the card level) and its ring (--cv-look-card-ring, the card line until a look's
    // toolCard.border none clears it), #46848.
    for (const fill of new Set(fills)) expect(fill, name).toMatch(/^var\(--(ds-surface-card|cv-card-fill)\)$/);
    const rings = declarations(selectors, RING).filter((ring) => ring !== "0" && ring !== "none");
    expect(rings.length, name).toBeGreaterThan(0);
    for (const ring of rings) expect(ring, name).toMatch(/var\(--(ds-surface-card-line|cv-look-card-ring)\)/);
  }
});

test("the levels are card, inset, hover and control, the page's ink over clear, in desktop.css", () => {
  const levels = designScale.surfaces.levels;
  expect(levels.map((level) => level.name)).toEqual(["card", "inset", "hover", "control"]);
  const desktop = source("pages/shared/desktop.css");
  for (const level of levels) {
    if ("fill" in level)
      expect(desktop).toContain(
        `--ds-surface-${level.name}: color-mix(in srgb, var(--ds-surface-ink) ${level.fill}%, transparent);`,
      );
    if ("line" in level)
      expect(desktop).toContain(
        `--ds-surface-${level.name}-line: color-mix(in srgb, var(--ds-surface-ink) ${level.line}%, transparent);`,
      );
  }
  // The pane's ink is its own text colour.
  expect(source("agent-session/shared/styles.css")).toContain("--ds-surface-ink: var(--agent-text);");
  // The chat's own aliases name the levels.
  const conversation = source("agent-session/acpmux/conversation/conversation.css");
  expect(conversation).toContain("--cv-codeblock-bg: var(--ds-surface-card);");
  expect(conversation).toContain("--cv-code-bg: var(--ds-surface-inset);");
});

test("no chat stylesheet adds a raw fill: the backlog of older ones only shrinks", () => {
  const found = rawChatFills();
  const counts = Object.fromEntries(Object.entries(found).map(([file, list]) => [file, list.length]));
  const over: string[] = [];
  const stale: string[] = [];
  for (const [file, list] of Object.entries(found)) {
    const allowed = (baseline as Record<string, number>)[file] ?? 0;
    if (list.length > allowed)
      over.push(`${file}: ${list.length} raw fills, the backlog allows ${allowed}:\n  ${list.join("\n  ")}`);
  }
  for (const [file, allowed] of Object.entries(baseline as Record<string, number>))
    if ((counts[file] ?? 0) < allowed)
      stale.push(`${file}: ${counts[file] ?? 0} now, lower its backlog from ${allowed}`);
  // A new fill names a level (--ds-surface-*), a state (--ds-color-hover, -pressed, -selection) or a
  // role colour; one that truly is a colour of its own says why (chat-surface-allow: <reason>).
  expect(over).toEqual([]);
  expect(stale).toEqual([]);
});

// A filled button ("Retry" on the new tab, the queue's buttons, "Try again" on an unavailable chat)
// rests on the inset level (ink 8%); its hover moved to the host's hover (ink 4 to 5%) in place of the
// rest, so the pointer lightened it. A state over a filled rest is a layer on that rest.
test("a hover or press never paints over a filled rest with a quieter fill", () => {
  expect(statesReplacingFilledRest()).toEqual([]);
});

// The diff's view toggles and the usage sort showed "on" with the pressed fill, so a press on an on
// toggle showed nothing. On is the checked segment: the selection fill.
test("a toggle that is on shows the selection fill, not the press", () => {
  expect(togglesOnWithPressedFill()).toEqual([]);
});

// The scripted move put every chat hover (ink 4 to 12%, most 6%) on the host's chrome hover: ink 4% in a
// light theme, a step of ΔL* 3.1 over an opaque page and 2.2 over a wallpaper on a fleet Mac (6% read
// 4.5 and 3.2), so Undo and View changes all but lost their hover in light. A control in the page hovers
// at the hover level, half way from clear to the press, and never at the host's chrome share.
test("a control in the page hovers at the hover level, between clear and the press", () => {
  const share = (name: string) => designScale.surfaces.levels.find((level) => level.name === name)?.fill ?? 0;
  expect(share("hover")).toBeGreaterThan(share("card"));
  expect(share("hover")).toBeLessThan(share("inset"));
  const edited = source("agent-session/acpmux/styles.css");
  for (const selector of [".acpmux-edited-undo:hover:not(:disabled)", ".acpmux-review-changes:hover"])
    expect(edited).toContain(`${selector}{background:var(--ds-surface-hover)`);
  expect(source("pages/shared/desktop.css")).toContain(
    "--ds-surface-hover-layer: linear-gradient(var(--ds-surface-hover), var(--ds-surface-hover));",
  );
});
