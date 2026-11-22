// The curator overrides as database rows (catalog_overrides) and back.
//
// A `harness` row holds one HarnessOverride without its `models`, plus its
// list `position`; a `model` row holds one ModelOverride for (harness, model).
// overrides.ts is the seed: the first migration inserts `seedRows()`, and the
// bundled catalog copies are built from it.

import { HARNESS_OVERRIDES, type HarnessOverride, type ModelOverride } from "./overrides";

export type OverrideKind = "harness" | "model";

export interface OverrideRow {
  kind: OverrideKind;
  harnessId: string;
  modelId: string | null;
  value: Record<string, unknown>;
  active: boolean;
}

export class OverrideValueError extends Error {}

const SLUG = /^[a-z0-9][a-z0-9-]{0,63}$/;
const MODEL_ID = /^[A-Za-z0-9][A-Za-z0-9._:/@[\]+-]{0,199}$/;
const EFFORTS = ["none", "minimal", "low", "medium", "high", "xhigh", "max"];
const HARNESS_KEYS = [
  "id", "name", "brand", "families", "modelSource", "docsUrl", "sources", "defaultModel", "defaultEffort",
  "dropEfforts", "shortNamePrefix", "familyNames", "groupByProvider", "familyAliases", "position",
];
const SOURCE_KEYS = ["provider", "include", "exclude", "minReleaseDate"];
const MODEL_KEYS = ["name", "shortName", "family", "provider", "efforts", "defaultEffort", "fast", "aliases", "status", "hidden"];

function fail(path: string, message: string): never {
  throw new OverrideValueError(`${path} ${message}`);
}

function object(value: unknown, path: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) fail(path, "must be an object");
  return value as Record<string, unknown>;
}

function keys(value: Record<string, unknown>, allowed: readonly string[], path: string): void {
  for (const key of Object.keys(value)) if (!allowed.includes(key)) fail(`${path}.${key}`, "is not a known field");
}

function string(value: unknown, path: string, max = 200): string {
  if (typeof value !== "string" || !value.trim() || value.length > max) fail(path, `must be a nonempty string of at most ${max} characters`);
  return value;
}

function strings(value: unknown, path: string, item: (v: unknown, p: string) => unknown = string): void {
  if (!Array.isArray(value)) fail(path, "must be an array");
  value.forEach((entry, index) => item(entry, `${path}[${index}]`));
}

function stringMap(value: unknown, path: string): void {
  for (const [key, entry] of Object.entries(object(value, path))) string(entry, `${path}.${key}`);
}

function optionalBool(value: unknown, path: string): void {
  if (value !== undefined && typeof value !== "boolean") fail(path, "must be a boolean");
}

function effort(value: unknown, path: string): void {
  if (!EFFORTS.includes(value as string)) fail(path, `must be one of ${EFFORTS.join(", ")}`);
}

function checkSources(value: unknown, path: string): void {
  if (!Array.isArray(value)) fail(path, "must be an array");
  value.forEach((raw, index) => {
    const source = object(raw, `${path}[${index}]`);
    keys(source, SOURCE_KEYS, `${path}[${index}]`);
    if (!SLUG.test(string(source.provider, `${path}[${index}].provider`))) fail(`${path}[${index}].provider`, "is malformed");
    if (source.include !== undefined) strings(source.include, `${path}[${index}].include`);
    if (source.exclude !== undefined) strings(source.exclude, `${path}[${index}].exclude`);
    if (source.minReleaseDate !== undefined) string(source.minReleaseDate, `${path}[${index}].minReleaseDate`, 10);
  });
}

