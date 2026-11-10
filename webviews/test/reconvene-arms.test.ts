// The chat look and speed reconvene's gallery entries (src/agent-session/acpmux/reconvene): every
// candidate is tokens only, held to the token-only rule a shipped surface meets
// (scripts/check-design-tokens.ts TOKEN_ONLY_FILES), and every item draws its shipped look and at
// least three candidates (cmuxterm-hq docs/handbook/feature-thrown-in-without-design.md).
import { describe, expect, test } from "bun:test";
import { readdirSync } from "node:fs";
import { join } from "node:path";
import { tokenOnlyFindings } from "../scripts/check-design-tokens";
import type { Arm } from "../src/agent-session/acpmux/reconvene/arm";

const DIR = join(import.meta.dir, "../src/agent-session/acpmux/reconvene");
const FILES = readdirSync(DIR).filter((name) => /\.gallery\.tsx?$/.test(name));

describe("reconvene gallery arms", () => {
  test("there are entries", () => {
    expect(FILES.length).toBeGreaterThan(0);
  });

  test.each(FILES)("%s: the shipped look and at least three candidates, tokens only", async (name) => {
    const mod = (await import(join(DIR, name))) as {
      default: { id: string; variants: Record<string, unknown> };
      ARMS: Record<string, Arm>;
    };
    expect(mod.default.id.startsWith("agent-pane.reconvene-")).toBe(true);
    expect(Object.keys(mod.default.variants)).toContain("now");
    const arms = Object.entries(mod.ARMS ?? {});
    expect(arms.length).toBeGreaterThanOrEqual(3);
    for (const [arm, { css }] of arms) {
      expect(Object.keys(mod.default.variants)).toContain(arm);
      const findings = tokenOnlyFindings(`${name}#${arm}.css`, css).map(
        (finding) => `${arm}: ${finding.selector} { ${finding.property}: ${finding.value} }`,
      );
      expect(findings).toEqual([]);
    }
  });
});
