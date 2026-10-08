/**
 * Plans a run the way GitHub would: job order from `needs`, job `if`
 * conditions with status functions over ancestors, matrix expansion (deferred
 * when it waits for `needs` outputs), `runs-on` labels, and local reusable
 * workflows inlined as `<caller>/<job>`. Job results come from `outcome`
 * (default: success), so tests can drive any path through the graph.
 *
 * RunDO uses the same functions one job at a time; the simulator runs them
 * over the whole graph in one call.
 */

import { type EvalContext, evaluateCondition, evaluateDeep, evaluateTemplate } from "../expr/evaluate.ts";
import { isObject, toText, type Value, type ValueObject } from "../expr/value.ts";
import { type Job, parseWorkflow, type Workflow, WorkflowError } from "../workflow/model.ts";
import { classifyJob } from "./classify.ts";
import { githubContext, type RunEvent, type RunIdentity } from "./events.ts";
import { type LabelDecision, resolveRunsOn } from "./labels.ts";
import { type Combination, expandMatrix } from "./matrix.ts";
import { parseUses, type RepoFiles, referencesContext } from "./references.ts";

export type JobStatus = "run" | "skipped" | "deferred" | "blocked" | "error";
export type JobResult = "success" | "failure" | "cancelled" | "skipped";

export interface SimulatedJob {
  /** Unique key: job id, `(index)` per matrix leg, `caller/` prefix inside reusable workflows. */
  readonly key: string;
  readonly jobId: string;
  readonly workflowPath: string;
  readonly name: string;
  readonly matrix: Combination | null;
  readonly status: JobStatus;
  readonly runsOn: Value;
  /** Null when the job does not run or `runs-on` waits for `needs` outputs. */
  readonly label: LabelDecision | null;
  /** Why cmux Actions cannot run this job (empty: it can). */
  readonly unsupported: readonly string[];
  /** Error, deferral or blocking reason. */
  readonly detail: string | null;
}

export interface Outcome {
  readonly result?: "success" | "failure" | "cancelled";
  readonly outputs?: Readonly<Record<string, string>>;
}

export interface SimulateOptions {
  readonly event: RunEvent;
  /** Typed `inputs` for workflow_dispatch. */
  readonly inputs?: ValueObject;
  readonly run?: Partial<RunIdentity>;
  readonly vars?: Readonly<Record<string, string>>;
  /** Names of secrets cmux Actions holds for the repo. */
  readonly secrets?: ReadonlySet<string>;
  readonly files: RepoFiles;
  readonly outcome?: (job: SimulatedJob) => Outcome | undefined;
}

export interface Simulation {
  readonly jobs: readonly SimulatedJob[];
  readonly errors: readonly string[];
}

/** GitHub's limit on nested reusable workflow calls. */
export const MAX_REUSABLE_DEPTH = 4;

interface NodeState {
  readonly status: JobStatus;
  readonly result: JobResult;
  readonly outputs: ValueObject;
}

interface Scope {
  readonly workflow: Workflow;
  readonly prefix: string;
  readonly namePrefix: string;
  readonly github: ValueObject;
  readonly inputs: ValueObject;
  readonly depth: number;
}

const message = (error: unknown): string => (error instanceof Error ? error.message : String(error));

const topologicalOrder = (workflow: Workflow): Job[] => {
  const remaining = new Map(workflow.jobs.map((job) => [job.id, job]));
  const done = new Set<string>();
  const order: Job[] = [];
  while (remaining.size > 0) {
    const ready = [...remaining.values()].find((job) => job.needs.every((need) => done.has(need)));
    if (ready === undefined) {
      throw new WorkflowError(workflow.path, [`needs cycle among jobs: ${[...remaining.keys()].join(", ")}`]);
    }
    order.push(ready);
    done.add(ready.id);
    remaining.delete(ready.id);
  }
  return order;
};

