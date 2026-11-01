// Every hover card in the web UI is glass, never a solid card (Leo, 2026-10-21: "STOP DOING SOLID.
// WE HAVE GLASS, SO JUST USE GLASS."). The cards a pointer opens by resting on something:
//   - a link's or a pull request's hover card (chips/LinkHoverCard.tsx, also the PR dock bars);
//   - a session reference's hover card (started/SessionHoverCard.tsx);
//   - a New Tab suggestion row's hover card (newtab/StageCards.tsx);
//   - the thread minimap's mark preview (threadMinimap/PreviewCard.tsx).
// Each renders the shared liquid glass (.ui-glass, ui/glass/glass.css) or, for the minimap card, the
// tooltip glass (the tooltip tint over the shared blur). No stylesheet may lay a solid fill on one
// of them or switch its blur off, except under Reduce Transparency, where the shared tokens turn
// every glass solid on their own (pages/shared/desktop.css). The native hover cards share one glass
// window (HoverCardPanel; scripts/cmux-next/check-overlay-glass.py and
// FloatingSurfacesStayGlassTests keep it glass).
import { expect, test } from "bun:test";
import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SRC = new URL("../src/", import.meta.url).pathname;

/// Each hover card: the component that renders it and the class that names its root.
const CARDS = [
  { file: "agent-session/acpmux/chips/LinkHoverCard.tsx", root: "cv-link-preview", glass: "ui-glass" },
  { file: "agent-session/acpmux/chips/LinkHoverCard.tsx", root: "acpmux-pr-card", glass: "ui-glass" },
  { file: "agent-session/acpmux/started/SessionHoverCard.tsx", root: "acpmux-session-hover-card", glass: "ui-glass" },
  { file: "agent-session/acpmux/newtab/StageCards.tsx", root: "nt-hovercard", glass: "ui-glass" },
  // Not .ui-glass: the tooltip tint over the shared blur (thread-minimap-card-glass.test.ts).
  { file: "agent-session/acpmux/threadMinimap/PreviewCard.tsx", root: "acpmux-minimap__card", glass: null },
] as const;
const ROOTS = [...new Set(CARDS.map((card) => card.root))];

