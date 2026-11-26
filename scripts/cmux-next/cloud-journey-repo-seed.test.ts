import { describe, expect, test } from "bun:test";
import { parseRepoSeed, repoSeedDetail, repoSeedRuns, repoSeedScripts } from "./cloud-journey-repo-seed.ts";

describe("repo seed probe", () => {
  test("runs are opt-in and bounded", () => {
    expect(repoSeedRuns(undefined)).toBe(0);
    expect(repoSeedRuns("0")).toBe(0);
    expect(repoSeedRuns("x")).toBe(0);
    expect(repoSeedRuns("3")).toBe(3);
    expect(repoSeedRuns("40")).toBe(5);
  });

  test("the clone and the borrow are two scripts on one folder, and the borrow cleans it up", () => {
    const s = repoSeedScripts("/tmp/cmux-seed-probe-1-1");
    expect(s.clone).toContain("git clone -q --filter=blob:none --no-checkout");
    expect(s.clone).toContain("w='/tmp/cmux-seed-probe-1-1'");
    expect(s.clone).not.toContain("trap");
    expect(s.borrow).toContain("objects/info/alternates");
    expect(s.borrow).toContain("extensions.partialClone origin");
    expect(s.borrow).toContain("trap 'rm -rf \"$w\"' EXIT");
    expect(s.cleanup).toBe("rm -rf '/tmp/cmux-seed-probe-1-1'");
  });

  test("a full run reads back as one detail line", () => {
    const out = [
      "noise",
      "@@seed facts git=2.43.0 env_mirrors=unset default_mirror=no dev_tree=no free_kb=1000",
      "@@seed clone code=0 checkout_code=0 clone_ms=40000 checkout_ms=9000 ms=49000 rx=1395864371 git_bytes=1300000000 err=",
      "@@seed borrow code=0 missing=0 setup_ms=50 checkout_ms=900 ms=950 rx=1000 git_bytes=90000000 err=",
    ].join("\n");
    const p = parseRepoSeed(out);
    expect(p.clone.ms).toBe("49000");
    expect(p.borrow.err).toBe("");
    const d = repoSeedDetail(p);
    expect(d.ok).toBe(true);
    expect(d.detail).toContain("env_mirrors=unset default_mirror=no");
    expect(d.detail).toContain("clone 49000 ms");
    expect(d.detail).toContain("received 1331 MiB");
    expect(d.detail).toContain("borrow 950 ms");
  });

  test("a failed clone names its error", () => {
    const d = repoSeedDetail(parseRepoSeed("@@seed clone code=128 checkout_code=1 clone_ms=1 checkout_ms=1 ms=2 rx=0 git_bytes=0 err=fatal: unable to access x"));
    expect(d.ok).toBe(false);
    expect(d.detail).toContain("fatal: unable to access x");
  });
});
