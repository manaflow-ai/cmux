import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// Leo 2026-10-19: "the spinner should NOT have a background". The harness health notice draws the
// arc Spinner with the class acpmux-harness-spinner, and the Harnesses screen's CSS ring spinner used
// the same class unscoped. App.tsx imports that screen statically, so its 35% border ring loaded
// everywhere and drew a circle behind the notice's arc. The ring belongs to the screen's rows only,
// and even there only the arc draws: the rest of the circle is transparent, not a faint track.
const css = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/harnesses/harnesses.css"), "utf8");

test("the Harnesses screen's ring spinner never reaches the notice's arc", () => {
  const selectors = [...css.matchAll(/([^{}]*\.acpmux-harness-spinner[^{]*)\{/g)].flatMap((match) =>
    match[1].split(",").map((selector) => selector.replace(/@media[^{]*\{/, "").trim()),
  );
  const spinnerSelectors = selectors.filter((selector) => selector.includes(".acpmux-harness-spinner"));
  expect(spinnerSelectors.length).toBeGreaterThan(0);
  expect(spinnerSelectors.filter((selector) => !selector.includes(".acpmux-harness-row "))).toEqual([]);
});

test("the Harnesses row spinner draws its arc with no track circle behind it", () => {
  const rule = css.match(/\.acpmux-harness-row \.acpmux-harness-spinner\{([^}]*)\}/)?.[1] ?? "";
  expect(rule).toContain("border:1.5px solid transparent");
  expect(rule).toContain("border-top-color:var(--agent-muted)");
});
