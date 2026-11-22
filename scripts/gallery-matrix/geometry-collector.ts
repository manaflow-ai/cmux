import type { Page } from "playwright";
import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { GeometryArtifact, GeometryElement } from "./geometry";

/** Match a declared scrolled fixture before freezing it for screenshot/geometry pairing. */
export async function prepareGeometryCapture(page: Page, scrollSelector?: string): Promise<void> {
  if (scrollSelector) await page.evaluate((selector) => {
    const targets = document.querySelectorAll(selector);
    if (targets.length !== 1) throw new Error(`geometry scroll target must resolve once: ${selector}`);
    const target = targets[0]!;
    const maximum = Math.max(0, target.scrollHeight - target.clientHeight);
    if (maximum > 0 && !["auto", "scroll"].includes(getComputedStyle(target).overflowY)) throw new Error(`geometry scroll target is not scrollable: ${selector}`);
    target.scrollTop = target.scrollHeight;
    if (Math.abs(target.scrollTop - maximum) > 1) throw new Error(`geometry scroll target did not reach its end: ${selector}`);
  }, scrollSelector);
  await page.evaluate(() => document.getAnimations().forEach((animation) => animation.pause()));
}

/** Selectors assign meaning in the audit config, never in runtime UI. */
export type GeometrySelection = { group: string; selector: string; secondary?: boolean; containerSelector?: string; containerGroup?: string; part?: string; measurement?: "element" | "text-range" };
const SELECTION_STRINGS = ["group", "selector", "containerSelector", "containerGroup", "part"] as const;
const MEASUREMENTS = ["element", "text-range"] as const;

/** Selectors arrive as JSON: reject unknown keys and enum values instead of silently measuring something else. */
export function parseSelections(value: unknown, file = "geometry selectors"): GeometrySelection[] {
  if (!Array.isArray(value)) throw new Error(`${file}: selections must be an array`);
  return value.map((entry, index) => {
    const at = `${file}[${index}]`;
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) throw new Error(`${at}: selection must be an object`);
    const item = entry as Record<string, unknown>;
    for (const key of Object.keys(item)) if (![...SELECTION_STRINGS, "secondary", "measurement"].includes(key)) throw new Error(`${at}: unknown selection key ${JSON.stringify(key)}`);
    for (const key of SELECTION_STRINGS) if ((key === "group" || key === "selector" || item[key] !== undefined) && (typeof item[key] !== "string" || !item[key])) throw new Error(`${at}: ${key} must be a non-empty string`);
    if (item.secondary !== undefined && typeof item.secondary !== "boolean") throw new Error(`${at}: secondary must be a boolean`);
    if (item.measurement !== undefined && !(MEASUREMENTS as readonly unknown[]).includes(item.measurement)) throw new Error(`${at}: measurement must be one of ${MEASUREMENTS.join(", ")}`);
    if ((item.containerSelector === undefined) !== (item.containerGroup === undefined)) throw new Error(`${at}: containerSelector and containerGroup must be paired`);
    return item as GeometrySelection;
  });
}

/** Parse the per-case selector map written by the audit and read by the runner. */
export function parseSelectorMap(value: unknown, file = "geometry selectors"): Record<string, GeometrySelection[]> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${file}: selectors must map case IDs to selections`);
  return Object.fromEntries(Object.entries(value).map(([caseId, selections]) => [caseId, parseSelections(selections, `${file}.${caseId}`)]));
}

export async function collectGeometry(page: Page, selectionsInput: GeometrySelection[], identity: Omit<GeometryArtifact, "elements">, outputDir: string): Promise<string> {
  const selections = parseSelections(selectionsInput);
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
