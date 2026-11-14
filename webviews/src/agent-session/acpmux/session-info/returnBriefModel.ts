// l10n-allow-file: gallery prototype, not shipped: only ReturnBrief.gallery.tsx imports it (HQ #6236 brief 17).
/** Gallery-only, read-only completion projection. The caller must fetch run/approval/PR receipts
 * from their owners, and re-read saved bytes through the authorized artifact owner. Agent prose
 * and transcript tool paths cannot produce any "verified" status here. */
export type EvidenceLevel =
  | "observed"
  | "verified"
  | "unverified"
  | "stale"
  | "failed"
  | "unknown"
  | "inaccessible"
  | "expired";
export type ReviewAction = "changes" | "artifact";
export type ReviewItem = {
  id: "changes" | "checks" | "artifact" | "preview" | "approvals" | "pull-request";
  label: string;
  detail: string;
  level: EvidenceLevel;
  href?: string;
  action?: ReviewAction;
};
export type ReturnBriefInput = {
  sessionId: string;
  turnId: string;
  repository: string;
  commit: string;
  now: number;
  viewerScope: string;
  observed: { changedPaths: readonly string[]; previews: number };
  /** Actual job owner, bound to this acpmux turn + checked source revision. */
  run?: {
    ownerRead: boolean;
    sessionId: string;
    turnId: string;
    commit: string;
    kind: "tests" | "build";
    state: "running" | "succeeded" | "failed" | "cancelled" | "outcome_unknown";
    tests?: { passed: number; failed: number; skipped: number };
    /** The repository the run belongs to, as its owner reports it; the Actions link needs it. */
    repository?: string;
    githubRunId?: number;
  };
  /** Re-read immutable file bytes, hash them, check CURRENT identity and read permission.
   * checkedAt must be the owner read's timestamp in the same clock domain as now. */
  artifact?: {
    ownerRead: boolean;
    checkedAt: number;
    sessionId: string;
    turnId: string;
    id: string;
    path: string;
    revision: string;
    digest: string;
    readbackDigest?: string;
    scope: string;
    accessible: boolean;
    expiresAt?: number;
  };
  /** An authority-bound, observed approval decision (never inferred from tool success). */
  approval?: {
    ownerRead: boolean;
    sessionId: string;
    turnId: string;
    authority: string;
    state: "pending" | "approved" | "denied" | "unknown";
  };
  /** Re-fetched from GitHub independently of a link the agent mentioned. */
  pullRequest?: {
    ownerRead: boolean;
    repository: string;
    number: number;
    headCommit: string;
    state: "draft" | "open" | "closed" | "merged";
  };
  /** Reported risks; displayed as unverified claims, never as safety attestations. */
  risks?: readonly string[];
};

const SHA = /^[0-9a-f]{40}$/;
const DIGEST = /^sha256:[0-9a-f]{64}$/;
const REPOSITORY = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
/** The gallery's refresh window; production adapters must supply and enforce owner TTLs. */
export const MAX_ARTIFACT_READ_AGE_MS = 60_000;
const sameTurn = (input: ReturnBriefInput, other: { sessionId: string; turnId: string }) =>
  input.sessionId === other.sessionId && input.turnId === other.turnId;
const sourceMatches = (input: ReturnBriefInput, sha: string) => SHA.test(input.commit) && sha === input.commit;
const safeRepository = (repo: string | undefined) => (repo !== undefined && REPOSITORY.test(repo) ? repo : undefined);
const testCounts = (
  counts: NonNullable<ReturnBriefInput["run"]>["tests"],
): counts is {
  passed: number;
  failed: number;
  skipped: number;
} => !!counts && [counts.passed, counts.failed, counts.skipped].every((n) => Number.isSafeInteger(n) && n >= 0);

