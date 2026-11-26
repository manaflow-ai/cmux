// The composer's hover glass ring (Leo 2026-10-20: "on hover, the Claude desktop, like that gives you
// the focus ring ... it's the glass type focus ring. So it's not just one hard bar"). Reads the
// stylesheets, as focus-modality.test.ts does:
// - the pointer over the card (the chat's and the New Tab's) sets --acpmux-composer-halo, a band of
//   spread-only box-shadow rings in the glass's edge color: no border, no outline, no blur, nothing
//   that moves the layout, and no hard-coded color;
// - the band is weaker going out, and the card at rest draws the same rings transparent, so the
//   change is a color fade the transition can run (a list of another length would jump);
// - every box-shadow the card draws with its ring carries the band;
// - the ring and band ease on box-shadow with the motion tokens, only under
//   prefers-reduced-motion: no-preference, and never from a bare :focus or :focus-within.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const acpmux = path.resolve(import.meta.dir, "../src/agent-session/acpmux");
const read = (file: string) => fs.readFileSync(path.join(acpmux, file), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
const states = read("composerStates.css");

/** The declarations of the first rule whose selector list matches `selector`. */
function block(css: string, selector: RegExp): string {
  const match = new RegExp(`${selector.source}[^{}]*\\{([^{}]*)\\}`).exec(css);
  expect(match, `a rule for ${selector}`).not.toBeNull();
  return match![1]!;
}

/** The top-level comma-separated layers of a shadow value. */
function layers(value: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < value.length; i++) {
    if (value[i] === "(") depth++;
    else if (value[i] === ")") depth--;
    else if (value[i] === "," && depth === 0) {
      out.push(value.slice(start, i).trim());
      start = i + 1;
    }
  }
  return [...out, value.slice(start).trim()].filter(Boolean);
}

const halo = (declarations: string) => {
  const value = /--acpmux-composer-halo:\s*([^;]+);/.exec(declarations)?.[1];
  expect(value, "sets --acpmux-composer-halo").toBeDefined();
  return layers(value!);
};

describe("composer hover glass ring", () => {
  const hover = block(states, /\.acpmux-composer-box:not\(\[data-composer-v2\]\):hover,\s*\.nt-box:hover\s*/);
  const rest = block(states, /\n\.acpmux-composer-box,\s*\.nt-box\s*/);

  test("hover sets a band of spread-only rings in the glass edge's color, weaker going out", () => {
    const band = halo(hover);
    expect(band.length).toBe(2);
    for (const layer of band) {
      expect(layer, "an outer ring, not inset").not.toContain("inset");
      expect(layer, "no blur: 0 0 0 <spread>").toMatch(/^0 0 0 /);
      expect(layer, "the glass's edge color").toContain("var(--glass-edge)");
      expect(layer, "no hard-coded color").not.toMatch(/#[0-9a-f]{3,8}\b|rgba?\(/i);
    }
    const strength = band.map((layer) => Number(/var\(--glass-edge\)\s+(\d+)%/.exec(layer)![1]));
    expect(strength[0]!).toBeGreaterThan(strength[1]!);
    expect(hover, "box-shadow only: no border or outline").not.toMatch(/\b(border|outline)\s*:/);
  });

  test("at rest the same rings draw transparent, so hover fades their color", () => {
    const band = halo(rest);
    expect(band.length).toBe(halo(hover).length);
    for (const layer of band) expect(layer).toMatch(/^0 0 0 .* transparent$/);
  });

  test("the band is the hover's: Increase Contrast keeps the shared ring alone", () => {
    expect(states).toMatch(
      /@media \(hover: hover\) and \(not \(prefers-contrast: more\)\)\s*\{\s*\.acpmux-composer-box:not\(\[data-composer-v2\]\):hover/,
    );
  });

  test("every box-shadow the card draws with its ring carries the band", () => {
    const sheets = ["composerStates.css", "composerLocation.css", "styles.css"].map(read).join("\n");
    const withRing = [...sheets.matchAll(/box-shadow:\s*var\(--acpmux-card-ring\)([^;}]*)/g)].filter(
      // The queue's ring layer and the subagent tray draw the ring alone, round more than the card.
      (match) => match[1]!.trim() !== "",
    );
    expect(withRing.length).toBeGreaterThan(3);
    for (const match of withRing) expect(match[0]).toContain("var(--acpmux-composer-halo");
  });

  test("the ring and band ease on box-shadow with motion tokens, only without reduced motion", () => {
    const motion =
      /@media \(prefers-reduced-motion: no-preference\)\s*\{\s*\.acpmux-composer-box,\s*\.nt-box\s*\{([^}]*)\}/.exec(
        states,
      );
    expect(motion, "the transition sits under prefers-reduced-motion: no-preference").not.toBeNull();
    expect(motion![1]).toMatch(/transition:\s*box-shadow var\(--agent-motion-[a-z]+\) var\(--agent-ease-out\)/);
    const rules = [...states.matchAll(/([^{}]*)\{[^{}]*--acpmux-composer-halo:/g)].map((m) => m[1]!);
    for (const selector of rules)
      expect(selector, "no ring from a bare :focus or :focus-within").not.toMatch(/:focus(?!-visible)/);
  });
});
