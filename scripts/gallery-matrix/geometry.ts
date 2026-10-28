import { mkdir, readFile, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { PNG } from "pngjs";
import { createHash } from "node:crypto";

export const GEOMETRY_SCHEMA_VERSION = 1 as const;

export type Rect = { x: number; y: number; width: number; height: number };
export type GeometrySource = "dom-rect" | "ax-frame" | "view-frame";
export type GeometryKind = "web" | "native";

export type GeometryStyle = {
  fontSize?: number;
  fontWeight?: number | string;
  lineHeight?: number | string;
  /** Measured text baseline in the same coordinate space as rect.y. */
  baseline?: number;
  color?: string;
  backgroundColor?: string;
  padding?: [number, number, number, number];
  gap?: number;
  borderRadius?: number;
  opacity?: number;
};

export type GeometryElement = {
  id: string;
  kind: GeometryKind;
  source: GeometrySource;
  role?: string;
  label?: string;
  group?: string;
  rect: Rect;
  style?: GeometryStyle;
  control?: boolean;
  secondary?: boolean;
  /** For hover-control-only checks, this is the measured highlight bounds. */
  hoverRect?: Rect;
  /** True when the capture explicitly exercised the control's opened menu. */
  menuOpen?: boolean;
};

export type GeometryCapture = {
  caseId: string;
  engine: string;
  theme: string;
  viewport: { width: number; height: number };
  deviceScaleFactor: number;
  screenshot: string;
  screenshotSha256: string;
  coordinateSpace?: "css-px" | "screenshot-pixels";
};

export type GeometryArtifact = {
  schemaVersion: typeof GEOMETRY_SCHEMA_VERSION;
  revision: { sha: string; source: string };
  capture: GeometryCapture;
  elements: GeometryElement[];
};

type CommonRule = { id: string; group: string; tolerancePx: number; minCount?: number; source?: GeometrySource; appliesTo?: string[] };
export type GeometryRule =
  | (CommonRule & { kind: "peer-alignment"; axis: "x" | "y"; measure: "start" | "center" | "end" })
  | (CommonRule & { kind: "peer-size"; dimension: "width" | "height" })
  | (CommonRule & { kind: "spacing"; axis: "x" | "y"; tokensPx: number[] })
  | (CommonRule & { kind: "inset"; containerGroup: string; edge: "left" | "top" | "right" | "bottom"; tokensPx: number[] })
  | (CommonRule & { kind: "style-token"; property: "borderRadius" | "gap"; tokensPx: number[] })
  | (CommonRule & { kind: "text-baseline" })
  | (CommonRule & { kind: "secondary-text"; colors: string[]; weights: Array<number | string> })
  | (CommonRule & { kind: "hover-control-only"; requireMenuOpen?: boolean })
  | (CommonRule & { kind: "required-source"; requiredSource: GeometrySource });

export type AcceptedFinding = { maxDeltaPx: number; reason: string };
export type GeometryConfig = {
  schemaVersion: typeof GEOMETRY_SCHEMA_VERSION;
  revision: { sha: string; source: string };
  required: Array<{ caseId: string; engine: string; theme: string }>;
  rules: GeometryRule[];
  /** Existing debt is explicit and bounded. New findings always fail. */
  acceptedFindings?: Record<string, AcceptedFinding>;
};

export type GeometryFinding = {
  id: string;
  rule: string;
  caseId: string;
  theme: string;
  engine: string;
  elementIds: string[];
  observedPx?: number;
  expectedPx?: number;
  deltaPx?: number;
  message: string;
  screenshot: string;
  crop?: string;
  accepted?: boolean;
};

export type GeometryReport = {
  schemaVersion: typeof GEOMETRY_SCHEMA_VERSION;
  revision: GeometryConfig["revision"];
  artifacts: number;
  findings: GeometryFinding[];
  errors: string[];
  passed: boolean;
};

const finite = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);
const rectValid = (rect: unknown): rect is Rect => {
  if (!rect || typeof rect !== "object") return false;
  const candidate = rect as Record<string, unknown>;
  return ["x", "y", "width", "height"].every((key) => finite(candidate[key]) && (key === "width" || key === "height" || Math.abs(candidate[key] as number) < 1e9)) && (candidate.width as number) >= 0 && (candidate.height as number) >= 0;
};

