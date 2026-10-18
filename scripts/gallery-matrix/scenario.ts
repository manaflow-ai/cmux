import { createHash } from "node:crypto";

export type ScenarioCase = {
  id: string;
  path_or_url?: string;
  params?: Record<string, unknown>;
};

function stable(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === "object")
    return Object.fromEntries(Object.entries(value as Record<string, unknown>).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => [key, stable(item)]));
  return value;
}

/** Hashes scenario identity independent of manifest order or object key insertion order. */
export function scenarioFingerprint(cases: readonly ScenarioCase[]): string {
  const input = JSON.stringify(
    [...cases]
      .sort((a, b) => a.id.localeCompare(b.id))
      .map((item) => ({ id: item.id, path_or_url: item.path_or_url, params: stable(item.params ?? {}) })),
  );
  return createHash("sha256").update(input).digest("hex");
}
