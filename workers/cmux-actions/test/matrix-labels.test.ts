import { describe, expect, it } from "vitest";
import { expandMatrix, MatrixError, resolveRunsOn } from "../src/plan/index.ts";
import { isForkPullRequest, pullRequestEvent } from "../src/plan/events.ts";
import { parseWorkflow, WorkflowError } from "../src/workflow/model.ts";
import { REPOSITORY, SHA_A, SHA_B, SHA_C } from "./support/repo.ts";

describe("expandMatrix", () => {
  it("returns null without a matrix", () => {
    expect(expandMatrix(null)).toBeNull();
  });

  it("follows the documented include example", () => {
    // https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/run-job-variations#example-expanding-configurations
    const combinations = expandMatrix({
      fruit: ["apple", "pear"],
      animal: ["cat", "dog"],
      include: [
        { color: "green" },
        { color: "pink", animal: "cat" },
        { fruit: "apple", shape: "circle" },
        { fruit: "banana" },
        { fruit: "banana", animal: "cat" },
      ],
    });
    expect(combinations).toEqual([
      { fruit: "apple", animal: "cat", color: "pink", shape: "circle" },
      { fruit: "apple", animal: "dog", color: "green", shape: "circle" },
      { fruit: "pear", animal: "cat", color: "pink" },
      { fruit: "pear", animal: "dog", color: "green" },
      { fruit: "banana" },
      { fruit: "banana", animal: "cat" },
    ]);
  });

  it("applies exclude before include, with partial matches", () => {
    const combinations = expandMatrix({
      os: ["macos-latest", "windows-latest"],
      version: [12, 14, 16],
      environment: ["staging", "production"],
      exclude: [
        { os: "macos-latest", version: 12, environment: "production" },
        { os: "windows-latest", version: 16 },
      ],
    });
    expect(combinations).toHaveLength(9);
    expect(combinations).not.toContainEqual({ os: "windows-latest", version: 16, environment: "staging" });
  });

  it("expands an include-only matrix, as cmux-tui.yml uses", () => {
    expect(expandMatrix({ include: [{ os: "macos", runner: "m" }, { os: "linux", runner: "l" }] })).toEqual([
      { os: "macos", runner: "m" },
      { os: "linux", runner: "l" },
    ]);
  });

  it("rejects empty and oversized matrices", () => {
    expect(() => expandMatrix({ include: [] })).toThrow(MatrixError);
    expect(() => expandMatrix({ a: Array.from({ length: 16 }, (_, i) => i), b: Array.from({ length: 17 }, (_, i) => i) })).toThrow(
      /limit is 256/,
    );
    expect(() => expandMatrix({ a: "x" })).toThrow(MatrixError);
  });
});

describe("resolveRunsOn", () => {
  it("maps Linux labels to VM sizes", () => {
    expect(resolveRunsOn("blacksmith-4vcpu-ubuntu-2404")).toEqual({
      kind: "linux",
      label: "blacksmith-4vcpu-ubuntu-2404",
      vcpus: 4,
      memoryGiB: 16,
    });
    expect(resolveRunsOn("ubuntu-latest")).toMatchObject({ kind: "linux", vcpus: 4 });
    expect(resolveRunsOn(["self-hosted", "blacksmith-32vcpu-ubuntu-2404"])).toMatchObject({ kind: "linux", vcpus: 32 });
  });

  it("marks macOS, Windows, ARM and unknown labels unsupported", () => {
    for (const label of [
      "blacksmith-6vcpu-macos-15",
      "macos-26",
      "blacksmith-4vcpu-windows-2025",
      "blacksmith-4vcpu-ubuntu-2404-arm",
      "ubuntu-24.04-arm",
      "depot-macos-15",
      "my-runner",
      "",
    ]) {
      expect(resolveRunsOn(label).kind, label).toBe("unsupported");
    }
    expect(resolveRunsOn({ group: "x" }).kind).toBe("unsupported");
  });
});

describe("fork gate", () => {
  const base = { repository: REPOSITORY, number: 7, headRef: "f", headSha: SHA_A, baseRef: "main", baseSha: SHA_B, mergeSha: SHA_C };

  it("treats a pull request from another repository as a fork", () => {
    expect(isForkPullRequest(pullRequestEvent(base))).toBe(false);
    expect(isForkPullRequest(pullRequestEvent({ ...base, headRepository: "someone/cmux" }))).toBe(true);
  });
});

describe("parseWorkflow", () => {
  it("keeps 'on' as a key and parses YAML 1.2 flow scalars with colons", () => {
    const workflow = parseWorkflow(
      [
        "on: push",
        "jobs:",
        "  db:",
        "    runs-on: ubuntu-latest",
        "    services:",
        "      postgres:",
        "        image: postgres:16-alpine",
        "        ports: [5432:5432]",
        "    steps:",
        "      - run: echo hi",
      ].join("\n"),
      "inline.yml",
    );
    expect(workflow.on).toEqual({ push: null });
    expect(workflow.jobs[0]?.services).toEqual({ postgres: { image: "postgres:16-alpine", ports: ["5432:5432"] } });
  });

  it("rejects unknown needs, duplicate keys and steps with both uses and run", () => {
    const bad = (text: string) => () => parseWorkflow(text, "bad.yml");
    expect(bad("on: push\njobs:\n  a:\n    runs-on: x\n    needs: b\n    steps: [{run: x}]")).toThrow(/needs unknown job 'b'/);
    expect(bad("on: push\non: pull_request\njobs: {}")).toThrow(WorkflowError);
    expect(bad("on: push\njobs:\n  a:\n    runs-on: x\n    steps: [{run: x, uses: y}]")).toThrow(/both uses and run/);
  });
});
