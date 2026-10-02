import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";

// With Reduce Motion on (as on the macOS CI VMs and for users who turn it on), the
// transcript must not animate: every transition and animation sits inside
// `@media (prefers-reduced-motion: no-preference)`, so it runs only when the setting is off.
const css = readFileSync(new URL("./conversation.css", import.meta.url), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");

/** Each `transition` or `animation` declaration with the at-rules it is nested in. */
function motionDeclarations(source: string) {
  const found: { declaration: string; media: string[] }[] = [];
  const stack: string[] = [];
  let prelude = "";
  for (const char of source) {
    if (char === "{") {
      stack.push(prelude.trim());
      prelude = "";
    } else if (char === "}") {
      stack.pop();
      prelude = "";
    } else if (char === ";") {
      const declaration = prelude.trim();
      if (/^(transition|animation)(-[a-z-]+)?\s*:/.test(declaration) && !/:\s*none\b/.test(declaration))
        found.push({ declaration, media: stack.filter((rule) => rule.startsWith("@media")) });
      prelude = "";
    } else prelude += char;
  }
  return found;
}

describe("transcript motion", () => {
  const motion = motionDeclarations(css);

  test("the transcript animates when Reduce Motion is off", () => {
    // The fold and tool chevrons turn; this guards the parser against passing on an empty list.
    expect(motion.length).toBeGreaterThan(0);
  });

  test("nothing animates when Reduce Motion is on", () => {
    const unguarded = motion.filter(
      ({ media }) => !media.some((rule) => /prefers-reduced-motion:\s*no-preference/.test(rule)),
    );
    expect(unguarded.map(({ declaration }) => declaration)).toEqual([]);
  });
});
