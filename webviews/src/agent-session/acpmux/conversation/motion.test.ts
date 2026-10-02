import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";

// With Reduce Motion on (as on the macOS CI VMs and for users who turn it on), the
// transcript must not animate: every transition and animation sits inside
// `@media (prefers-reduced-motion: no-preference)`, so it runs only when the setting is off.
const sheets = ["./conversation.css", "../styles.css"].map((file) => ({
  file,
  css: readFileSync(new URL(file, import.meta.url), "utf8").replace(/\/\*[\s\S]*?\*\//g, ""),
}));

/** Each `transition` or `animation` declaration with the at-rules it is nested in. */
function motionDeclarations(source: string) {
  const found: { declaration: string; media: string[] }[] = [];
  const stack: string[] = [];
  let prelude = "";
  // A block's last declaration may end at its `}` without a semicolon.
  const take = () => {
    const declaration = prelude.trim();
    if (/^(transition|animation)(-[a-z-]+)?\s*:/i.test(declaration) && !/:\s*none\s*$/i.test(declaration))
      found.push({ declaration, media: stack.filter((rule) => rule.startsWith("@media")) });
    prelude = "";
  };
  for (const char of source) {
    if (char === "{") {
      stack.push(prelude.trim());
      prelude = "";
    } else if (char === "}") {
      take();
      stack.pop();
    } else if (char === ";") take();
    else prelude += char;
  }
  return found;
}

describe("transcript motion", () => {
  const motion = sheets.flatMap(({ file, css }) =>
    motionDeclarations(css).map((found) => ({ ...found, declaration: `${file}: ${found.declaration}` })),
  );

  test("the transcript animates when Reduce Motion is off", () => {
    // The fold and tool chevrons turn; this guards the parser against passing on an empty list.
    expect(motion.length).toBeGreaterThan(0);
  });

  test("nothing animates when Reduce Motion is on", () => {
    const unguarded = motion.filter(
      ({ media }) => !media.some((rule) => /^@media\s+\(\s*prefers-reduced-motion:\s*no-preference\s*\)/i.test(rule)),
    );
    expect(unguarded.map(({ declaration }) => declaration)).toEqual([]);
  });
});