export function parseArtifact(value: unknown, file = "artifact"): GeometryArtifact {
  if (!value || typeof value !== "object") throw new Error(`${file}: artifact must be an object`);
  const item = value as Record<string, unknown>;
  if (item.schemaVersion !== GEOMETRY_SCHEMA_VERSION) throw new Error(`${file}: unsupported schemaVersion`);
  const revision = item.revision as Record<string, unknown> | undefined;
  if (!revision || typeof revision.sha !== "string" || !/^[0-9a-f]{7,64}$/i.test(revision.sha) || typeof revision.source !== "string" || !revision.source) throw new Error(`${file}: revision.sha/source are required`);
  const capture = item.capture as Record<string, unknown> | undefined;
  if (!capture || typeof capture.caseId !== "string" || typeof capture.engine !== "string" || typeof capture.theme !== "string" || typeof capture.screenshot !== "string") throw new Error(`${file}: capture provenance is required`);
  if (!capture.caseId || !capture.engine || !capture.theme || !capture.screenshot || typeof capture.screenshotSha256 !== "string" || !/^[0-9a-f]{64}$/.test(capture.screenshotSha256)) throw new Error(`${file}: non-empty capture identity and screenshotSha256 are required`);
  if (!["css-px", "screenshot-pixels"].includes(String(capture.coordinateSpace))) throw new Error(`${file}: coordinateSpace is required`);
  const viewport = capture.viewport as Record<string, unknown> | undefined;
  if (!viewport || !finite(viewport.width) || viewport.width <= 0 || !finite(viewport.height) || viewport.height <= 0 || !finite(capture.deviceScaleFactor) || (capture.deviceScaleFactor as number) <= 0) throw new Error(`${file}: positive viewport/deviceScaleFactor are required`);
  if (!Array.isArray(item.elements) || item.elements.length === 0) throw new Error(`${file}: elements evidence is required`);
  const ids = new Set<string>();
  const elements = item.elements.map((raw, index) => {
    if (!raw || typeof raw !== "object") throw new Error(`${file}: element ${index} must be an object`);
    const element = raw as Record<string, unknown>;
    if (typeof element.id !== "string" || !element.id || ids.has(element.id) || (element.kind !== "web" && element.kind !== "native") || !["dom-rect", "ax-frame", "view-frame"].includes(String(element.source)) || !rectValid(element.rect)) throw new Error(`${file}: element ${index} has invalid or duplicate id/kind/source/rect`);
    ids.add(element.id);
    if (element.kind === "web" && element.source !== "dom-rect") throw new Error(`${file}: web element ${element.id} must use dom-rect source`);
    const style = element.style;
    if (style !== undefined && (!style || typeof style !== "object")) throw new Error(`${file}: element ${element.id} style must be an object`);
    if (element.hoverRect !== undefined && !rectValid(element.hoverRect)) throw new Error(`${file}: element ${element.id} hoverRect is invalid`);
    return element as unknown as GeometryElement;
  });
  return { schemaVersion: GEOMETRY_SCHEMA_VERSION, revision: revision as GeometryArtifact["revision"], capture: { ...capture, viewport } as unknown as GeometryCapture, elements };
}

