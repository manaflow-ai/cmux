// l10n-allow-file: a probe's report words, never shown in the app.
// RFD 0132's confirm count for cmuxterm-hq's `cloud-ergonomics-linux` probe: "confirms that guard nothing
// irreversible: 0". The Cloud page's confirmations are declared in Swift (PageDescriptor.cloud in
// Packages/macOS/CmuxNext/Sources/CmuxNextPages/PageDescriptor.swift): `confirmedOps` (every sheet),
// `clickRunsOps` (those a person's own click runs with no sheet) and `confirmGuards` (why each other sheet
// stays: irreversible, spends or exposes). A confirm a person's click still meets with no guard counts.
// This reads the declaration as text, as the Swift initializer reads it: click-run ops count only when
// confirmed, and a guard counts only on a confirmed op the click does not run.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const GUARDS = ["irreversible", "spends", "exposes"] as const;
export type ConfirmGuard = (typeof GUARDS)[number];

export type ConfirmReading = { op: string; guard: ConfirmGuard | null };

export type CloudConfirmsReport = {
  /// Sheets a person's click on the Cloud page still meets.
  confirms_total: number;
  /// Of those, the ones with no irreversible, spends or exposes guard (the goal is 0).
  confirms_guarding_nothing: number;
  /// Confirmed ops a person's click runs with no sheet (an agent's call still gets it).
  confirms_click_runs: number;
  confirms: ConfirmReading[];
};

export const PAGE_DESCRIPTOR_SWIFT = fileURLToPath(
  new URL("../../../../../Packages/macOS/CmuxNext/Sources/CmuxNextPages/PageDescriptor.swift", import.meta.url),
);

/// The text of `static let cloud = PageDescriptor(...)`, line comments dropped, or null when it is not there.
function cloudDeclaration(swift: string): string | null {
  const start = swift.search(/static\s+let\s+cloud\s*=\s*PageDescriptor\(/);
  if (start < 0) return null;
  const body = swift.slice(start).replace(/\/\/[^\n]*/g, "");
  let depth = 0;
  for (let i = body.indexOf("("); i < body.length; i++) {
    if (body[i] === "(") depth++;
    else if (body[i] === ")" && --depth === 0) return body.slice(0, i + 1);
  }
  return null;
}

/// The literal after `label:` (`[...]`), or null when the call has no such argument.
function literal(call: string, label: string): string | null {
  const match = new RegExp(`\\b${label}\\s*:\\s*\\[([^\\]]*)\\]`).exec(call);
  return match ? match[1] : null;
}

/// The Cloud page's confirm count from PageDescriptor.swift's text; null when the declaration or its
/// `confirmedOps` cannot be read (the probe then reports the inventory missing instead of a quiet zero).
export function readCloudConfirms(swift: string): CloudConfirmsReport | null {
  const call = cloudDeclaration(swift);
  if (!call) return null;
  const confirmed = literal(call, "confirmedOps");
  if (!confirmed) return null;
  const ops = [...confirmed.matchAll(/"([^"]+)"\s*:\s*\.\w+/g)].map((m) => m[1]);
  if (!ops.length) return null;
  const clickRuns = new Set(
    [...(literal(call, "clickRunsOps") ?? "").matchAll(/"([^"]+)"/g)].map((m) => m[1]).filter((op) => ops.includes(op)),
  );
  const guards = new Map<string, ConfirmGuard>();
  for (const m of (literal(call, "confirmGuards") ?? "").matchAll(/"([^"]+)"\s*:\s*\.(\w+)/g)) {
    if ((GUARDS as readonly string[]).includes(m[2])) guards.set(m[1], m[2] as ConfirmGuard);
  }
  const confirms = ops.filter((op) => !clickRuns.has(op)).map((op) => ({ op, guard: guards.get(op) ?? null }));
  return {
    confirms_total: confirms.length,
    confirms_guarding_nothing: confirms.filter((c) => c.guard === null).length,
    confirms_click_runs: clickRuns.size,
    confirms,
  };
}

/// The count from the checkout's own PageDescriptor.swift (null when unreadable).
export function measureCloudConfirms(path = PAGE_DESCRIPTOR_SWIFT): CloudConfirmsReport | null {
  try {
    return readCloudConfirms(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}