/// A fill that keeps a card glass: the glass's own tint, the tooltip tint, none, or a mix that
/// fades to transparent. Anything else (the popup surface, a page color, a hex) is a solid card.
const GLASS_FILL = /^(none|transparent|var\(--(glass-tint|tooltip-tint)\b.*|color-mix\(.*\btransparent\b.*\))$/;
const GLASS_BLUR = /^var\(--(glass-backdrop|tooltip-blur|surface-blur)\b|blur\(/;
const REDUCE_TRANSPARENCY = /reduce-transparency|reduced-transparency/;

type Rule = { file: string; selector: string; context: string; body: string };

/// Every style rule in `css` with the at-rules around it, comments dropped.
function rules(file: string, css: string): Rule[] {
  const text = css.replace(/\/\*[\s\S]*?\*\//g, "");
  const out: Rule[] = [];
  const stack: string[] = [];
  let start = 0;
  for (let index = 0; index < text.length; index++) {
    const char = text[index];
    if (char === "{") {
      const prelude = text.slice(start, index).trim();
      const close = matching(text, index);
      const inner = text.slice(index + 1, close);
      if (prelude.startsWith("@") || /\{/.test(inner)) {
        // An at-rule, or a rule with nested rules: walk into it.
        stack.push(prelude);
        out.push(...rules(file, inner).map((rule) => ({ ...rule, context: [...stack, rule.context].join(" ") })));
        stack.pop();
        if (!prelude.startsWith("@"))
          out.push({ file, selector: prelude, context: stack.join(" "), body: inner.replace(/[^;{}]*\{[^}]*\}/g, "") });
      } else {
        out.push({ file, selector: prelude, context: stack.join(" "), body: inner });
      }
      index = close;
      start = close + 1;
    } else if (char === ";" && stack.length === 0) {
      start = index + 1;
    }
  }
  return out;
}

function matching(text: string, open: number): number {
  let depth = 0;
  for (let index = open; index < text.length; index++) {
    if (text[index] === "{") depth++;
    else if (text[index] === "}" && --depth === 0) return index;
  }
  return text.length;
}

/// The declarations `name: value` of a rule body (the last one wins, as in CSS).
function declarations(body: string): Map<string, string> {
  const map = new Map<string, string>();
  for (const part of body.split(";")) {
    const colon = part.indexOf(":");
    if (colon < 0) continue;
    map.set(
      part.slice(0, colon).trim().toLowerCase(),
      part
        .slice(colon + 1)
        .replace(/!important/, "")
        .trim(),
    );
  }
  return map;
}

/// The hover card a selector styles: the root class in its subject (last) compound, as a whole
/// class name (`.cv-link-preview`, not `.cv-link-preview__open` or `.nt-hovercard-body`).
function cardOf(selector: string, roots: readonly string[]): string | null {
  const subject =
    selector
      .trim()
      .split(/\s*[\s>+~]\s*/)
      .pop() ?? "";
  for (const root of roots) {
    if (new RegExp(`\\.${root.replaceAll("-", "\\-")}(?![\\w-])`).test(subject)) return root;
  }
  return null;
}

function cssFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return name === "node_modules" ? [] : cssFiles(path);
    return name.endsWith(".css") ? [path] : [];
  });
}

/// Every rule that paints one of `roots` solid or takes its blur away, outside Reduce Transparency.
function solidHoverCards(dir = SRC, roots: readonly string[] = ROOTS): { findings: string[]; styled: Set<string> } {
  const findings: string[] = [];
  const styled = new Set<string>();
  for (const path of cssFiles(dir)) {
    const file = path.slice(dir.length);
    for (const rule of rules(file, readFileSync(path, "utf8"))) {
      if (REDUCE_TRANSPARENCY.test(rule.context)) continue;
      for (const selector of rule.selector.split(/,(?![^(]*\))/)) {
        if (REDUCE_TRANSPARENCY.test(selector) && !/:not\([^)]*reduce-transparency/.test(selector)) continue;
        const root = cardOf(selector, roots);
        if (!root) continue;
        styled.add(root);
        const decls = declarations(rule.body);
        const bad = (why: string) => findings.push(`${file}: ${selector.trim()} { ${why} }`);
        for (const name of ["background", "background-color", "--glass-tint"]) {
          const value = decls.get(name);
          if (value !== undefined && !GLASS_FILL.test(value)) bad(`${name}: ${value}`);
        }
        for (const name of ["backdrop-filter", "-webkit-backdrop-filter", "--glass-backdrop"]) {
          const value = decls.get(name);
          if (value !== undefined && !GLASS_BLUR.test(value)) bad(`${name}: ${value}`);
        }
      }
    }
  }
  return { findings, styled };
}

test("every hover card renders the shared glass", () => {
  const missing = CARDS.filter(({ file, root, glass }) => {
    const source = readFileSync(join(SRC, file), "utf8");
    // The class strings (double-quoted, one line) that name the card's root.
    const classes = [...source.matchAll(/"([^"\n]*)"/g)].map((match) => match[1]!.split(/\s+/));
    const named = classes.filter((list) => list.includes(root));
    if (named.length === 0) return true;
    return glass !== null && !named.every((list) => list.includes(glass));
  });
  expect(missing.map(({ file, root }) => `${file}: .${root}`)).toEqual([]);
});

test("no stylesheet paints a hover card solid or takes its blur away", () => {
  const { findings, styled } = solidHoverCards();
  expect(findings).toEqual([]);
  // Not vacuous: the scan reads the rules that style each card (the PR card has none of its own:
  // it is the link card with a pull request's body).
  for (const root of ["cv-link-preview", "acpmux-session-hover-card", "nt-hovercard", "acpmux-minimap__card"]) {
    expect(styled.has(root)).toBe(true);
  }
});

test("the scan flags a solid hover card and passes glass and Reduce Transparency", () => {
  const dir = mkdtempSync(join(tmpdir(), "hover-cards-glass-"));
  try {
    writeFileSync(
      join(dir, "fixture.css"),
      [
        ".card-a { background: var(--surface-popup); }",
        ".card-b.ui-card { background-color: #222; }",
        ".x .card-c { backdrop-filter: none; }",
        ":root:not([data-glass]) .card-d.ui-glass { --glass-tint: var(--surface-popup); }",
        ":root:not([data-reduce-transparency]) .card-e { background: Canvas; }",
        ".card-a { background: var(--tooltip-tint, var(--surface-popup)); backdrop-filter: var(--surface-blur); }",
        ".card-b:hover .card-a__open { background: var(--surface-popup); }",
        ".card-c-body { background: #000; }",
        ":root[data-reduce-transparency] .card-a { background: var(--surface-popup); backdrop-filter: none; }",
        "@media (prefers-reduced-transparency: reduce) { .card-b { background: Canvas; } }",
        ".card-d { --glass-tint: color-mix(in srgb, var(--surface-popup) 60%, transparent); }",
      ].join("\n"),
    );
    const { findings } = solidHoverCards(dir + "/", ["card-a", "card-b", "card-c", "card-d", "card-e"]);
    expect(findings.map((line) => line.split(": ").slice(1).join(": ").split(" {")[0])).toEqual([
      ".card-a",
      ".card-b.ui-card",
      ".x .card-c",
      ":root:not([data-glass]) .card-d.ui-glass",
      ":root:not([data-reduce-transparency]) .card-e",
    ]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
