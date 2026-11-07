/** Evidence for comparing independently executed VM forks. Pure/read-only: this
 * module never starts VMs, trusts a Git branch name as a commit, or promotes a
 * candidate. A future RunSpec worker must attest these fields from the guest. */
export type ForkSourceEvidence = {
  /** The full immutable Git commit requested and the commit actually checked out. */
  requestedSha: string;
  observedSha: string;
  /** Dirty inputs require an explicitly recorded content digest. */
  worktree: "clean" | "captured" | "unknown";
  dirtyTreeDigest?: string;
  checkpointId: string;
  imageDigest: string;
  setupDigest: string;
  inputDigest: string;
  /** A bounded transcript/capsule may omit parts of an agent's context. */
  contextDigest: string;
  contextCoverage: "complete" | "truncated" | "unknown";
};

export type ForkCandidateReceipt = {
  attemptId: string;
  machineId: string;
  agentSessionId: string;
  branch: string;
  source: ForkSourceEvidence;
  finalSha: string;
  diffDigest: string;
  artifactManifestDigest: string;
  checks: {
    suiteDigest: string;
    status: "passed" | "failed" | "error" | "skipped";
    exitCode: number | null;
    resultDigest: string;
  };
  review: {
    reviewerSessionId: string;
    independent: boolean;
    verdict: "accepted" | "rejected" | "needs-work";
    reportDigest: string;
  };
  cost?: {
    coverage: "complete" | "partial" | "unknown";
    computeSeconds?: number;
    modelUsd?: number;
  };
};

export type ForkCandidateComparison = {
  status: "comparable" | "different-inputs" | "incomplete-evidence";
  reasons: readonly string[];
  /** Missing costs stay unknown; they are never silently treated as zero. */
  costCoverage: "complete" | "partial" | "unknown";
};

const FULL_SHA = /^[0-9a-f]{40}$/i;
const DIGEST = /^sha256:[0-9a-f]{64}$/i;
const BRANCH_SEGMENT = /^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/;

/** A deterministic, collision-resistant-by-attempt Git ref (when IDs are
 * unique). IDs are restricted to ref-safe lowercase ASCII path segments. */
export function forkExperimentBranch(runId: string, variantId: string, attemptNumber: number): string {
  if (!BRANCH_SEGMENT.test(runId) || !BRANCH_SEGMENT.test(variantId)) {
    throw new Error("runId and variantId must be lowercase Git-safe segments");
  }
  if (!Number.isSafeInteger(attemptNumber) || attemptNumber < 1) {
    throw new Error("attemptNumber must be a positive safe integer");
  }
  return `cmux/exp/${runId}/${variantId}-a${attemptNumber}`;
}

const sourceFields = [
  "requestedSha", "observedSha", "worktree", "dirtyTreeDigest", "checkpointId",
  "imageDigest", "setupDigest", "inputDigest", "contextDigest", "contextCoverage",
] as const;

/** Controlled comparisons require an identical verified starting point, test
 * suite and complete context. Different results, models or strategies are fine.
 * The function judges evidence completeness, never which candidate wins. */