export function parseConfig(value: unknown, file = "geometry config"): GeometryConfig {
  if (!value || typeof value !== "object") throw new Error(`${file}: config must be an object`);
  const item = value as Record<string, unknown>;
  if (item.schemaVersion !== GEOMETRY_SCHEMA_VERSION) throw new Error(`${file}: unsupported schemaVersion`);
  const revision = item.revision as Record<string, unknown> | undefined;
  if (!revision || typeof revision.sha !== "string" || typeof revision.source !== "string") throw new Error(`${file}: revision is required`);
  const required = item.required as Array<Record<string, unknown>> | undefined;
  if (!Array.isArray(required) || !required.length || required.some((entry) => !entry || !["caseId", "engine", "theme"].every((key) => typeof entry[key] === "string" && entry[key]))) throw new Error(`${file}: required capture tuples are required`);
  if (!Array.isArray(item.rules) || item.rules.length === 0) throw new Error(`${file}: at least one rule is required`);
  const rules = item.rules as GeometryRule[];
  const ids = new Set<string>();
  for (const rule of rules) {
    if (!rule || typeof rule.id !== "string" || ids.has(rule.id) || typeof rule.group !== "string" || !finite(rule.tolerancePx) || rule.tolerancePx < 0 || (rule.minCount !== undefined && (!Number.isInteger(rule.minCount) || rule.minCount < 1))) throw new Error(`${file}: every rule needs a unique id/group/tolerancePx`);
    ids.add(rule.id);
    if (rule.appliesTo !== undefined && (!Array.isArray(rule.appliesTo) || rule.appliesTo.length === 0 || rule.appliesTo.some((value) => typeof value !== "string" || !value))) throw new Error(`${file}: invalid appliesTo`);
    if (rule.source !== undefined && !["dom-rect", "ax-frame", "view-frame"].includes(rule.source)) throw new Error(`${file}: invalid source`);
    if ((rule.kind === "peer-alignment" || rule.kind === "spacing") && !["x", "y"].includes(rule.axis)) throw new Error(`${file}: invalid axis`);
    if (rule.kind === "peer-alignment" && !["start", "center", "end"].includes(rule.measure)) throw new Error(`${file}: invalid measure`);
    if (rule.kind === "peer-size" && !["width", "height"].includes(rule.dimension)) throw new Error(`${file}: invalid dimension`);
    if (rule.kind === "inset" && (!["left", "top", "right", "bottom"].includes(rule.edge) || !rule.containerGroup)) throw new Error(`${file}: invalid inset`);
    if (rule.kind === "style-token" && !["borderRadius", "gap"].includes(rule.property)) throw new Error(`${file}: invalid property`);
    if (!["peer-alignment", "peer-size", "spacing", "inset", "style-token", "text-baseline", "secondary-text", "hover-control-only", "required-source"].includes(rule.kind)) throw new Error(`${file}: unknown rule kind ${String((rule as { kind?: unknown }).kind)}`);
    if ((rule.kind === "spacing" || rule.kind === "inset" || rule.kind === "style-token") && (!Array.isArray(rule.tokensPx) || rule.tokensPx.length === 0 || rule.tokensPx.some((token) => !finite(token) || token <= 0))) throw new Error(`${file}: ${rule.kind} rule ${rule.id} needs positive tokensPx`);
    if (rule.kind === "secondary-text" && (!Array.isArray(rule.colors) || rule.colors.length === 0 || !Array.isArray(rule.weights) || rule.weights.length === 0)) throw new Error(`${file}: secondary-text rule ${rule.id} needs colors and weights`);
    if (rule.kind === "required-source" && !["dom-rect", "ax-frame", "view-frame"].includes(rule.requiredSource)) throw new Error(`${file}: required-source rule ${rule.id} has invalid source`);
  }
  const accepted = item.acceptedFindings;
  if (accepted !== undefined && (!accepted || typeof accepted !== "object" || Object.values(accepted as object).some((value) => !value || typeof value !== "object" || !finite((value as AcceptedFinding).maxDeltaPx) || typeof (value as AcceptedFinding).reason !== "string"))) throw new Error(`${file}: acceptedFindings entries need maxDeltaPx/reason`);
  return { schemaVersion: GEOMETRY_SCHEMA_VERSION, revision: revision as GeometryConfig["revision"], required: required as GeometryConfig["required"], rules, acceptedFindings: accepted as GeometryConfig["acceptedFindings"] };
}