export function returnBrief(input: ReturnBriefInput): {
  source: string;
  items: ReviewItem[];
  risks: readonly string[];
} {
  const repository = safeRepository(input.repository);
  const source =
    repository && SHA.test(input.commit)
      ? repository + " @ " + input.commit.slice(0, 12)
      : "Source revision unverified";
  const count = new Set(input.observed.changedPaths).size;
  const items: ReviewItem[] = [
    {
      id: "changes",
      label: "Files changed",
      level: count ? "observed" : "unverified",
      detail: count ? count + " path(s) observed in this chat · review the actual diff" : "No edits recorded",
      ...(count ? { action: "changes" as const } : {}),
    },
  ];

  const run = input.run;
  if (!run || !run.ownerRead) {
    items.push({
      id: "checks",
      label: "Tests & builds",
      level: "unverified",
      detail: "No independently read job receipt",
    });
  } else if (!sameTurn(input, run) || !sourceMatches(input, run.commit)) {
    items.push({
      id: "checks",
      label: "Tests & builds",
      level: "stale",
      detail: "Job belongs to another turn or commit",
    });
  } else {
    const href =
      repository &&
      safeRepository(run.repository) === repository &&
      Number.isSafeInteger(run.githubRunId) &&
      (run.githubRunId ?? 0) > 0
        ? "https://github.com/" + repository + "/actions/runs/" + run.githubRunId
        : undefined;
    let level: EvidenceLevel;
    let detail: string;
    switch (run.state) {
      case "succeeded":
        if (run.kind === "build") {
          level = "verified";
          detail = "Build owner reports success at this commit · tests separately unverified";
        } else if (testCounts(run.tests) && run.tests.passed + run.tests.failed > 0 && run.tests.failed === 0) {
          level = "verified";
          detail =
            run.tests.passed +
            " tests passed" +
            (run.tests.skipped ? ", " + run.tests.skipped + " skipped" : "") +
            " · owner receipt";
        } else {
          level = "unverified";
          detail = "Run finished; executed passing tests unconfirmed";
        }
        break;
      case "failed":
        level = "failed";
        detail = "Run owner reports failure · inspect the log";
        break;
      case "cancelled":
        level = "failed";
        detail = "Run owner reports cancellation";
        break;
      case "running":
        level = "observed";
        detail = "Owner confirms run still in progress";
        break;
      case "outcome_unknown":
        level = "unknown";
        detail = "Outcome unknown · reconcile the original job, never replay its side effects";
        break;
    }
    items.push({ id: "checks", label: "Tests & builds", level, detail, ...(href ? { href } : {}) });
  }

  const artifact = input.artifact;
  if (!artifact || !artifact.ownerRead) {
    items.push({
      id: "artifact",
      label: "Saved result",
      level: "unverified",
      detail: "No independently re-read file receipt",
    });
  } else if (!sameTurn(input, artifact) || !SHA.test(artifact.revision)) {
    items.push({
      id: "artifact",
      label: "Saved result",
      level: "stale",
      detail: "Missing immutable revision or wrong turn",
    });
  } else if (!artifact.accessible || artifact.scope !== input.viewerScope) {
    items.push({
      id: "artifact",
      label: "Saved result",
      level: "inaccessible",
      detail: "Current account lacks access · check the original owner",
    });
  } else if (
    !Number.isFinite(input.now) ||
    (artifact.expiresAt !== undefined && !Number.isFinite(artifact.expiresAt))
  ) {
    // A NaN or infinite time makes every comparison below false, which would pass expiry and freshness.
    items.push({
      id: "artifact",
      label: "Saved result",
      level: "stale",
      detail: "Clock or retention time unreadable · refresh before opening",
    });
  } else if (artifact.expiresAt !== undefined && input.now >= artifact.expiresAt) {
    items.push({
      id: "artifact",
      label: "Saved result",
      level: "expired",
      detail: "Retention expired · request republication",
    });
  } else if (
    !Number.isFinite(artifact.checkedAt) ||
    artifact.checkedAt > input.now ||
    input.now - artifact.checkedAt > MAX_ARTIFACT_READ_AGE_MS
  ) {
    items.push({
      id: "artifact",
      label: "Saved result",
      level: "stale",
      detail: "Owner access/readback check aged out · refresh before opening",
    });
  } else if (!DIGEST.test(artifact.digest) || !artifact.readbackDigest || artifact.readbackDigest !== artifact.digest) {
    items.push({
      id: "artifact",
      label: "Saved result",
      level: "failed",
      detail: "Independent byte/digest readback missing or mismatched",
    });
  } else {
    items.push({
      id: "artifact",
      label: "Saved result",
      level: "verified",
      detail: artifact.path + " · immutable revision " + artifact.revision.slice(0, 12) + " · SHA-256 matched",
      action: "artifact",
    });
  }

  if (input.observed.previews > 0)
    items.push({
      id: "preview",
      label: "Screenshots & previews",
      level: "observed",
      detail: input.observed.previews + " transcript preview(s) · capture/build identity still unverified",
    });

  const approval = input.approval;
  if (!approval || !approval.ownerRead || !sameTurn(input, approval) || !approval.authority) {
    items.push({
      id: "approvals",
      label: "Approvals",
      level: "unverified",
      detail: "No turn-bound decision from the permission owner",
    });
  } else {
    const status = {
      pending: ["observed", "Permission request pending · open the original chat to respond"],
      approved: ["verified", "Permission owner records approval for this turn"],
      denied: ["failed", "Permission owner records denial for this turn"],
      unknown: ["unknown", "Approval outcome unknown · consult the original owner"],
    } as const;
    items.push({
      id: "approvals",
      label: "Approvals",
      level: status[approval.state][0],
      detail: status[approval.state][1],
    });
  }

  const pr = input.pullRequest;
  if (pr) {
    const href =
      repository && safeRepository(pr.repository) === repository && Number.isSafeInteger(pr.number) && pr.number > 0
        ? "https://github.com/" + repository + "/pull/" + pr.number
        : undefined;
    const matching = pr.ownerRead && !!href && sourceMatches(input, pr.headCommit);
    items.push({
      id: "pull-request",
      label: "Pull request",
      level: !matching ? "stale" : pr.state === "closed" ? "failed" : "verified",
      detail: matching
        ? pr.state === "merged"
          ? "GitHub reports merged"
          : pr.state === "closed"
            ? "GitHub reports closed without merge"
            : "GitHub reports " + pr.state + " · awaits human review"
        : "PR link or head lacks a matching independent GitHub read",
      ...(href ? { href } : {}),
    });
  }
  return { source, items, risks: input.risks ?? [] };
}
