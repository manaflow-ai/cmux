// Verbose opens every Shell block, so a Wrap lines button at rest on each repeated one control down
// the transcript (#28782's review). Wrap lines is one choice for every Shell block (blockWrap.ts):
// hidden at rest, shown on its own block's hover or keyboard focus; the chat menu's Transcript view
// submenu has it once.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

const css = readFileSync(
  path.resolve(import.meta.dir, "../src/agent-session/acpmux/conversation/conversation.css"),
  "utf8",
);
const rules = [...css.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/([^{}]+)\{([^{}]*)\}/g)].map((match) => ({
  selectors: match[1]!
    .split(/,(?![^()]*\))/)
    .map((selector) => selector.trim())
    .filter(Boolean),
  body: match[2]!,
}));

test("a Shell block's Wrap lines is hidden at rest", () => {
  // Its fade (the shared hover tokens) is a separate transition rule; the rest state is its opacity.
  const rest = rules.filter(
    (rule) => rule.selectors.includes(".cv-shell__actions .cv-shell__wrap") && /opacity:/.test(rule.body),
  );
  expect(rest.map((rule) => rule.body.replace(/\s+/g, " ").trim())).toEqual(["opacity: 0;"]);
});

test("only its own block's hover or keyboard focus shows it", () => {
  const lit = rules
    .filter((rule) => /opacity:\s*1/.test(rule.body))
    .flatMap((rule) => rule.selectors)
    .filter((selector) => selector.includes("cv-shell__wrap"));
  expect(lit.sort()).toEqual([".cv-shell:focus-within .cv-shell__wrap", ".cv-shell:hover .cv-shell__wrap"]);
});
