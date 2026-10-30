import type { Page } from "playwright";
import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { GeometryArtifact, GeometryElement } from "./geometry";

/** Selectors assign meaning in the audit config, never in runtime UI. */
export type GeometrySelection = { group: string; selector: string; secondary?: boolean; containerSelector?: string; containerGroup?: string; part?: string; measurement?: "element" | "text-range" };
export async function collectGeometry(page: Page, selections: GeometrySelection[], identity: Omit<GeometryArtifact, "elements">, outputDir: string): Promise<string> {
  const containerGroups = new Set(selections.map((selection) => selection.containerGroup).filter(Boolean));
  if (selections.some((selection) => containerGroups.has(selection.group))) throw new Error("geometry container and child groups must be distinct");
  const evidence = await page.evaluate((selectors) => {
    const elements: GeometryElement[] = [];
    const groupCounts = new Map<string, number>();
    const containers = new Map<string, Map<Element, string>>();
    const visible = (element: Element) => element.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
    const rectOf = (element: Element, measurement: "element" | "text-range" = "element") => {
      const range = document.createRange();
      range.selectNodeContents(element);
      const rect = measurement === "text-range" ? range.getBoundingClientRect() : element.getBoundingClientRect();
      return { x: rect.x + scrollX, y: rect.y + scrollY, width: rect.width, height: rect.height };
    };
    for (const selection of selectors) {
      const { containerSelector, containerGroup } = selection;
      if (Boolean(containerSelector) !== Boolean(containerGroup)) throw new Error("containerSelector and containerGroup must be paired");
      if (!containerSelector || !containerGroup) continue;
      let captured = containers.get(containerGroup);
      if (!captured) { captured = new Map(); containers.set(containerGroup, captured); }
      for (const element of document.querySelectorAll(containerSelector)) {
        if (!visible(element) || captured.has(element)) continue;
        const id = `${containerGroup}:${captured.size}`;
        captured.set(element, id);
        elements.push({ id, kind: "web", source: "dom-rect", group: containerGroup, rect: rectOf(element) });
      }
    }
    for (const { group, selector, secondary, containerSelector, containerGroup, part, measurement = "element" } of selectors) {
      for (const element of document.querySelectorAll(selector)) {
        const rect = rectOf(element, measurement);
        const style = getComputedStyle(element);
        if (rect.width <= 0 || rect.height <= 0 || !visible(element)) continue;
        const index = groupCounts.get(group) ?? 0;
        groupCounts.set(group, index + 1);
        const parent = containerSelector ? element.closest(containerSelector) : null;
        const containerId = parent && containerGroup ? containers.get(containerGroup)?.get(parent) : undefined;
        const numeric = (value: string) => Number.isFinite(Number.parseFloat(value)) ? Number.parseFloat(value) : undefined;
        elements.push({ id: `${group}:${index}`, kind: "web", source: "dom-rect", group, secondary, containerId, part, rectSource: measurement, rect, style: { fontSize: numeric(style.fontSize), fontWeight: numeric(style.fontWeight), color: style.color, backgroundColor: style.backgroundColor, borderRadius: numeric(style.borderTopLeftRadius), gap: numeric(style.gap), opacity: numeric(style.opacity) } });
      }
    }
    return { elements, deviceScaleFactor: window.devicePixelRatio, viewport: { width: Math.max(document.documentElement.scrollWidth, innerWidth), height: Math.max(document.documentElement.scrollHeight, innerHeight) } };
  }, selections);
  const nextByGroup = new Map<string, number>();
  const elements = evidence.elements.map((element) => {
    const index = nextByGroup.get(element.group) ?? 0;
    nextByGroup.set(element.group, index + 1);
    return { ...element, id: `${element.group}:${index}` };
  });
  const screenshotSha256 = createHash("sha256").update(await readFile(join(outputDir, identity.capture.screenshot))).digest("hex");
  const artifact: GeometryArtifact = { ...identity, capture: { ...identity.capture, deviceScaleFactor: evidence.deviceScaleFactor, viewport: evidence.viewport, screenshotSha256, coordinateSpace: "css-px" }, elements };
  const filename = identity.capture.screenshot.replace(/\.png$/, ".geometry.json");
  await writeFile(join(outputDir, filename), `${JSON.stringify(artifact, null, 2)}\n`);
  return filename;
}
