// Leo 2026-11-07, on the sidebar's "Updated to Nightly" card beside the agent composer: "the border
// styles, the glass intensity is different. For two, it's like the heights never match up with
// anything". The card wears the composer's material and box from one set of shared tokens
// (ui/glass/composerMaterial.css). These read the composer's own stylesheets and fail when the shared
// tokens drift from what the composer draws, or when the card stops using them.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const read = (file: string) => readFileSync(new URL(`../src/${file}`, import.meta.url), "utf8");
const material = read("ui/glass/composerMaterial.css");
const composerStates = read("agent-session/acpmux/composerStates.css");
const composerStyles = read("agent-session/acpmux/styles.css");
const desktop = read("pages/shared/desktop.css");
const card = read("pages/changelog/updateSurfaces.css");

/** The value of `--name:` in `css` (the first declaration), spaces collapsed. */
function declaration(css: string, name: string): string {
  const match = new RegExp(`${name}:\\s*([^;]+);`).exec(css);
  expect(match, `${name} is declared`).not.toBeNull();
  return match![1]!.replace(/\s+/g, " ").trim();
}

/** The percentages a value mixes, in order. */
const shares = (value: string) => value.match(/\d+(?:\.\d+)?%/g) ?? [];

test("the shared solid surface mixes the composer's shares", () => {
  expect(shares(declaration(material, "--composer-material-solid"))).toEqual(
    shares(declaration(composerStates, "--acpmux-composer-solid")),
  );
});

test("the shared edge is the composer's edge share, one hairline on every side", () => {
  expect(shares(declaration(material, "--composer-material-edge"))).toEqual(
    shares(declaration(composerStyles, "--acpmux-composer-edge")),
  );
  expect(declaration(material, "--composer-material-ring")).toContain("inset 0 0 0 var(--cmux-hairline");
});

/** What a `color-mix(in srgb, A N%, B)` value mixes toward: its last argument, B. */
const mixTarget = (value: string) => /,\s*([^,]+(?:\([^()]*(?:\([^()]*\))?[^()]*\))?)\s*\)$/.exec(value)?.[1]?.trim();

test("the shared edge mixes toward the page under it, as the composer's does, so an opaque theme draws the same line", () => {
  const composer = mixTarget(declaration(composerStyles, "--acpmux-composer-edge"));
  const shared = mixTarget(declaration(material, "--composer-material-edge"));
  expect(composer).toStartWith("var(--agent-page-bg");
  expect(shared).toStartWith("var(--agent-page-bg");
  expect(shared).not.toBe("transparent");
});

test("the shared rim is the composer's top-lit rim", () => {
  expect(shares(declaration(material, "--composer-material-rim"))).toEqual(
    shares(declaration(composerStates, "--acpmux-composer-rim")),
  );
});

test("the shared tint is the popover level the composer's card takes, clearer over art", () => {
  expect(composerStates).toMatch(
    /--glass-tint: color-mix\(in srgb, var\(--acpmux-composer-solid\) var\(--ds-glass-popover-tint\)/,
  );
  expect(composerStates).toMatch(
    /--glass-tint: color-mix\(in srgb, var\(--acpmux-composer-solid\) var\(--ds-glass-popover-art-tint\)/,
  );
  expect(declaration(material, "--composer-material-tint")).toContain("var(--ds-glass-popover-tint");
  expect(material).toMatch(/data-cmux-see-through[^{]*\{\s*--composer-material-tint:[^;]*--ds-glass-popover-art-tint/);
});

test("the shared box is the one-line composer's height and corner (grid.md 5.1)", () => {
  expect(declaration(material, "--composer-material-height")).toContain("var(--grid-composer-box");
  expect(declaration(material, "--composer-material-radius")).toContain("var(--grid-composer-radius");
  expect(declaration(desktop, "--grid-composer-box")).toContain("48px");
  // The composer's box takes the same corner token.
  expect(read("agent-session/acpmux/composerLocation.css")).toContain(
    "--acpmux-composer-radius: var(--grid-composer-radius)",
  );
});

test("the Updated card paints the shared material at the composer's height", () => {
  const surface = /\.wn-card\.wn-updated \{([^}]*)\}/.exec(card)?.[1] ?? "";
  expect(surface).toContain("background: var(--composer-material-tint)");
  expect(surface).toContain("box-shadow: var(--composer-material-ring), var(--composer-material-rim)");
  expect(surface).toContain("border-radius: var(--composer-material-radius)");
  const rest = /\.wn-updated \.wn-card-rest \{([^}]*)\}/.exec(card)?.[1] ?? "";
  expect(rest).toContain("height: var(--composer-material-height)");
});

// Review F3 of #37615: the sidebar no longer draws a native glass under the card's page, so the
// card with the theme's doodle decoration paints the composer's material itself too, or it has none.
test("the doodle-decorated card wears the same material", () => {
  const surface = /\.wn-card\[data-decoration="doodle"\] \{([^}]*)\}/.exec(card)?.[1] ?? "";
  expect(surface).toContain("background: var(--composer-material-tint)");
  expect(surface).toContain("box-shadow: var(--composer-material-ring), var(--composer-material-rim)");
  expect(surface).toContain("border-radius: var(--composer-material-radius)");
  const tsx = read("pages/changelog/UpdateSurfaces.tsx");
  const doodle = /<section[^>]*data-decoration="doodle"[^>]*>/s.exec(tsx)?.[0] ?? "";
  expect(doodle).toContain('data-composer-material=""');
  expect(doodle).not.toContain("ui-glass");
});

// Review F1 of #37743: the composer wears the shared glass material (glass.css "GLASS MATERIAL":
// its specular rim and two-step depth), so the card beside it reads the same rim and depth, under the
// same conditions: not under Reduce Transparency, and not the lens's own rim over a see-through window.
test("where the composer wears the glass material, the card's rim and depth are that material's", () => {
  const override = /@media not \(prefers-reduced-transparency: reduce\) \{([\s\S]*?)\n\}/.exec(material)?.[1] ?? "";
  expect(override).toContain("--composer-material-rim: var(--glass-material-rim)");
  expect(override).toContain("--composer-material-depth: var(--glass-material-depth-composer)");
  expect(override).toContain("data-reduce-transparency");
  expect(override).toMatch(/data-cmux-see-through[^{]*data-glass="lens"/);
  expect(declaration(material, "--composer-material-depth")).toBe("0 0 transparent");
  for (const selector of ["\\.wn-card\\.wn-updated", '\\.wn-card\\[data-decoration="doodle"\\]']) {
    const surface = new RegExp(`${selector} \\{([^}]*)\\}`).exec(card)?.[1] ?? "";
    expect(surface).toContain(
      "box-shadow: var(--composer-material-ring), var(--composer-material-rim), var(--composer-material-depth)",
    );
  }
});
