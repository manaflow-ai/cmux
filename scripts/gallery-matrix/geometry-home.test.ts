import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { chromium } from "playwright";
import { lintGeometry, parseConfig, type GeometryArtifact } from "./geometry";
import { prepareGeometryCapture } from "./geometry-collector";
import { parseManifest } from "./runner";

const raw = JSON.parse(readFileSync(join(import.meta.dir, "geometry-home.json"), "utf8"));
const config = parseConfig(raw);
// Unit fixtures replay the measured x coordinates; the other box dimensions are synthetic.
function captures(reviewMarkX = 30, reviewLabelX = 54) {
  return config.required.map((tuple) => ({ file: "synthetic-boxes", artifact: {
    schemaVersion: 1,
    revision: { sha: config.revision.sha, source: tuple.source ?? config.revision.source },
    capture: { ...tuple, viewport: { width: 560, height: 640 }, deviceScaleFactor: 2, screenshot: "fixture.png", screenshotSha256: "0".repeat(64), coordinateSpace: "css-px" },
    elements: ["home-marks", "home-labels"].flatMap((group) => Array.from({ length: 6 }, (_, index) => {
      const rect = { x: group === "home-marks" ? index < 4 ? 30 : reviewMarkX : index < 4 ? 54 : reviewLabelX, y: 50 + index * 28, width: 16, height: 16 };
      const subgroup = `home-${index < 4 ? "inbox" : "review"}-${group === "home-marks" ? "marks" : "labels"}`;
      return [{ id: `${group}:${index}`, group, kind: "web", source: "dom-rect", rect }, { id: `${subgroup}:${index}`, group: subgroup, kind: "web", source: "dom-rect", rect: { ...rect } }];
    }).flat()),
  } as GeometryArtifact }));
}

test("Home capture contract exercises every inbox and review row in both appearances", () => {
  const cases = parseManifest(raw.cases);
  expect(cases).toHaveLength(2);
  for (const tuple of config.required) {
    const item = cases.find((item) => item.id === tuple.caseId)!;
    expect(item.params?.colorScheme).toBe(tuple.theme);
    expect(tuple.source ?? config.revision.source).toBe(item.params?.source);
    expect(item.params?.auditScroll).toBe(".acpmux-home-area");
    expect(raw.selectors[tuple.caseId].filter((selection: { group: string }) => ["home-marks", "home-labels"].includes(selection.group)).every((selection: { selector: string }) => selection.selector.includes(".acpmux-home-row >") && selection.selector.includes(".acpmux-home-inbox-"))).toBe(true);
  }
});

test("measured 2px/4px column drift fails, aligned columns pass, and missing evidence fails", async () => {
  const before = await lintGeometry(captures(32, 58), config);
  expect(new Set(before.findings.map((finding) => finding.deltaPx))).toEqual(new Set([2, 4]));
  expect(before.passed).toBe(false);
  expect((await lintGeometry(captures(), config)).passed).toBe(true);
  const missing = captures();
  missing[0]!.artifact.elements.pop();
  expect((await lintGeometry(missing, config)).passed).toBe(false);
  const regression = captures();
  regression[1]!.artifact.elements[10]!.rect.x += 0.51;
  expect((await lintGeometry(regression, config)).passed).toBe(false);
  const substituted = captures();
  for (const item of substituted) {
    const review = item.artifact.elements.find((element) => element.group === "home-review-marks")!;
    review.group = "home-inbox-marks";
  }
  expect((await lintGeometry(substituted, config)).passed).toBe(false);
});

const fleetTest = process.env.CMUX_GALLERY_IN_VM === "1" ? test : test.skip;
fleetTest("declared scroll setup exposes lower rows and rejects ambiguous or missing targets", async () => {
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage();
    await page.setContent('<div class="area" style="height:100px;overflow:auto"><div style="height:300px"></div><button>Review</button></div>');
    await prepareGeometryCapture(page, ".area");
    expect(await page.locator(".area").evaluate((element) => element.scrollTop)).toBeGreaterThan(0);
    const row = await page.locator("button").boundingBox();
    const area = await page.locator(".area").boundingBox();
    expect(row!.y + row!.height).toBeLessThanOrEqual(area!.y + area!.height);
    await expect(prepareGeometryCapture(page, ".missing")).rejects.toThrow("must resolve once");
    await page.locator(".area").evaluate((element) => (element as HTMLElement).style.overflow = "visible");
    await expect(prepareGeometryCapture(page, ".area")).rejects.toThrow("not scrollable");
    await page.locator("body").evaluate((element) => element.insertAdjacentHTML("beforeend", '<div class="area"></div>'));
    await expect(prepareGeometryCapture(page, ".area")).rejects.toThrow("must resolve once");
  } finally { await browser.close(); }
});