const ancestorsOf = (workflow: Workflow, job: Job): Set<string> => {
  const byId = new Map(workflow.jobs.map((item) => [item.id, item]));
  const found = new Set<string>();
  const stack = [...job.needs];
  while (stack.length > 0) {
    const id = stack.pop() ?? "";
    if (found.has(id)) continue;
    found.add(id);
    stack.push(...(byId.get(id)?.needs ?? []));
  }
  return found;
};

const aggregate = (results: readonly JobResult[]): JobResult => {
  if (results.includes("failure")) return "failure";
  if (results.includes("cancelled")) return "cancelled";
  if (results.length > 0 && results.every((result) => result === "skipped")) return "skipped";
  return "success";
};

const toOutputs = (outputs: Readonly<Record<string, string>> | undefined): ValueObject => ({ ...(outputs ?? {}) });

export const simulateRun = (workflow: Workflow, options: SimulateOptions): Simulation => {
  const jobs: SimulatedJob[] = [];
  const errors: string[] = [];
  const secretNames = options.secrets ?? new Set<string>();
  const vars: ValueObject = { ...(options.vars ?? {}) };
  const secretsContext: ValueObject = Object.fromEntries([...secretNames].map((name) => [name, "***"]));

  const identity = (scopeWorkflow: Workflow): RunIdentity => ({
    runId: options.run?.runId ?? "1",
    runNumber: options.run?.runNumber ?? "1",
    runAttempt: options.run?.runAttempt ?? "1",
    workflowPath: options.run?.workflowPath ?? scopeWorkflow.path,
    workflowName: options.run?.workflowName ?? scopeWorkflow.name ?? scopeWorkflow.path,
  });

  const record = (job: SimulatedJob): void => {
    jobs.push(job);
    if (job.status === "error" && job.detail !== null) errors.push(`${job.workflowPath} ${job.key}: ${job.detail}`);
  };

  const simulateScope = (scope: Scope): Map<string, NodeState> => {
    const { workflow: current } = scope;
    const states = new Map<string, NodeState>();
    let order: Job[];
    try {
      order = topologicalOrder(current);
    } catch (error) {
      errors.push(message(error));
      return states;
    }

    for (const job of order) {
      const key = `${scope.prefix}${job.id}`;
      const base = {
        jobId: job.id,
        workflowPath: current.path,
        matrix: null,
        runsOn: job.runsOn,
        label: null,
        unsupported: [] as string[],
      };
      const rawName = `${scope.namePrefix}${job.name ?? job.id}`;
      const needStates = job.needs.map((need) => [need, states.get(need)] as const);
      const waiting = needStates.find(([, state]) => state === undefined || state.status === "deferred" || state.status === "blocked" || state.status === "error");
      if (waiting !== undefined) {
        record({ ...base, key, name: rawName, status: "blocked", detail: `waits for ${waiting[0]}` });
        states.set(job.id, { status: "blocked", result: "skipped", outputs: {} });
        continue;
      }
      const needsContext: Record<string, Value> = {};
      for (const [need, state] of needStates) {
        needsContext[need] = { result: state?.result ?? "skipped", outputs: state?.outputs ?? {} };
      }
      const ancestorResults = [...ancestorsOf(current, job)].map((id) => states.get(id)?.result ?? "skipped");
      const jobContext: EvalContext = {
        contexts: {
          github: { ...scope.github, job: job.id },
          vars,
          inputs: scope.inputs,
          needs: needsContext,
          secrets: secretsContext,
          env: { ...current.env },
          strategy: {},
          matrix: {},
        },
        status: {
          success: () => ancestorResults.every((result) => result === "success"),
          failure: () => ancestorResults.includes("failure"),
          cancelled: () => false,
        },
      };

      let runs: boolean;
      try {
        runs = evaluateCondition(job.if ?? "", jobContext);
      } catch (error) {
        record({ ...base, key, name: rawName, status: "error", detail: `if: ${message(error)}` });
        states.set(job.id, { status: "error", result: "failure", outputs: {} });
        continue;
      }
      if (!runs) {
        record({ ...base, key, name: rawName, status: "skipped", detail: null });
        states.set(job.id, { status: "skipped", result: "skipped", outputs: {} });
        continue;
      }

      if (job.uses !== null) {
        states.set(job.id, simulateCall(scope, job, key, jobContext));
        continue;
      }

      let legs: Array<Combination | null>;
      try {
        const matrixRaw = job.strategy?.matrix ?? null;
        const matrix =
          matrixRaw === null ? null : typeof matrixRaw === "string" ? evaluateTemplate(matrixRaw, jobContext) : evaluateDeep(matrixRaw, jobContext);
        legs = expandMatrix(matrix) ?? [null];
      } catch (error) {
        const waitsForNeeds = referencesContext(job.strategy?.matrix ?? null, "needs");
        const status: JobStatus = waitsForNeeds ? "deferred" : "error";
        record({ ...base, key, name: rawName, status, detail: `matrix: ${message(error)}` });
        states.set(job.id, { status, result: waitsForNeeds ? "skipped" : "failure", outputs: {} });
        continue;
      }

      const results: JobResult[] = [];
      let outputs: ValueObject = {};
      let legError = false;
      legs.forEach((leg, index) => {
        const legContext: EvalContext = {
          ...jobContext,
          contexts: {
            ...jobContext.contexts,
            matrix: leg ?? {},
            strategy: {
              "fail-fast": job.strategy?.failFast ?? true,
              "job-index": index,
              "job-total": legs.length,
              "max-parallel": job.strategy?.maxParallel ?? legs.length,
            },
          },
        };
        const legKey = leg === null ? key : `${key}(${index})`;
        let name: string;
        try {
          name =
            job.name !== null
              ? toText(evaluateTemplate(job.name, legContext))
              : leg === null
                ? job.id
                : `${job.id} (${Object.values(leg).map((value) => toText(value)).join(", ")})`;
        } catch (error) {
          record({ ...base, key: legKey, name: rawName, matrix: leg, status: "error", detail: `name: ${message(error)}` });
          results.push("failure");
          legError = true;
          return;
        }
        let runsOn: Value = job.runsOn;
        let label: LabelDecision | null = null;
        let detail: string | null = null;
        try {
          if (job.runsOn === null) throw new Error("runs-on is required");
          runsOn = evaluateDeep(job.runsOn, legContext);
          label = resolveRunsOn(runsOn);
        } catch (error) {
          if (!referencesContext(job.runsOn, "needs")) {
            record({ ...base, key: legKey, name: `${scope.namePrefix}${name}`, matrix: leg, status: "error", detail: `runs-on: ${message(error)}` });
            results.push("failure");
            legError = true;
            return;
          }
          detail = `runs-on waits for needs outputs: ${message(error)}`;
        }
        const simulated: SimulatedJob = {
          ...base,
          key: legKey,
          name: `${scope.namePrefix}${name}`,
          matrix: leg,
          status: "run",
          runsOn,
          label,
          unsupported: classifyJob(current, job, label, options.files, secretNames),
          detail,
        };
        record(simulated);
        const outcome = options.outcome?.(simulated);
        results.push(outcome?.result ?? "success");
        outputs = { ...outputs, ...toOutputs(outcome?.outputs) };
      });
      states.set(job.id, { status: legError ? "error" : "run", result: aggregate(results), outputs });
    }
    return states;
  };

  const simulateCall = (scope: Scope, job: Job, key: string, context: EvalContext): NodeState => {
    const callerName = (() => {
      try {
        return job.name === null ? job.id : toText(evaluateTemplate(job.name, context));
      } catch {
        return job.name ?? job.id;
      }
    })();
    const fail = (detail: string): NodeState => {
      record({
        key,
        jobId: job.id,
        workflowPath: scope.workflow.path,
        name: `${scope.namePrefix}${callerName}`,
        matrix: null,
        status: "error",
        runsOn: null,
        label: null,
        unsupported: [],
        detail,
      });
      return { status: "error", result: "failure", outputs: {} };
    };
    const target = parseUses(job.uses ?? "");
    if (target.kind !== "local") return fail(`only local reusable workflows are supported: ${job.uses ?? ""}`);
    if (job.strategy !== null) return fail("a matrix on a reusable workflow call is not supported");
    if (scope.depth >= MAX_REUSABLE_DEPTH) return fail(`reusable workflows nest deeper than ${MAX_REUSABLE_DEPTH}`);
    const text = options.files.read(target.path);
    if (text === undefined) return fail(`reusable workflow not found: ${target.path}`);
    let callee: Workflow;
    try {
      callee = parseWorkflow(text, target.path);
    } catch (error) {
      return fail(message(error));
    }
    const call = callee.workflowCall;
    if (call === null) return fail(`${target.path} has no workflow_call trigger`);

    let given: Value;
    try {
      given = evaluateDeep({ ...job.with }, context);
    } catch (error) {
      return fail(`with: ${message(error)}`);
    }
    const provided = isObject(given) ? given : {};
    const inputs: Record<string, Value> = {};
    for (const name of Object.keys(provided)) {
      if (!Object.hasOwn(call.inputs, name)) return fail(`input '${name}' is not declared by ${target.path}`);
    }
    for (const [name, spec] of Object.entries(call.inputs)) {
      const value = Object.hasOwn(provided, name) ? (provided[name] ?? null) : null;
      if (value === null && spec.required && !Object.hasOwn(provided, name)) return fail(`required input '${name}' is missing`);
      let resolved: Value;
      try {
        resolved = value ?? (typeof spec.default === "string" ? evaluateTemplate(spec.default, context) : spec.default);
      } catch (error) {
        return fail(`input '${name}' default: ${message(error)}`);
      }
      if (spec.type === "boolean") {
        if (typeof resolved === "string" && (resolved === "true" || resolved === "false")) resolved = resolved === "true";
        if (resolved === null) resolved = false;
        if (typeof resolved !== "boolean") return fail(`input '${name}' must be a boolean`);
      } else if (spec.type === "number") {
        if (resolved === null) resolved = 0;
        if (typeof resolved === "string" && resolved.trim() !== "" && !Number.isNaN(Number(resolved))) resolved = Number(resolved);
        if (typeof resolved !== "number") return fail(`input '${name}' must be a number`);
      } else {
        resolved = resolved === null ? "" : typeof resolved === "string" ? resolved : toText(resolved);
      }
      inputs[name] = resolved;
    }
    if (job.secrets !== "inherit") {
      for (const name of Object.keys(job.secrets)) {
        if (!Object.hasOwn(call.secrets, name)) return fail(`secret '${name}' is not declared by ${target.path}`);
      }
    }

    const inner = simulateScope({
      workflow: callee,
      prefix: `${key}/`,
      namePrefix: `${scope.namePrefix}${callerName} / `,
      github: scope.github,
      inputs,
      depth: scope.depth + 1,
    });
    const innerStates = [...inner.values()];
    const stuck = innerStates.find((state) => state.status === "deferred" || state.status === "blocked" || state.status === "error");
    const result = aggregate(innerStates.map((state) => (state.result === "skipped" ? "success" : state.result)));
    const jobsContext: Record<string, Value> = {};
    for (const [id, state] of inner) jobsContext[id] = { result: state.result, outputs: state.outputs };
    const outputs: Record<string, Value> = {};
    if (stuck === undefined) {
      for (const [name, value] of Object.entries(call.outputs)) {
        try {
          outputs[name] = toText(
            typeof value === "string"
              ? evaluateTemplate(value, { contexts: { ...context.contexts, inputs, jobs: jobsContext } })
              : value,
          );
        } catch (error) {
          return fail(`output '${name}': ${message(error)}`);
        }
      }
    }
    return { status: stuck === undefined ? "run" : "blocked", result, outputs };
  };

  let github: ValueObject;
  try {
    github = githubContext(options.event, identity(workflow));
  } catch (error) {
    return { jobs, errors: [message(error)] };
  }
  simulateScope({ workflow, prefix: "", namePrefix: "", github, inputs: options.inputs ?? {}, depth: 0 });
  return { jobs, errors };
};
