import type { Page } from "playwright";
import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { GeometryArtifact, GeometryElement } from "./geometry";

/** Selectors assign meaning in the audit config, never in runtime UI. */
export type GeometrySelection = { group: string; selector: string; secondary?: boolean };
export async function collectGeometry(page: Page, selections: GeometrySelection[], identity: Omit<GeometryArtifact, "elements">, outputDir: string): Promise<string> {
  const evidence = await page.evaluate((selectors) => {
    const elements: GeometryElement[] = [];
    for (const { group, selector, secondary } of selectors) {
      for (const [index, element] of Array.from(document.querySelectorAll(selector)).entries()) {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        if (rect.width <= 0 || rect.height <= 0 || style.display === "none" || style.visibility === "hidden") continue;
        const numeric = (value: string) => Number.isFinite(Number.parseFloat(value)) ? Number.parseFloat(value) : undefined;
        elements.push({ id: `${group}:${index}`, kind: "web", source: "dom-rect", group, secondary, rect: { x: rect.x + scrollX, y: rect.y + scrollY, width: rect.width, height: rect.height }, style: { fontSize: numeric(style.fontSize), fontWeight: style.fontWeight, color: style.color, backgroundColor: style.backgroundColor, borderRadius: numeric(style.borderTopLeftRadius), gap: numeric(style.gap), opacity: numeric(style.opacity) } });
      }
    }
    return { elements, deviceScaleFactor: window.devicePixelRatio, viewport: { width: Math.max(document.documentElement.scrollWidth, innerWidth), height: Math.max(document.documentElement.scrollHeight, innerHeight) } };
  }, selections);
  const screenshotSha256 = createHash("sha256").update(await readFile(join(outputDir, identity.capture.screenshot))).digest("hex");
  const artifact: GeometryArtifact = { ...identity, capture: { ...identity.capture, deviceScaleFactor: evidence.deviceScaleFactor, viewport: evidence.viewport, screenshotSha256, coordinateSpace: "css-px" }, elements: evidence.elements };
  const filename = identity.capture.screenshot.replace(/\.png$/, ".geometry.json");
  await writeFile(join(outputDir, filename), `${JSON.stringify(artifact, null, 2)}\n`);
  return filename;
}
