import { RunCloudHttpError } from "./cloudClientContract";

/** The steps of a Run attempt a failure receipt may name. */
const RUN_STAGES = new Set(["vm-create", "checkpoint", "guest-command", "source-receipt", "completion-marker", "artifact"]);

/** Tag an error from `work` with the attempt step it came from. The innermost
 * step wins, and the error keeps its class so control-flow errors still match. */
export async function labelRunStage<T>(stage: string, work: () => Promise<T>): Promise<T> {
  try {
    return await work();
  } catch (error) {
    if (error instanceof Error && Object.isExtensible(error) && (error as { runStage?: unknown }).runStage === undefined) Object.assign(error, { runStage: stage });
    throw error;
  }
}

/** ` (vm-create, HTTP 403, vm_limit_exceeded)` for a durable failure receipt:
 * a known step plus only an HTTP status, a short error code and a guest exit
 * code. Empty for anything else, so provider text never reaches the receipt. */
export function runFailureDetail(error: unknown): string {
  if (!(error instanceof Error)) return "";
  const stage = (error as { runStage?: unknown }).runStage;
  if (typeof stage !== "string" || !RUN_STAGES.has(stage)) return "";
  const parts = [stage];
  if (error instanceof RunCloudHttpError) {
    parts.push(`HTTP ${error.status}`);
    if (error.code) parts.push(error.code);
  }
  const exitCode = (error as { exitCode?: unknown }).exitCode;
  if (typeof exitCode === "number" && Number.isSafeInteger(exitCode)) parts.push(`exit ${exitCode}`);
  return ` (${parts.join(", ")})`;
}