/** Checks a `harness` row value. Throws OverrideValueError. */
export function checkHarnessValue(harnessId: string, raw: unknown): void {
  const value = object(raw, "value");
  keys(value, HARNESS_KEYS, "value");
  if (value.id !== harnessId || !SLUG.test(harnessId)) fail("value.id", "must equal the row's harness id");
  string(value.name, "value.name");
  if (!SLUG.test(string(value.brand, "value.brand"))) fail("value.brand", "is malformed");
  strings(value.families, "value.families", (v, p) => SLUG.test(string(v, p)) || fail(p, "is malformed"));
  if (value.modelSource !== "catalog" && value.modelSource !== "probe") fail("value.modelSource", "must be catalog or probe");
  if (!Number.isInteger(value.position)) fail("value.position", "must be an integer");
  if (value.docsUrl !== undefined) string(value.docsUrl, "value.docsUrl", 500);
  if (value.sources !== undefined) checkSources(value.sources, "value.sources");
  if (value.defaultModel !== undefined) string(value.defaultModel, "value.defaultModel");
  if (value.defaultEffort !== undefined) effort(value.defaultEffort, "value.defaultEffort");
  if (value.dropEfforts !== undefined) strings(value.dropEfforts, "value.dropEfforts", effort);
  if (value.shortNamePrefix !== undefined) string(value.shortNamePrefix, "value.shortNamePrefix");
  if (value.familyNames !== undefined) stringMap(value.familyNames, "value.familyNames");
  if (value.familyAliases !== undefined) stringMap(value.familyAliases, "value.familyAliases");
  optionalBool(value.groupByProvider, "value.groupByProvider");
}

/** Checks a `model` row value. Throws OverrideValueError. */
export function checkModelValue(modelId: string, raw: unknown): void {
  const value = object(raw, "value");
  keys(value, MODEL_KEYS, "value");
  if (!MODEL_ID.test(modelId)) fail("modelId", "is malformed");
  for (const key of ["name", "shortName", "family", "provider"]) if (value[key] !== undefined) string(value[key], `value.${key}`);
  if (value.efforts !== undefined) strings(value.efforts, "value.efforts", effort);
  if (value.defaultEffort !== undefined) effort(value.defaultEffort, "value.defaultEffort");
  if (value.aliases !== undefined) strings(value.aliases, "value.aliases");
  if (value.status !== undefined && value.status !== "preview" && value.status !== "deprecated") fail("value.status", "must be preview or deprecated");
  optionalBool(value.fast, "value.fast");
  optionalBool(value.hidden, "value.hidden");
}

export function checkRow(row: Pick<OverrideRow, "kind" | "harnessId" | "modelId" | "value">): void {
  if (row.kind === "harness") {
    if (row.modelId !== null) fail("modelId", "must be null for a harness row");
    checkHarnessValue(row.harnessId, row.value);
  } else if (row.kind === "model") {
    if (!row.modelId) fail("modelId", "is required for a model row");
    checkModelValue(row.modelId, row.value);
  } else {
    fail("kind", "must be harness or model");
  }
}

/** Active rows -> the HarnessOverride list projectCatalog reads, in `position` order. */
export function overridesFromRows(rows: readonly OverrideRow[]): HarnessOverride[] {
  const active = rows.filter((row) => row.active);
  const harnesses = active
    .filter((row) => row.kind === "harness")
    .map((row) => row.value as unknown as HarnessOverride & { position: number })
    .sort((a, b) => a.position - b.position || a.id.localeCompare(b.id));
  return harnesses.map((entry) => {
    const harness: HarnessOverride & { position?: number } = { ...entry };
    delete harness.position;
    const models: Record<string, ModelOverride> = {};
    for (const row of active) {
      if (row.kind === "model" && row.harnessId === harness.id && row.modelId) models[row.modelId] = row.value as ModelOverride;
    }
    return Object.keys(models).length > 0 ? { ...harness, models } : { ...harness };
  });
}

/** overrides.ts as rows: the first migration's seed. */
export function seedRows(overrides: readonly HarnessOverride[] = HARNESS_OVERRIDES): OverrideRow[] {
  return overrides.flatMap(({ models, ...harness }, position) => [
    { kind: "harness" as const, harnessId: harness.id, modelId: null, value: { ...harness, position }, active: true },
    ...Object.entries(models ?? {}).map(([modelId, value]) => ({
      kind: "model" as const,
      harnessId: harness.id,
      modelId,
      value: value as Record<string, unknown>,
      active: true,
    })),
  ]);
}