export function compareForkCandidateReceipts(receipts: readonly ForkCandidateReceipt[]): ForkCandidateComparison {
  const incomplete = new Set<string>();
  const different = new Set<string>();
  if (receipts.length < 2) incomplete.add("at least two candidate receipts are required");

  const seen = {
    attempt: new Set<string>(),
    machine: new Set<string>(),
    session: new Set<string>(),
    branch: new Set<string>(),
  };
  const first = receipts[0];
  for (const [i, receipt] of receipts.entries()) {
    const name = `candidate ${i + 1}`;
    for (const [field, set, value] of [
      ["attemptId", seen.attempt, receipt.attemptId],
      ["machineId", seen.machine, receipt.machineId],
      ["agentSessionId", seen.session, receipt.agentSessionId],
      ["branch", seen.branch, receipt.branch],
    ] as const) {
      if (typeof value !== "string" || !value.trim()) incomplete.add(`${name} missing ${field}`);
      else if (set.has(value)) incomplete.add(`duplicate ${field}: ${value}`);
      else set.add(value);
    }

    const source = receipt.source;
    if (!source || !FULL_SHA.test(source.requestedSha) || !FULL_SHA.test(source.observedSha)) {
      incomplete.add(`${name} missing valid full Git source SHAs`);
    } else if (source.requestedSha.toLowerCase() !== source.observedSha.toLowerCase()) {
      different.add(`${name} observed source SHA differs from requested SHA`);
    }
    if (!source || !source.checkpointId?.trim()) incomplete.add(`${name} missing checkpoint identity`);
    for (const field of ["imageDigest", "setupDigest", "inputDigest", "contextDigest"] as const) {
      if (!source || !DIGEST.test(source[field])) incomplete.add(`${name} missing ${field}`);
    }
    if (source?.worktree === "captured") {
      if (!DIGEST.test(source.dirtyTreeDigest ?? "")) incomplete.add(`${name} missing dirty worktree digest`);
    } else if (source?.worktree !== "clean" || source.dirtyTreeDigest) {
      incomplete.add(`${name} has unverified worktree state`);
    }
    if (source?.contextCoverage !== "complete") incomplete.add(`${name} context coverage is incomplete`);
    if (!FULL_SHA.test(receipt.finalSha)) incomplete.add(`${name} missing final commit SHA`);
    if (!DIGEST.test(receipt.diffDigest) || !DIGEST.test(receipt.artifactManifestDigest)) {
      incomplete.add(`${name} missing diff/artifact evidence`);
    }

    const checks = receipt.checks;
    if (!checks || !DIGEST.test(checks.suiteDigest) || !DIGEST.test(checks.resultDigest) ||
        !["passed", "failed", "error"].includes(checks.status) ||
        (checks.status === "passed" && checks.exitCode !== 0) ||
        (checks.status === "failed" && (!Number.isInteger(checks.exitCode) || checks.exitCode === 0))) {
      incomplete.add(`${name} missing trustworthy test outcome`);
    }
    const review = receipt.review;
    if (!review || !review.independent || !review.reviewerSessionId?.trim() ||
        review.reviewerSessionId === receipt.agentSessionId ||
        !["accepted", "rejected", "needs-work"].includes(review.verdict) ||
        !DIGEST.test(review.reportDigest)) {
      incomplete.add(`${name} missing independent review`);
    }

    if (first && i > 0 && first.source && source) {
      for (const field of sourceFields) {
        if (String(source[field] ?? "").toLowerCase() !== String(first.source[field] ?? "").toLowerCase()) {
          different.add(`starting ${field} differs between candidates`);
        }
      }
      if (checks?.suiteDigest !== first.checks?.suiteDigest) different.add("test suite digest differs between candidates");
    }
  }

  const costComplete = (receipt: ForkCandidateReceipt) =>
    receipt.cost?.coverage === "complete" &&
    typeof receipt.cost.computeSeconds === "number" && Number.isFinite(receipt.cost.computeSeconds) && receipt.cost.computeSeconds >= 0 &&
    typeof receipt.cost.modelUsd === "number" && Number.isFinite(receipt.cost.modelUsd) && receipt.cost.modelUsd >= 0;
  const costCoverage = receipts.length > 0 && receipts.every(costComplete) ? "complete"
    : receipts.some((receipt) => receipt.cost?.coverage !== "unknown" &&
      (receipt.cost?.computeSeconds !== undefined || receipt.cost?.modelUsd !== undefined)) ? "partial" : "unknown";
  if (costCoverage !== "complete") incomplete.add("costs incomplete: compare as unknown, never zero");

  const status = different.size > 0 ? "different-inputs"
    : incomplete.size > 0 && [...incomplete].some((reason) => !reason.startsWith("costs incomplete"))
      ? "incomplete-evidence" : "comparable";
  return { status, reasons: [...different, ...incomplete], costCoverage };
}