function measure(rect: Rect, axis: "x" | "y", point: "start" | "center" | "end"): number {
  const origin = axis === "x" ? rect.x : rect.y;
  const size = axis === "x" ? rect.width : rect.height;
  return point === "start" ? origin : point === "center" ? origin + size / 2 : origin + size;
}

function findingId(rule: GeometryRule, artifact: GeometryArtifact, suffix: string): string {
  return `${rule.id}:${artifact.capture.caseId}:${artifact.capture.engine}:${artifact.capture.theme}:${suffix}`;
}

function pushFinding(findings: GeometryFinding[], rule: GeometryRule, artifact: GeometryArtifact, elementIds: string[], message: string, observedPx?: number, expectedPx?: number, deltaPx?: number): void {
  findings.push({ id: findingId(rule, artifact, elementIds.join(",")), rule: rule.id, caseId: artifact.capture.caseId, theme: artifact.capture.theme, engine: artifact.capture.engine, elementIds, observedPx, expectedPx, deltaPx, message, screenshot: artifact.capture.screenshot });
}

function lintRule(findings: GeometryFinding[], rule: GeometryRule, artifact: GeometryArtifact): void {
  if (rule.appliesTo && !rule.appliesTo.includes(artifact.capture.caseId)) return;
  const elements = artifact.elements.filter((element) => element.group === rule.group);
  const minCount = rule.minCount ?? 2;
  if (elements.length < minCount) {
    pushFinding(findings, rule, artifact, elements.map((element) => element.id), `missing evidence for group ${rule.group}: expected at least ${minCount} elements`);
    return;
  }
  if (rule.source && elements.some((element) => element.source !== rule.source)) {
    pushFinding(findings, rule, artifact, elements.map((element) => element.id), `group ${rule.group} must use source ${rule.source}`);
    return;
  }
  if (rule.kind === "required-source") {
    if (elements.some((element) => element.source !== rule.requiredSource)) pushFinding(findings, rule, artifact, elements.map((element) => element.id), `group ${rule.group} must use source ${rule.requiredSource}`);
    return;
  }
  if (rule.kind === "peer-alignment") {
    const values = elements.map((element) => measure(element.rect, rule.axis, rule.measure));
    const span = Math.max(...values) - Math.min(...values);
    if (span > rule.tolerancePx) pushFinding(findings, rule, artifact, elements.map((element) => element.id).sort(), `${rule.axis} ${rule.measure} peer spread exceeds tolerance`, span, 0, span);
  } else if (rule.kind === "peer-size") {
    const values = elements.map((element) => rule.dimension === "width" ? element.rect.width : element.rect.height);
    const span = Math.max(...values) - Math.min(...values);
    if (span > rule.tolerancePx) pushFinding(findings, rule, artifact, elements.map((element) => element.id).sort(), `${rule.dimension} peer spread exceeds tolerance`, span, 0, span);
  } else if (rule.kind === "spacing") {
    const sorted = [...elements].sort((a, b) => (rule.axis === "x" ? a.rect.x - b.rect.x : a.rect.y - b.rect.y));
    for (let index = 1; index < sorted.length; index++) {
      const previous = sorted[index - 1]!.rect;
      const current = sorted[index]!.rect;
      const gap = rule.axis === "x" ? current.x - (previous.x + previous.width) : current.y - (previous.y + previous.height);
      const expected = rule.tokensPx.reduce((best, token) => Math.abs(token - gap) < Math.abs(best - gap) ? token : best, rule.tokensPx[0]!);
      if (Math.abs(gap - expected) > rule.tolerancePx) pushFinding(findings, rule, artifact, [sorted[index - 1]!.id, sorted[index]!.id], `${rule.axis} gap is outside spacing scale`, gap, expected, Math.abs(gap - expected));
    }
  } else if (rule.kind === "inset") {
    const containers = artifact.elements.filter((element) => element.group === rule.containerGroup);
    if (containers.length !== 1) {
      pushFinding(findings, rule, artifact, elements.map((element) => element.id), `inset rule requires one ${rule.containerGroup} container`);
      return;
    }
    const container = containers[0]!.rect;
    for (const element of elements) {
      const inset = rule.edge === "left" ? element.rect.x - container.x : rule.edge === "top" ? element.rect.y - container.y : rule.edge === "right" ? container.x + container.width - element.rect.x - element.rect.width : container.y + container.height - element.rect.y - element.rect.height;
      const expected = rule.tokensPx.reduce((best, token) => Math.abs(token - inset) < Math.abs(best - inset) ? token : best, rule.tokensPx[0]!);
      if (Math.abs(inset - expected) > rule.tolerancePx) pushFinding(findings, rule, artifact, [element.id, containers[0]!.id], `${rule.edge} inset is outside spacing scale`, inset, expected, Math.abs(inset - expected));
    }
  } else if (rule.kind === "style-token") {
    for (const element of elements) {
      const value = rule.property === "borderRadius" ? element.style?.borderRadius : element.style?.gap;
      if (!finite(value)) {
        pushFinding(findings, rule, artifact, [element.id], `${rule.property} evidence is missing`);
        continue;
      }
      const expected = rule.tokensPx.reduce((best, token) => Math.abs(token - value) < Math.abs(best - value) ? token : best, rule.tokensPx[0]!);
      if (Math.abs(value - expected) > rule.tolerancePx) pushFinding(findings, rule, artifact, [element.id], `${rule.property} is outside spacing scale`, value, expected, Math.abs(value - expected));
    }
  } else if (rule.kind === "text-baseline") {
    const baselineElements = elements.filter((element) => finite(element.style?.baseline));
    if (baselineElements.length !== elements.length) {
      pushFinding(findings, rule, artifact, elements.map((element) => element.id), `text baseline evidence is missing; rect bottom is not a baseline`);
      return;
    }
    const values = baselineElements.map((element) => element.style!.baseline!);
    const span = Math.max(...values) - Math.min(...values);
    if (span > rule.tolerancePx) pushFinding(findings, rule, artifact, baselineElements.map((element) => element.id).sort(), `text baseline peer spread exceeds tolerance`, span, 0, span);
  } else if (rule.kind === "secondary-text") {
    for (const element of elements) {
      const color = element.style?.color;
      const weight = element.style?.fontWeight;
      if (!element.secondary) {
        pushFinding(findings, rule, artifact, [element.id], `secondary text marker is missing`);
      } else if (color === undefined || !rule.colors.includes(color) || weight === undefined || !rule.weights.map(String).includes(String(weight))) {
        pushFinding(findings, rule, artifact, [element.id], `secondary text weight/colour is outside the declared palette`);
      }
    }
  } else if (rule.kind === "hover-control-only") {
    for (const element of elements) {
      if (!element.control || !element.hoverRect) {
        pushFinding(findings, rule, artifact, [element.id], `hover control evidence is missing control/hoverRect`);
      } else if (["x", "y", "width", "height"].some((key) => Math.abs(element.hoverRect![key as keyof Rect] - element.rect[key as keyof Rect]) > rule.tolerancePx)) {
        pushFinding(findings, rule, artifact, [element.id], `hover highlight extends beyond its control`);
      } else if (rule.requireMenuOpen && !element.menuOpen) {
        pushFinding(findings, rule, artifact, [element.id], `menu-open state was not captured for hover control`);
      }
    }
  }
}

