"use strict";

const CACHE_REFRESH_JOB = "refresh-compilation-cache";

// Keep workflow identifiers out of the operator-facing issue. Unknown jobs are
// intentionally collapsed to a generic label so adding a new pipeline stage
// cannot leak an internal identifier into a public issue.
const JOB_LABELS = Object.freeze({
  [CACHE_REFRESH_JOB]: "cache refresh",
  "build-nightly-ghostty-cli-helper": "Ghostty CLI helper",
  "build-nightly-app": "app compile",
  "build-sign-notarize-nightly": "sign and notarize",
  "publish-nightly": "publish",
});

const FAILURE_RESULTS = new Set(["failure", "cancelled"]);

function summarizeNightlyFailure(results) {
  const failed = Object.entries(results ?? {})
    .filter(([, value]) => FAILURE_RESULTS.has(value?.result))
    .map(([name]) => name);
  const publishFailed = failed.some((name) => name !== CACHE_REFRESH_JOB);
  const failureKind = publishFailed ? "publish pipeline" : "cache refresh";
  const impact = publishFailed
    ? "NIGHTLY installs stop receiving updates until a run on main succeeds."
    : "The cache refresh failed; no publish was attempted and the previous NIGHTLY remains available.";
  const failedLabels = failed.map((name) => JOB_LABELS[name] ?? "other nightly job");
  const where = failedLabels.length > 0 ? failedLabels.join(", ") : failureKind;

  return { failed, failedLabels, publishFailed, failureKind, impact, where };
}

function formatNightlyFailure({ runUrl, headSha, results }) {
  const summary = summarizeNightlyFailure(results);
  // The public run URL and source SHA are deliberate audit breadcrumbs, not
  // credentials: operators need them to locate the exact failed execution.
  const body =
    `Nightly run ${runUrl} failed on ${headSha} in the ${summary.where}.\n\n` +
    `${summary.impact} This issue closes itself on the next successful publish.`;
  return { ...summary, body };
}

module.exports = { formatNightlyFailure, summarizeNightlyFailure };
