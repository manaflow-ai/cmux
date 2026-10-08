/**
 * Fixture tests over every workflow in .github/workflows and every local
 * action in .github/actions of this checkout: each file parses, each
 * expression and condition parses, each `uses:` resolves or is pinned, and
 * each consumed trigger (push, pull_request, workflow_dispatch) plans
 * without errors.
 */

import { describe, expect, it } from "vitest";
import {
  expressionsOf,
  isPinned,
  loadLocalAction,
  parseUses,
  pullRequestEvent,
  pushEvent,
  type RunEvent,
  simulateRun,
  templateExpressions,
  workflowDispatchEvent,
} from "../src/plan/index.ts";
import type { Value, ValueObject } from "../src/expr/value.ts";
import { type Action, parseWorkflow, type Step, type Workflow } from "../src/workflow/model.ts";
import { actionDirectories, localActionPaths, REPOSITORY, SHA_A, SHA_B, SHA_C, workflowPaths, workingTree } from "./support/repo.ts";

/**
 * Known non-SHA pins. The coordinator fixes ci.yml's 39-character
 * upload-artifact pin on main (decision C7); this list may only shrink.
 */
const KNOWN_UNPINNED = new Set(["actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0"]);

const load = (path: string): Workflow => {
  const text = workingTree.read(path);
  if (text === undefined) throw new Error(`missing ${path}`);
  return parseWorkflow(text, path);
};

const eventsFor = (workflow: Workflow): Array<{ event: RunEvent; inputs?: ValueObject }> => {
  const out: Array<{ event: RunEvent; inputs?: ValueObject }> = [];
  if ("push" in workflow.on) out.push({ event: pushEvent({ repository: REPOSITORY, ref: "refs/heads/main", sha: SHA_A }) });
  if ("pull_request" in workflow.on) {
    out.push({
      event: pullRequestEvent({
        repository: REPOSITORY,
        number: 1,
        headRef: "feat-x",
        headSha: SHA_B,
        baseRef: "main",
        baseSha: SHA_A,
        mergeSha: SHA_C,
      }),
    });
  }
  if ("workflow_dispatch" in workflow.on) {
    const dispatch = workflowDispatchEvent({ repository: REPOSITORY, ref: "refs/heads/main", sha: SHA_A, workflow });
    out.push({ event: dispatch.event, inputs: dispatch.inputs });
  }
  return out;
};

const unpinned = (steps: readonly Step[]): string[] =>
  steps.flatMap((step) => (step.uses !== null && !isPinned(parseUses(step.uses)) ? [step.uses] : []));

/**
 * Local actions that do not exist in the tree. A local action under a
 * directory that an earlier actions/checkout step of the same job fills
 * (`with.path`) resolves at run time and is allowed.
 */
