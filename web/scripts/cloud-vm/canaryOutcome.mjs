/**
 * Classifies the response captured by the Cloud VM edge canary.
 *
 * The no-account response has existed in two wire shapes: the original flat
 * `error: "no_usable_account"` body and the OpenAI-shaped terminal 403 with
 * `error.code: "no_account_configured"`. Both mean the throwaway canary team
 * reached coderouter and has no upstream account, so either is a passing
 * no-token outcome.
 */
export function classifyCodexCanaryOutcome(output, { zeroToken }) {
  if (typeof output !== "string") return "failed";
  if (output.includes("codex-missing")) return "failed";

  if (!zeroToken && output.split("\n").some((line) => line.trim().toLowerCase() === "pong")) {
    return "answered";
  }

  for (const line of output.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("{")) continue;
    try {
      const parsed = JSON.parse(trimmed);
      const error = parsed?.error;
      if (error === "no_usable_account" || (error && typeof error === "object" && error.code === "no_account_configured")) {
        return "no_account";
      }
    } catch {
      // The command output can contain non-JSON diagnostics; keep scanning.
    }
  }

  return "failed";
}
