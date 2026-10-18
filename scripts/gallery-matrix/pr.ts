#!/usr/bin/env bun
// The per-PR gallery diff from three matrix runs (runner.ts output folders): the merge-base, the
// head and the head again. Writes the diff folder: index.html, outcomes.json, summary.json (the
// feed card), comment.md (the sticky PR comment) and the images they show.
//
//   bun pr.ts --base base-run --head head-run --repeat head-run-2 \
//     --base-manifest base.json --head-manifest head.json --out diff \
//     --pr 18189 --head-sha <sha> --base-sha <sha> [--diff-url U] [--gallery-url U] [--matrix-url U] [--feed-url U]
//     [--artifact-url U] [--thumb-base U] [--branch B (the live preview /wt/<name>/ in the comment)]
//
// With --outcomes (an earlier run's outcomes.json) it only writes the reports, so a publisher can
// rebuild the comment from data without running the comparison or the PR's code.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { compareRuns, type Outcome } from "./compare";
import { commentMarkdown, commentThumbs, diffPage, feedSummary, liveBase, type ReportMeta } from "./report";

type MatrixResult = {
  id?: string;
  engine?: string;
  params?: Record<string, unknown>;
  revision?: { sha?: string; source?: string };
};

type ManifestCase = { id: string; path_or_url?: string; params?: Record<string, unknown> };
type CaptureReceipt = {
  schemaVersion?: number;
  captureId?: string;
  capturedAt?: string;
  scenario?: { count?: number; fingerprint?: string };
  results?: { count?: number; expected?: number; status?: string };
  quality?: string;
  revisions?: { shas?: string[]; sources?: string[] };
};

const canonical = (value: unknown): string => {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object")
    return `{${Object.entries(value as Record<string, unknown>)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([key, item]) => `${JSON.stringify(key)}:${canonical(item)}`)
      .join(",")}}`;
  return JSON.stringify(value) ?? "null";
};

const manifestCases = (file: string | undefined): Map<string, string> => {
  if (!file || !existsSync(file)) return new Map();
  const cases = JSON.parse(readFileSync(file, "utf8")) as ManifestCase[];
  return new Map(cases.map((item) => [item.id, canonical(item.params ?? {})]));
};

const caseIds = (file: string | undefined) => new Set(manifestCases(file).keys());

const matrixResults = (dir: string): MatrixResult[] => {
  const file = join(dir, "results.json");
  if (!existsSync(file)) throw new Error(`${dir} matrix has no results.json`);
  return JSON.parse(readFileSync(file, "utf8")) as MatrixResult[];
};

const readReceipt = (dir: string): CaptureReceipt | undefined => {
  const file = join(dir, "receipt.json");
  if (!existsSync(file)) return undefined;
  return JSON.parse(readFileSync(file, "utf8")) as CaptureReceipt;
};

const receiptFingerprint = (manifest: string): string => {
  const cases = JSON.parse(readFileSync(manifest, "utf8")) as ManifestCase[];
  return createHash("sha256")
    .update(JSON.stringify(cases.map((item) => ({ id: item.id, path_or_url: item.path_or_url, params: item.params ?? {} }))))
    .digest("hex");
};

type EvidenceReceipt = { captureId: string; capturedAt?: string; scenarioFingerprint: string; quality?: string; status?: string };
const evidenceReceipt = (dir: string, label: string, manifest?: string): EvidenceReceipt | undefined => {
  const receipt = readReceipt(dir);
  if (!receipt?.captureId || !receipt.scenario?.fingerprint) return undefined;
  const manifestCount = manifest ? (JSON.parse(readFileSync(manifest, "utf8")) as ManifestCase[]).length : 0;
  // PR workflows render a union manifest (head plus base-only cases), while the report receives
  // each side's narrower manifest. Verify the narrower case params below; compare fingerprints
  // only when the receipt and supplied manifest describe the same complete set.
  if (manifest && receipt.scenario.count === manifestCount && receipt.scenario.fingerprint !== receiptFingerprint(manifest))
    throw new Error(`${label} receipt scenario fingerprint mismatch`);
  return {
    captureId: receipt.captureId,
    capturedAt: receipt.capturedAt,
    scenarioFingerprint: receipt.scenario.fingerprint,
    quality: receipt.quality,
    status: receipt.results?.status,
  };
};