const missingLocal = (steps: readonly Step[]): string[] => {
  const checkedOut: string[] = [];
  return steps.flatMap((step) => {
    if (step.uses === null) return [];
    const ref = parseUses(step.uses);
    if (ref.kind === "remote" && `${ref.owner}/${ref.repo}` === "actions/checkout" && typeof step.with.path === "string") {
      checkedOut.push(step.with.path.replace(/^\.\//, "").replace(/\/+$/, ""));
    }
    if (ref.kind !== "local" || loadLocalAction(workingTree, ref.path) !== undefined) return [];
    return checkedOut.some((directory) => ref.path.startsWith(`${directory}/`)) ? [] : [step.uses];
  });
};

describe.each(workflowPaths())("%s", (path) => {
  it("parses", () => {
    expect(() => load(path)).not.toThrow();
  });

  it("has only valid expressions and conditions", () => {
    const workflow = load(path);
    const values: Value[] = [workflow.env, workflow.concurrency, workflow.runName, workflow.workflowCall?.outputs ?? null];
    for (const value of values) {
      expect(() => templateExpressions(value)).not.toThrow();
    }
    for (const job of workflow.jobs) {
      expect(() => expressionsOf(job.raw), `jobs.${job.id}`).not.toThrow();
    }
  });

  it("references local actions and reusable workflows that exist, and pins remote actions", () => {
    const workflow = load(path);
    const steps = workflow.jobs.flatMap((job) => job.steps);
    expect(workflow.jobs.flatMap((job) => missingLocal(job.steps))).toEqual([]);
    for (const reference of unpinned(steps)) expect(KNOWN_UNPINNED.has(reference), reference).toBe(true);
    for (const job of workflow.jobs) {
      if (job.uses === null) continue;
      const ref = parseUses(job.uses);
      expect(ref.kind, job.uses).toBe("local");
      if (ref.kind === "local") expect(load(ref.path).workflowCall, job.uses).not.toBeNull();
    }
  });

  it("plans every consumed trigger without errors", () => {
    const workflow = load(path);
    for (const { event, inputs } of eventsFor(workflow)) {
      const simulation = simulateRun(workflow, inputs === undefined ? { event, files: workingTree } : { event, inputs, files: workingTree });
      expect(simulation.errors, event.name).toEqual([]);
      for (const job of simulation.jobs.filter((item) => item.status === "run")) {
        const resolved = job.label !== null || (job.detail ?? "").startsWith("runs-on waits for needs outputs");
        expect(resolved, `${event.name} ${job.key}`).toBe(true);
      }
    }
  });
});

describe.each(localActionPaths())("%s", (directory) => {
  const action = (): Action => {
    const loaded = loadLocalAction(workingTree, directory);
    if (loaded === undefined) throw new Error(`missing ${directory}/action.yml`);
    return loaded;
  };

  it("parses, with shell on every composite run step", () => {
    expect(() => action()).not.toThrow();
  });

  it("has only valid expressions, existing local references and pinned remote actions", () => {
    const loaded = action();
    for (const step of loaded.steps) expect(() => expressionsOf(step.raw)).not.toThrow();
    expect(missingLocal(loaded.steps)).toEqual([]);
    for (const reference of unpinned(loaded.steps)) expect(KNOWN_UNPINNED.has(reference), reference).toBe(true);
  });
});

/**
 * Coverage holds on any branch: no hard-coded counts of workflows or actions,
 * which differ between main and feature branches.
 */
describe("fixture coverage", () => {
  it("covers the whole workflow directory", () => {
    expect(workflowPaths().length).toBeGreaterThan(0);
    for (const path of workflowPaths()) expect(load(path).jobs.length, path).toBeGreaterThan(0);
  });

  it("covers every local action directory", () => {
    // A directory without action.yml or action.yaml would be skipped by the
    // per-action tests above, and a `uses:` of it fails at run time.
    expect(actionDirectories().filter((directory) => !localActionPaths().includes(directory))).toEqual([]);
  });

  it("plans jobs across all workflows and triggers", () => {
    const totals = { plans: 0, jobs: 0, run: 0, skipped: 0, deferred: 0, blocked: 0, linuxCandidates: 0, linuxUnsupported: 0, other: 0 };
    for (const path of workflowPaths()) {
      const workflow = load(path);
      for (const { event, inputs } of eventsFor(workflow)) {
        totals.plans += 1;
        const simulation = simulateRun(workflow, inputs === undefined ? { event, files: workingTree } : { event, inputs, files: workingTree });
        for (const job of simulation.jobs) {
          totals.jobs += 1;
          if (job.status === "run") {
            totals.run += 1;
            if (job.label?.kind === "linux") {
              if (job.unsupported.length === 0) totals.linuxCandidates += 1;
              else totals.linuxUnsupported += 1;
            } else totals.other += 1;
          } else if (job.status === "skipped") totals.skipped += 1;
          else if (job.status === "deferred") totals.deferred += 1;
          else if (job.status === "blocked") totals.blocked += 1;
        }
      }
    }
    console.log(`cmux-actions plan totals: ${JSON.stringify(totals)}`);
    expect(totals.plans).toBeGreaterThan(0);
    expect(totals.jobs).toBeGreaterThanOrEqual(totals.plans);
    expect(totals.linuxCandidates).toBeGreaterThan(0);
  });
});
