import { setTimeout as sleep } from "node:timers/promises";

/**
 * Classifies the response captured by the Cloud VM edge canary.
 *
 * The no-account response has existed in three wire shapes: the original flat
 * `error: "no_usable_account"` body, the OpenAI-shaped terminal 403 with
 * `error.code: "no_account_configured"`, and the terminal 429 with
 * `error.code: "no_usable_account"` (accounts exist, none usable). Each means
 * the throwaway canary team reached coderouter and has no usable upstream
 * account, so any of them is a passing no-token outcome.
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
      if (error === "no_usable_account" || (error && typeof error === "object" && (error.code === "no_account_configured" || error.code === "no_usable_account"))) {
        return "no_account";
      }
    } catch {
      // The command output can contain non-JSON diagnostics; keep scanning.
    }
  }

  return "failed";
}

/**
 * Returns the failures that should make the guest edge canary red.
 *
 * The provider's TLS implementation may steer an alias through mechanisms
 * other than a particular `/etc/hosts` marker. A successful authenticated
 * request to `vm-usage/self` is the behavioral proof that the edge injected
 * the VM-bound credential, so the canary judges that contract instead of the
 * provider's guest file layout.
 */
export function edgeCanaryProblems({
  tokenOnDisk,
  modelsStatus,
  codexOutcome,
  claudeCheck,
  claudeOutcome = "",
  codexTail = "",
  claudeTail = "",
}) {
  const problems = [];
  if (tokenOnDisk) problems.push(`route token found in guest files: ${tokenOnDisk}`);
  if (modelsStatus !== "200") {
    problems.push(`GET /api/coderouter/vm-usage/self from the guest returned ${modelsStatus || "nothing"}`);
  }
  if (codexOutcome === "failed") problems.push(`codex turn through the edge did not answer: ${codexTail ?? ""}`);
  if (claudeCheck && claudeOutcome !== "answered") {
    problems.push(`claude turn through the edge did not answer: ${claudeTail ?? ""}`);
  }
  return problems;
}

/**
 * Retry an idempotent guest edge probe only when curl could not resolve its
 * expected alias. Provider/API errors and HTTP refusals remain single attempts.
 * The attempt cap and the caller's signal bound retries; cancellation also
 * interrupts the delay and is forwarded to the active guest request.
 * @param {(signal?: AbortSignal) => Promise<{ stdout?: string, stderr?: string, exitCode?: number }>} run
 * @param {string} host
 * @param {{ attempts?: number, delayMs?: number, signal?: AbortSignal }} [options]
 * @returns {Promise<{ stdout?: string, stderr?: string, exitCode?: number }>}
 */
export async function retryGuestEdgeRequest(
  run,
  host,
  { attempts = 4, delayMs = 1_000, signal } = {},
) {
  if (!Number.isInteger(attempts) || attempts < 1) {
    throw new RangeError("guest edge retry attempts must be positive");
  }
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    signal?.throwIfAborted();
    const result = await run(signal);
    const resolverMiss = typeof host === "string" && host !== "" &&
      [result?.stdout, result?.stderr].some((output) => typeof output === "string" &&
        output.split(/\r?\n/).some((line) => line.trim() === `curl: (6) Could not resolve host: ${host}`));
    if (!resolverMiss || attempt + 1 === attempts) return result;
    if (delayMs > 0) await sleep(delayMs, undefined, { signal });
  }
}
