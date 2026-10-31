import { describe, expect, test } from "bun:test";
import {
  compareForkCandidateReceipts,
  forkExperimentBranch,
  type ForkCandidateReceipt,
} from "../services/vms/forkCandidateReceipts";

const sha = (c: string) => c.repeat(40);
const digest = (c: string) => `sha256:${c.repeat(64)}`;
const base = {
  requestedSha: sha("a"), observedSha: sha("a"), worktree: "clean" as const,
  checkpointId: "checkpoint-1", imageDigest: digest("b"), setupDigest: digest("c"),
  inputDigest: digest("d"), contextDigest: digest("e"), contextCoverage: "complete" as const,
};
function candidate(id: string): ForkCandidateReceipt {
  return {
    attemptId: id, machineId: `vm-${id}`, agentSessionId: `agent-${id}`,
    branch: forkExperimentBranch("run-123", id, 1), source: { ...base },
    finalSha: sha("f"), diffDigest: digest("1"), artifactManifestDigest: digest("2"),
    checks: { suiteDigest: digest("3"), status: "passed", exitCode: 0, resultDigest: digest("4") },
    review: { reviewerSessionId: `reviewer-${id}`, independent: true, verdict: "accepted", reportDigest: digest("5") },
    cost: { coverage: "complete", computeSeconds: 10, modelUsd: 0.05 },
  };
}

describe("fork candidate receipt comparison", () => {
  test("accepts different strategies and results with identical verified inputs", () => {
    const a = candidate("refactor");
    const b = { ...candidate("patch"), finalSha: sha("1"), diffDigest: digest("6"),
      checks: { ...candidate("patch").checks, status: "failed" as const, exitCode: 2 } };
    expect(compareForkCandidateReceipts([a, b])).toEqual({status:"comparable",reasons:[],costCoverage:"complete"});
  });
  test("identifies a different initial SHA and a different test suite", () => {
    const b = candidate("patch");
    b.source.requestedSha = sha("9"); b.source.observedSha = sha("9");
    b.checks.suiteDigest = digest("9");
    const result = compareForkCandidateReceipts([candidate("refactor"), b]);
    expect(result.status).toBe("different-inputs");
    expect(result.reasons.join(" ")).toContain("starting requestedSha");
    expect(result.reasons.join(" ")).toContain("test suite");
  });
  test("rejects a copied session or machine identity", () => {
    const a = candidate("a"); const b = candidate("b");
    b.agentSessionId = a.agentSessionId; b.machineId = a.machineId;
    const result = compareForkCandidateReceipts([a, b]);
    expect(result.status).toBe("incomplete-evidence");
    expect(result.reasons.join(" ")).toContain("duplicate machineId");
    expect(result.reasons.join(" ")).toContain("duplicate agentSessionId");
  });
  test("refuses truncated context and unverified source/dirty worktree", () => {
    const b = candidate("b"); b.source.contextCoverage = "truncated";
    b.source.worktree = "captured"; b.source.dirtyTreeDigest = undefined;
    b.source.observedSha = sha("8");
    const result = compareForkCandidateReceipts([candidate("a"), b]);
    expect(result.status).toBe("different-inputs");
    expect(result.reasons.join(" ")).toContain("observed source SHA differs");
    expect(result.reasons.join(" ")).toContain("dirty worktree digest");
  });
  test("requires independent review, tests and artifacts", () => {
    const b = candidate("b"); b.review.reviewerSessionId = b.agentSessionId;
    b.checks.status = "skipped"; b.artifactManifestDigest = "unknown";
    const result = compareForkCandidateReceipts([candidate("a"), b]);
    expect(result.status).toBe("incomplete-evidence");
  });
  test("missing cost is unknown even if other results are comparable", () => {
    const a = candidate("a"); const b = candidate("b");
    b.cost = { coverage: "unknown" };
    const result = compareForkCandidateReceipts([a, b]);
    expect(result).toEqual({ status: "comparable", reasons: ["costs incomplete: compare as unknown, never zero"], costCoverage: "partial" });
  });
  test("one candidate is insufficient", () => {
    expect(compareForkCandidateReceipts([candidate("a")]).status).toBe("incomplete-evidence");
  });
  test("safe repeatable Git branch names", () => {
    expect(forkExperimentBranch("run-1", "patch", 2)).toBe("cmux/exp/run-1/patch-a2");
    expect(() => forkExperimentBranch("../escape", "patch", 1)).toThrow();
    expect(() => forkExperimentBranch("run", "with/slash", 1)).toThrow();
    expect(() => forkExperimentBranch("run", "patch", 0)).toThrow();
  });
});
