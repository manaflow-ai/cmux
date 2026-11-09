import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const record = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/** Artifact contents are data only; policy and executable code stay in the trusted checkout. */
export function verifyRawTraceArtifacts(evidence: unknown, directory?: string): string[] {
  if (!directory) return ["raw trace directory is required to verify trace artifacts"];
  if (!record(evidence) || !Array.isArray(evidence.results)) return ["raw trace results are missing"];
  const errors: string[] = [];
  const seen = new Set<string>();
  for (const result of evidence.results) {
    const id = record(result) && typeof result.id === "string" ? result.id : "<missing id>";
    const trace = record(result) && record(result.rawTrace) ? result.rawTrace : null;
    try {
      if (!trace || typeof trace.path !== "string" || !trace.path || path.basename(trace.path) !== trace.path)
        throw new Error("trace path must be a file name");
      if (seen.has(trace.path)) throw new Error("trace artifact is reused by multiple cases");
      seen.add(trace.path);
      const file = path.join(directory, trace.path);
      const stat = fs.lstatSync(file);
      if (!stat.isFile()) throw new Error("trace artifact must be a regular file");
      if (stat.size !== trace.bytes) throw new Error("trace artifact byte length mismatch");
      const data = fs.readFileSync(file);
      if (createHash("sha256").update(data).digest("hex") !== trace.sha256)
        throw new Error("trace artifact digest mismatch");
      const timeline: unknown = JSON.parse(data.toString());
      if (!record(timeline) || !Array.isArray(timeline.traceEvents) || !timeline.traceEvents.length)
        throw new Error("raw trace contains no timeline events");
    } catch (error) {
      errors.push(`${id}: raw trace artifact verification failed (${String(error)})`);
    }
  }
  return errors;
}