export function comparisonReceipt(
  base: EvidenceReceipt | undefined,
  head: EvidenceReceipt | undefined,
  repeat: EvidenceReceipt | undefined,
  heads: { base: string; head: string },
) {
  const fingerprints = [base?.scenarioFingerprint, head?.scenarioFingerprint, repeat?.scenarioFingerprint].filter(Boolean);
  if (new Set(fingerprints).size > 1) throw new Error("comparison receipt scenario fingerprint mismatch");
  const input = [base?.captureId, head?.captureId, repeat?.captureId, heads.base, heads.head].join("|");
  return {
    schemaVersion: 1,
    comparisonId: createHash("sha256").update(input).digest("hex").slice(0, 16),
    createdAt: new Date().toISOString(),
    freshness: { status: head ? "unverified" : "missing", reason: "current means live PR-head verification, which this receipt does not perform" },
    candidate: head ? { ...head, role: "candidate", sha: heads.head } : undefined,
    baseline: base ? { ...base, role: "baseline", sha: heads.base } : undefined,
    repeat: repeat ? { ...repeat, role: "determinism-check", sha: heads.head } : undefined,
  };
}

/** Refuses to compare a matrix directory captured from a different checkout. */
export function assertRunRevision(dir: string, expected: string, label: string, manifest?: string): void {
  if (!expected) return;
  const results = matrixResults(dir);
  const mismatches = results.filter(
    (result) => result.revision?.sha !== expected || typeof result.revision.source !== "string" || !result.revision.source,
  );
  if (!results.length || mismatches.length)
    throw new Error(
      `${label} matrix provenance mismatch: expected ${expected}; got ${mismatches
        .slice(0, 5)
        .map((result) => `${result.id ?? "unknown"}:${result.revision?.sha ?? "missing"}`)
        .join(", ") || "no results"}`,
    );
  if (manifest) assertRunScenario(dir, manifest, label);
  if (manifest) evidenceReceipt(dir, label, manifest);
}

/** Refuses a matrix whose captured controls do not match the manifest it claims to render. */
export function assertRunScenario(dir: string, manifest: string, label: string): void {
  const expected = manifestCases(manifest);
  if (!expected.size) return;
  const results = matrixResults(dir);
  const seen = new Set<string>();
  const mismatches = results.filter((result) => {
    const id = result.id ?? "unknown";
    const wanted = expected.get(id);
    // The capture may use a union manifest so base-only/head-only cases remain comparable.
    if (wanted === undefined) return false;
    seen.add(id);
    return canonical(result.params ?? {}) !== wanted;
  });
  const missing = [...expected.keys()].filter((id) => !seen.has(id));
  if (mismatches.length || missing.length)
    throw new Error(
      `${label} matrix scenario mismatch: ${[
        ...mismatches.slice(0, 5).map((result) => `${result.id ?? "unknown"}:params`),
        ...missing.slice(0, 5).map((id) => `${id}:missing`),
      ].join(", ") || "unknown"}`,
    );
}

/** Shared IDs must carry the same controls in both sides of a comparison. */
export function assertScenarioParity(leftDir: string, rightDir: string, label = "comparison"): void {
  const left = new Map(matrixResults(leftDir).map((result) => [result.id ?? "unknown", canonical(result.params ?? {})]));
  const right = new Map(matrixResults(rightDir).map((result) => [result.id ?? "unknown", canonical(result.params ?? {})]));
  const mismatches = [...left.keys()]
    .filter((id) => right.has(id) && left.get(id) !== right.get(id))
    .slice(0, 5);
  if (mismatches.length) throw new Error(`${label} scenario mismatch: ${mismatches.map((id) => `${id}:params`).join(", ")}`);
}

