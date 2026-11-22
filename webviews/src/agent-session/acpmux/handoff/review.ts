import type { Enforcement } from "./protocol";
import { formatHandoff, handoffStrings, type HandoffStrings } from "./strings";
export type HandoffReviewInput = {
  capsule: string;
  checkpoint: { reference: string; confirmed: boolean };
  approvedMemoryReferences: string[];
  revision?: number;
};
function hasControlCharacters(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code < 32 || code === 127) return true;
  }
  return false;
}
export function reviewedContinuation(
  capsule: string,
  checkpointReference: string,
  checkpointConfirmed: boolean,
  memoryReferences: string,
  maxBytes = 65536,
  strings: HandoffStrings = handoffStrings(),
): HandoffReviewInput {
  const reference = checkpointReference.trim();
  const references = [
    ...new Set(
      memoryReferences
        .split(/\r?\n/)
        .map((value) => value.trim())
        .filter(Boolean),
    ),
  ];
  if (!capsule.trim()) throw new Error(strings.reviewContext);
  if (new TextEncoder().encode(capsule).length > maxBytes)
    throw new Error(formatHandoff(strings.tooLarge, String(maxBytes)));
  if (!reference || !checkpointConfirmed) throw new Error(strings.saveCheckpoint);
  if (reference.length > 2048 || hasControlCharacters(reference)) throw new Error(strings.checkpointSingle);
  if (references.length > 32 || references.some((value) => value.length > 2048 || hasControlCharacters(value)))
    throw new Error(strings.memoryLimit);
  return { capsule, checkpoint: { reference, confirmed: true }, approvedMemoryReferences: references };
}
export function sessionEnforcement(value: unknown): Enforcement | undefined {
  if (!value || typeof value !== "object") return undefined;
  const report = value as Record<string, unknown>;
  return report.label === "native_policy" &&
    report.isolation === "unverified" &&
    typeof report.policy === "string" &&
    !!report.policy.trim() &&
    (report.detail === null || typeof report.detail === "string")
    ? (report as Enforcement)
    : undefined;
}
