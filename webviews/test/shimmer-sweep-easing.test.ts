// A shimmer's band speeds up out of its start and slows into its end, never one constant speed
// (Leo, 2026-11-08, "Glimmer pacing": "i know there's some accel/decel aka easing"). The live line's
// and the running rows' pass ran `steps(48, end)`, a linear walk, while the Home shimmers already
// swept on easeInEaseOut. Every shipped shimmer animation takes the motion scale's sweep curve
// (`--cmux-ease-sweep`, schemas/motion-scale), directly or through a token that resolves to it.
// Prototypes and gallery comparison arms are not shipped and are skipped.
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { expect, test } from "bun:test";

const src = path.resolve(import.meta.dir, "../src");

function shippedCss(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const full = path.join(dir, name);
    if (statSync(full).isDirectory()) return name === "prototypes" ? [] : shippedCss(full);
    return name.endsWith(".css") && !name.endsWith(".gallery.css") ? [full] : [];
  });
}

const stripComments = (css: string) => css.replace(/\/\*[\s\S]*?\*\//g, "");

/** `animation:` declarations whose keyframes are a shimmer, as [file, declaration]. */
const sweeps = shippedCss(src).flatMap((file) =>
  [...stripComments(readFileSync(file, "utf8")).matchAll(/animation\s*:\s*([^;}]*)/g)]
    .map((match) => match[1]!.trim())
    .filter((value) => /^[\w-]*(shimmer|glimmer|note-bar)[\w-]*\s/.test(value))
    .map((value) => [path.relative(src, file), value] as const),
);

test("the live line's and running rows' sweeps are found", () => {
  const names = sweeps.map(([, value]) => value.split(/\s+/)[0]);
  expect(names).toContain("cmux-cadenced-shimmer-band");
  expect(names).toContain("cmux-cadenced-shimmer-lit");
});

test("every shipped shimmer sweep eases in and out on the sweep curve", () => {
  const unEased = sweeps.filter(([, value]) => !/var\(--(cmux-ease-sweep|cv-shimmer-sweep-ease)\b/.test(value));
  expect(unEased).toEqual([]);
  const constantSpeed = sweeps.filter(([, value]) => /\b(linear|steps\(|step-start|step-end)\b/.test(value));
  expect(constantSpeed).toEqual([]);
});

test("the chat's sweep token resolves to the motion scale's curve", () => {
  const conversation = stripComments(
    readFileSync(path.join(src, "agent-session/acpmux/conversation/conversation.css"), "utf8"),
  );
  expect(conversation).toMatch(/--cv-shimmer-sweep-ease:\s*var\(--cmux-ease-sweep\b/);
  const desktop = readFileSync(path.join(src, "pages/shared/desktop.css"), "utf8");
  const curve = desktop
    .match(/--cmux-ease-sweep:\s*cubic-bezier\(([^)]*)\)/)?.[1]
    ?.split(",")
    .map(Number);
  expect(curve).toHaveLength(4);
  // Accelerates out of the start (x1 > 0) and decelerates into the end (x2 < 1).
  expect(curve![0]!).toBeGreaterThan(0);
  expect(curve![2]!).toBeLessThan(1);
});