if (import.meta.main) {
  const { values } = parseArgs({
    options: {
      base: { type: "string" },
      head: { type: "string" },
      repeat: { type: "string" },
      "base-manifest": { type: "string" },
      "head-manifest": { type: "string" },
      out: { type: "string" },
      outcomes: { type: "string" },
      pr: { type: "string" },
      "head-sha": { type: "string", default: "" },
      "base-sha": { type: "string", default: "" },
      "diff-url": { type: "string" },
      "gallery-url": { type: "string" },
      "matrix-url": { type: "string" },
      "feed-url": { type: "string" },
      "thumb-base": { type: "string" },
      "artifact-url": { type: "string" },
      branch: { type: "string" },
    },
  });
  const required = values.outcomes
    ? (["out", "pr"] as const)
    : (["base", "head", "head-manifest", "out", "pr"] as const);
  for (const name of required) if (!values[name]) throw new Error(`--${name} is required`);
  const out = values.out!;
  mkdirSync(out, { recursive: true });
  if (!values.outcomes) {
    assertRunRevision(values.base!, values["base-sha"]!, "base", values["base-manifest"]!);
    assertRunRevision(values.head!, values["head-sha"]!, "head", values["head-manifest"]!);
    assertScenarioParity(values.base!, values.head!, "base/head");
    if (values.repeat) {
      assertRunRevision(values.repeat, values["head-sha"]!, "repeat", values["head-manifest"]!);
      assertScenarioParity(values.head!, values.repeat, "head/repeat");
    }
  }
  const outcomes: Outcome[] = values.outcomes
    ? JSON.parse(readFileSync(values.outcomes, "utf8"))
    : compareRuns({
        baseDir: values.base!,
        headDir: values.head!,
        repeatDir: values.repeat,
        baseIds: caseIds(values["base-manifest"]),
        headIds: caseIds(values["head-manifest"]),
        outDir: out,
      });
  const meta: ReportMeta = {
    pr: Number(values.pr),
    head: values["head-sha"]!,
    base: values["base-sha"]!,
    links: {
      diff: values["diff-url"],
      gallery: values["gallery-url"],
      matrix: values["matrix-url"],
      feed: values["feed-url"],
      thumbBase: values["thumb-base"],
      artifact: values["artifact-url"],
      live: values.branch ? liveBase(values.branch) : undefined,
    },
  };
  const baseEvidence = values.outcomes ? undefined : evidenceReceipt(values.base!, "base", values["base-manifest"]);
  const headEvidence = values.outcomes ? undefined : evidenceReceipt(values.head!, "head", values["head-manifest"]);
  const repeatEvidence = values.outcomes || !values.repeat ? undefined : evidenceReceipt(values.repeat, "repeat", values["head-manifest"]);
  meta.evidence = { base: baseEvidence, head: headEvidence, repeat: repeatEvidence };
  writeFileSync(join(out, "outcomes.json"), `${JSON.stringify(outcomes, null, 2)}\n`);
  writeFileSync(join(out, "summary.json"), `${JSON.stringify(feedSummary(outcomes, meta), null, 2)}\n`);
  if (!values.outcomes)
    writeFileSync(
      join(out, "comparison.json"),
      `${JSON.stringify(comparisonReceipt(baseEvidence, headEvidence, repeatEvidence, { base: values["base-sha"]!, head: values["head-sha"]! }), null, 2)}\n`,
    );
  writeFileSync(join(out, "comment.md"), commentMarkdown(outcomes, meta));
  // thumbs.txt: the keys whose thumbnails the comment shows, for the publisher to upload.
  writeFileSync(
    join(out, "thumbs.txt"),
    commentThumbs(outcomes, meta)
      .map((o) => `${o.key}\n`)
      .join(""),
  );
  if (!values.outcomes) writeFileSync(join(out, "index.html"), diffPage(outcomes, meta));
  console.log(feedSummary(outcomes, meta).summary);
}