function resolveScreenshot(artifactFile: string, screenshot: string): string {
  return isAbsolute(screenshot) ? screenshot : resolve(dirname(artifactFile), screenshot);
}

async function writeCrop(artifactFile: string, finding: GeometryFinding, artifact: GeometryArtifact, reportDir: string): Promise<void> {
  const screenshot = resolveScreenshot(artifactFile, artifact.capture.screenshot);
  if (!existsSync(screenshot)) return;
  let png: PNG;
  try {
    png = PNG.sync.read(await readFile(screenshot));
  } catch {
    return;
  }
  const selected = artifact.elements.filter((element) => finding.elementIds.includes(element.id));
  if (!selected.length) return;
  const scale = artifact.capture.coordinateSpace === "screenshot-pixels" ? 1 : artifact.capture.deviceScaleFactor || 1;
  const padding = Math.round(8 * scale);
  const left = Math.max(0, Math.floor(Math.min(...selected.map((element) => element.rect.x)) * scale) - padding);
  const top = Math.max(0, Math.floor(Math.min(...selected.map((element) => element.rect.y)) * scale) - padding);
  const right = Math.min(png.width, Math.ceil(Math.max(...selected.map((element) => element.rect.x + element.rect.width)) * scale) + padding);
  const bottom = Math.min(png.height, Math.ceil(Math.max(...selected.map((element) => element.rect.y + element.rect.height)) * scale) + padding);
  if (right <= left || bottom <= top) return;
  const crop = new PNG({ width: right - left, height: bottom - top });
  PNG.bitblt(png, crop, left, top, right - left, bottom - top, 0, 0);
  const name = createHash("sha256").update(finding.id).digest("hex").slice(0, 24);
  const path = join(reportDir, "crops", `${name}.png`);
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, PNG.sync.write(crop));
  finding.crop = relative(reportDir, path);
}

