// The theme slot ratchet (scripts/check-theme-slots.ts): a variant that keeps the budget passes; one with
// a raw duration, a layout property, an ungated loop or a frame loop of its own fails.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  SCHEMA_PATH,
  checkSlots,
  checkVariantCss,
  checkVariantScript,
  type SlotsSchema,
} from "../scripts/check-theme-slots";

const schema = JSON.parse(readFileSync(SCHEMA_PATH, "utf8")) as SlotsSchema;
const gate = schema.motionGate;
const kinds = (css: string) => checkVariantCss("v.css", css, schema).map((problem) => problem.kind);

const good = `
.mark { opacity: 1; transform: none; }
@media (prefers-reduced-motion: no-preference) {
  ${gate} .mark {
    animation: beat var(--cmux-spinner-period) linear infinite;
    animation-delay: calc(var(--cmux-spinner-period) * -0.5);
    transition: transform var(--cmux-motion-micro) var(--cmux-ease-out), opacity var(--cmux-motion-quick) steps(2, end);
  }
}
@keyframes beat { from { opacity: 1; transform: scale(1); } to { opacity: 0.4; transform: scale(0.6); } }
`;

test("the repo's slots keep the budget", () => {
  expect(checkSlots(schema)).toEqual([]);
});

test("a variant on tokens, transform and opacity, under the gate, passes", () => {
  expect(kinds(good)).toEqual([]);
});

test("a raw duration fails, in the shorthand, a delay or a custom property", () => {
  expect(
    kinds(`@media (prefers-reduced-motion: no-preference) { ${gate} .m { animation: beat 300ms linear infinite; } }`),
  ).toEqual(["raw-duration"]);
  expect(kinds(`.m { animation-delay: 1.5s; }`)).toEqual(["raw-duration"]);
  expect(kinds(`.m { --slot-period: 2s; }`)).toEqual(["raw-duration"]);
  expect(kinds(`.m { transition-duration: 0s; }`)).toEqual([]);
});

test("animating a layout or paint property fails", () => {
  expect(kinds(`@keyframes grow { to { width: 2em; } }`)).toEqual(["layout-property"]);
  expect(kinds(`@keyframes tint { to { background-color: red; } }`)).toEqual(["layout-property"]);
  expect(
    kinds(
      `@media (prefers-reduced-motion: no-preference) { ${gate} .m { transition: all var(--cmux-motion-micro) var(--cmux-ease-out); } }`,
    ),
  ).toEqual(["layout-property"]);
  expect(kinds(`.m { will-change: left; }`)).toEqual(["layout-property"]);
});

test("an easing that is not a token, linear or steps fails, as does an unknown --cmux token", () => {
  expect(
    kinds(
      `@media (prefers-reduced-motion: no-preference) { ${gate} .m { animation: beat var(--cmux-spinner-period) ease-in-out infinite; } }`,
    ),
  ).toEqual(["easing"]);
  expect(
    kinds(
      `@media (prefers-reduced-motion: no-preference) { ${gate} .m { animation: beat var(--cmux-made-up) linear infinite; } }`,
    ),
  ).toEqual(["unknown-token"]);
});

test("a loop outside the reduced-motion media query or the motion gate fails", () => {
  expect(kinds(`.m { animation: beat var(--cmux-spinner-period) linear infinite; }`)).toEqual(["ungated"]);
  expect(
    kinds(
      `@media (prefers-reduced-motion: no-preference) { .m { animation: beat var(--cmux-spinner-period) linear infinite; } }`,
    ),
  ).toEqual(["ungated"]);
  expect(kinds(`${gate} .m { animation: beat var(--cmux-spinner-period) linear infinite; }`)).toEqual(["ungated"]);
});

test("a variant script with a frame loop or timer fails; one without passes", () => {
  const bad = [
    "export function Bad() {",
    "  useEffect(() => { const id = requestAnimationFrame(step); return () => cancelAnimationFrame(id); });",
    "  setInterval(tick, 16);",
    "  el.animate([{ opacity: 0 }], 200);",
    "}",
  ].join("\n");
  expect(checkVariantScript("Bad.tsx", bad).map((problem) => problem.line)).toEqual([2, 3, 4]);
  // A mention in a comment is not a loop.
  expect(checkVariantScript("Good.tsx", "// no requestAnimationFrame here\nexport const Good = () => null;\n")).toEqual(
    [],
  );
});

test("the schema needs reduced motion, a stop condition, a box and token-only motion", () => {
  const broken = structuredClone(schema);
  const slot = broken.slots[0]!;
  delete slot.motion!.reducedMotion;
  slot.motion!.stop = "";
  slot.motion!.durations = { loop: "300ms" };
  delete slot.box!.inline;
  const problems = checkSlots(broken).map((problem) => problem.detail);
  expect(problems.some((detail) => detail.includes("reduced-motion"))).toBe(true);
  expect(problems.some((detail) => detail.includes("stop condition"))).toBe(true);
  expect(problems.some((detail) => detail.includes("300ms"))).toBe(true);
  expect(problems.some((detail) => detail.includes("block and inline"))).toBe(true);
});
