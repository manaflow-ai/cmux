import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseConfig, lintGeometry, type GeometryArtifact } from "./geometry";
import { parseManifest } from "./runner";

const baseline = JSON.parse(readFileSync(join(import.meta.dir, "geometry-baseline.json"), "utf8"));

test("audit baseline pairs both appearances and every required group has a selector", () => {
  const config = parseConfig(baseline);
  const cases = parseManifest(baseline.cases);
  expect(config.required).toHaveLength(2);
  expect(new Set(config.required.map((value) => value.theme))).toEqual(new Set(["light", "dark"]));
  for (const tuple of config.required) {
    expect(cases.find((value) => value.id === tuple.caseId)?.params?.colorScheme).toBe(tuple.theme);
    for (const rule of config.rules) expect(baseline.selectors[tuple.caseId].some((selection: { group: string }) => selection.group === rule.group)).toBe(true);
  }
});

test("measured two-pixel debt is bounded and missing Context/Connectors cannot hide it", async () => {
  const config = parseConfig(baseline);
  const captures = config.required.map((tuple) => ({ file: "fixture", artifact: {
    schemaVersion: 1, revision: { sha: "a".repeat(40), source: "fixture" }, capture: { ...tuple, viewport: { width: 420, height: 900 }, deviceScaleFactor: 2, screenshot: "fixture.png", screenshotSha256: "0".repeat(64), coordinateSpace: "css-px" },
    elements: Array.from({ length: 7 }, (_, index) => ({ id: `top-block-label:${index}`, group: "top-block-label", source: "dom-rect", kind: "web", rect: { x: index < 5 ? 128 : 126, y: index * 28, width: 30, height: 18 } })),
  } as GeometryArtifact }));
  expect((await lintGeometry(captures, config)).passed).toBe(true);
  captures[0]!.artifact.elements[6]!.rect.x = 125;
  expect((await lintGeometry(captures, config)).passed).toBe(false);
});