export async function validateScreenshot(file: string, artifact: GeometryArtifact): Promise<string[]> {
  const errors: string[] = [];
  const screenshot = resolveScreenshot(file, artifact.capture.screenshot);
  try {
    const bytes = await readFile(screenshot);
    if (createHash("sha256").update(bytes).digest("hex") !== artifact.capture.screenshotSha256) errors.push(`${file}: screenshot hash mismatch`);
    const png = PNG.sync.read(bytes);
    const scale = artifact.capture.deviceScaleFactor;
    if (png.width !== Math.round(artifact.capture.viewport.width * scale) || png.height !== Math.round(artifact.capture.viewport.height * scale)) errors.push(`${file}: screenshot dimensions do not match viewport and scale`);
  } catch (error) {
    errors.push(`${file}: screenshot evidence unavailable: ${error instanceof Error ? error.message : String(error)}`);
  }
  return errors;
}

export async function lintGeometry(artifacts: Array<{ file: string; artifact: GeometryArtifact }>, config: GeometryConfig, reportDir?: string): Promise<GeometryReport> {
  const findings: GeometryFinding[] = [];
  const errors: string[] = [];
  if (!artifacts.length) errors.push("no geometry artifacts were supplied");
  const seen = new Set<string>();
  for (const { file, artifact } of artifacts) {
    if (artifact.revision.sha !== artifacts[0]?.artifact.revision.sha) errors.push(`${file}: mixed capture revisions`);
    const key = `${artifact.capture.caseId}:${artifact.capture.engine}:${artifact.capture.theme}`;
    if (seen.has(key)) errors.push(`${file}: duplicate capture ${key}`);
    seen.add(key);
    for (const rule of config.rules) lintRule(findings, rule, artifact);
  }
  for (const capture of config.required) if (!artifacts.some(({ artifact }) => artifact.capture.caseId === capture.caseId && artifact.capture.engine === capture.engine && artifact.capture.theme === capture.theme)) errors.push(`missing required capture: ${capture.caseId}:${capture.engine}:${capture.theme}`);
  for (const finding of findings) {
    const accepted = config.acceptedFindings?.[finding.id];
    if (accepted && finding.deltaPx !== undefined && finding.deltaPx <= accepted.maxDeltaPx) finding.accepted = true;
    if (!finding.accepted && reportDir) {
      const source = artifacts.find(({ artifact }) => `${artifact.capture.caseId}:${artifact.capture.engine}:${artifact.capture.theme}` === `${finding.caseId}:${finding.engine}:${finding.theme}`);
      if (source) await writeCrop(source.file, finding, source.artifact, reportDir);
    }
  }
  return { schemaVersion: GEOMETRY_SCHEMA_VERSION, revision: config.revision, artifacts: artifacts.length, findings, errors, passed: errors.length === 0 && findings.every((finding) => finding.accepted === true) };
}

