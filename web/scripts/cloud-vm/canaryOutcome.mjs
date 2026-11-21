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

/**
 * Returns the failures that should make the guest edge canary red.
 *
 * The provider's TLS implementation may steer an alias through mechanisms
 * other than a particular `/etc/hosts` marker. A successful authenticated
 * request to `vm-usage/self` is the behavioral proof that the edge injected
 * the VM-bound credential, so the canary judges that contract instead of the
 * provider's guest file layout.
 */
function unresolvedAliasProblem({ edgeHost, aliasWaitMs, guestUptimeS, hostsBlocks }) {
  const shown = (value, fallback = "?") => (value === null || value === undefined ? fallback : value);
  return `guest never resolved ${shown(edgeHost, "the edge alias")} (waited ${shown(aliasWaitMs)} ms; guest uptime ${shown(guestUptimeS)} s; freestyle-tls-egress blocks in /etc/hosts: ${shown(hostsBlocks)})`;
}

export function edgeCanaryProblems(report) {
  const {
    tokenOnDisk,
    modelsStatus,
    codexOutcome,
    claudeCheck,
    claudeOutcome = "",
    codexTail = "",
    claudeTail = "",
  } = report;
  const problems = [];
  if (report.aliasResolved === false) problems.push(unresolvedAliasProblem(report));
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

const ALIAS_HOST = /^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$/;

/**
 * The guest command that waits, at most `budgetSeconds`, for the edge alias to
 * resolve, then reports what it saw.
 *
 * The provider steers the alias (`/etc/hosts` today) a few seconds after boot,
 * and nothing in the create waits for it (web/services/vms/drivers/freestyle.ts,
 * "Injection becomes active 20-30 s after boot"). The canary execs within a few
 * seconds of the create response, so without this wait a run passes or fails on
 * that race alone: `curl: (6) Could not resolve host`. `getent hosts` takes the
 * same NSS path as curl's resolver, whatever mechanism the provider uses.
 * Returns null for a host that is not a bare host name.
 */
export function guestAliasWaitCommand(host, budgetSeconds = 60) {
  if (typeof host !== "string" || !ALIAS_HOST.test(host)) return null;
  const budget = Math.max(1, Math.floor(budgetSeconds));
  return [
    // The guest exec runs this under /bin/sh (dash on ubuntu:24.04), which has
    // no $SECONDS: the deadline is wall-clock seconds from `date +%s`.
    `h='${host}'; start=$(date +%s%N); deadline=$(( $(date +%s) + ${budget} ));`,
    `until getent hosts "$h" >/dev/null 2>&1; do [ "$(date +%s)" -ge "$deadline" ] && break; sleep 0.5; done;`,
    `end=$(date +%s%N); if getent hosts "$h" >/dev/null 2>&1; then r=1; else r=0; fi;`,
    `printf 'alias-resolved %s\\nalias-wait-ms %s\\nuptime-s %s\\nhosts-blocks %s\\n'`,
    `"$r" "$(( (end - start) / 1000000 ))" "$(cut -d' ' -f1 /proc/uptime)" "$(grep -c 'BEGIN freestyle-tls-egress' /etc/hosts 2>/dev/null)"`,
  ].join(" ");
}

/** Parses guestAliasWaitCommand's report; fields it cannot read are null. */
export function parseGuestAliasWait(output) {
  const fields = {};
  for (const line of String(output ?? "").split(/\r?\n/)) {
    const match = /^(alias-resolved|alias-wait-ms|uptime-s|hosts-blocks) (\S+)$/.exec(line.trim());
    if (match) fields[match[1]] = match[2];
  }
  const number = (value) => (value === undefined || !Number.isFinite(Number(value)) ? null : Number(value));
  return {
    aliasResolved: fields["alias-resolved"] === "1" ? true : fields["alias-resolved"] === "0" ? false : null,
    aliasWaitMs: number(fields["alias-wait-ms"]),
    guestUptimeS: number(fields["uptime-s"]),
    hostsBlocks: number(fields["hosts-blocks"]),
  };
}

/**
 * The stage a failed edge check reports. An alias the guest never resolved is
 * the provider's edge steering, not coderouter: no request reached it.
 * Everything past the guest's alias and disk is coderouter answering.
 */
export function edgeFailureStage({ aliasResolved, modelsStatus, codexOutcome, claudeCheck, claudeOutcome }) {
  if (aliasResolved === false) return "edge";
  const coderouterFailed = modelsStatus !== "200" || codexOutcome === "failed" || (claudeCheck && claudeOutcome !== "answered");
  return coderouterFailed ? "coderouter" : "edge";
}
