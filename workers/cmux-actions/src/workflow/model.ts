/**
 * Typed model of workflow files (`.github/workflows/*.yml`) and action
 * metadata (`action.yml`), parsed with YAML 1.2 core schema like GitHub (so
 * `on` stays a string key).
 */

import { parseDocument } from "yaml";
import { toValue, type Value, type ValueObject } from "../expr/value.ts";

export class WorkflowError extends Error {
  override readonly name = "WorkflowError";
  constructor(
    readonly path: string,
    readonly problems: readonly string[],
  ) {
    super(`${path}: ${problems.join("; ")}`);
  }
}

export interface Step {
  readonly id: string | null;
  readonly name: string | null;
  readonly uses: string | null;
  readonly run: string | null;
  readonly shell: string | null;
  readonly with: Readonly<Record<string, Value>>;
  readonly env: Readonly<Record<string, Value>>;
  readonly if: string | null;
  readonly workingDirectory: string | null;
  readonly continueOnError: Value;
  readonly timeoutMinutes: Value;
  readonly raw: ValueObject;
}

export interface Strategy {
  readonly matrix: Value;
  readonly failFast: Value;
  readonly maxParallel: Value;
}

export interface Job {
  readonly id: string;
  readonly name: string | null;
  readonly needs: readonly string[];
  readonly if: string | null;
  readonly runsOn: Value;
  readonly environment: Value;
  readonly timeoutMinutes: Value;
  readonly strategy: Strategy | null;
  readonly continueOnError: Value;
  readonly concurrency: Value;
  readonly env: Readonly<Record<string, Value>>;
  readonly outputs: Readonly<Record<string, Value>>;
  readonly permissions: Value;
  readonly services: Readonly<Record<string, Value>>;
  readonly container: Value;
  readonly steps: readonly Step[];
  /** Reusable workflow reference, for `jobs.<id>.uses`. */
  readonly uses: string | null;
  readonly with: Readonly<Record<string, Value>>;
  readonly secrets: "inherit" | Readonly<Record<string, Value>>;
  readonly raw: ValueObject;
}

export interface WorkflowCallInput {
  readonly type: string;
  readonly required: boolean;
  readonly default: Value;
}

export interface WorkflowCall {
  readonly inputs: Readonly<Record<string, WorkflowCallInput>>;
  readonly outputs: Readonly<Record<string, Value>>;
  readonly secrets: Readonly<Record<string, { readonly required: boolean }>>;
}

export interface Workflow {
  readonly path: string;
  readonly name: string | null;
  readonly runName: string | null;
  /** Event name to its filter configuration (null when the event has none). */
  readonly on: Readonly<Record<string, ValueObject | null>>;
  readonly env: Readonly<Record<string, Value>>;
  readonly permissions: Value;
  readonly concurrency: Value;
  readonly defaults: Value;
  readonly jobs: readonly Job[];
  readonly workflowCall: WorkflowCall | null;
}

export interface ActionInput {
  readonly required: boolean;
  readonly default: Value;
}

export interface Action {
  readonly path: string;
  readonly name: string | null;
  readonly inputs: Readonly<Record<string, ActionInput>>;
  readonly outputs: Readonly<Record<string, Value>>;
  readonly using: string;
  readonly steps: readonly Step[];
  readonly main: string | null;
  readonly pre: string | null;
  readonly post: string | null;
  readonly image: string | null;
}

const JOB_ID = /^[A-Za-z_][A-Za-z0-9_-]*$/;

const JOB_KEYS = new Set([
  "name",
  "needs",
  "if",
  "runs-on",
  "environment",
  "timeout-minutes",
  "strategy",
  "continue-on-error",
  "concurrency",
  "env",
  "outputs",
  "permissions",
  "services",
  "container",
  "steps",
  "uses",
  "with",
  "secrets",
  "defaults",
]);

const STEP_KEYS = new Set([
  "id",
  "name",
  "uses",
  "run",
  "shell",
  "with",
  "env",
  "if",
  "working-directory",
  "continue-on-error",
  "timeout-minutes",
]);

const isRecord = (value: Value | undefined): value is ValueObject =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const loadYaml = (text: string, path: string): Value => {
  const document = parseDocument(text, { version: "1.2", schema: "core", uniqueKeys: true });
  if (document.errors.length > 0) throw new WorkflowError(path, document.errors.map((error) => error.message));
  return toValue(document.toJS({ maxAliasCount: 1000 }));
};

const asString = (value: Value | undefined): string | null => {
  if (value === undefined || value === null) return null;
  if (typeof value === "string") return value;
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  return null;
};

const asRecord = (value: Value | undefined): Readonly<Record<string, Value>> => (isRecord(value) ? value : {});

const field = (object: ValueObject, key: string): Value => object[key] ?? null;

const parseStep = (raw: Value, where: string, problems: string[]): Step => {
  if (!isRecord(raw)) {
    problems.push(`${where}: a step must be a mapping`);
    return parseStep({}, where, []);
  }
  for (const key of Object.keys(raw)) if (!STEP_KEYS.has(key)) problems.push(`${where}: unknown step key '${key}'`);
  const uses = asString(raw.uses);
  const run = asString(raw.run);
  if (uses !== null && run !== null) problems.push(`${where}: a step cannot have both uses and run`);
  return {
    id: asString(raw.id),
    name: asString(raw.name),
    uses,
    run,
    shell: asString(raw.shell),
    with: asRecord(raw.with),
    env: asRecord(raw.env),
    if: asString(raw.if),
    workingDirectory: asString(raw["working-directory"]),
    continueOnError: field(raw, "continue-on-error"),
    timeoutMinutes: field(raw, "timeout-minutes"),
    raw,
  };
};

const parseJob = (id: string, raw: Value, problems: string[]): Job => {
  const where = `jobs.${id}`;
  if (!JOB_ID.test(id)) problems.push(`${where}: invalid job id`);
  const job = isRecord(raw) ? raw : {};
  if (!isRecord(raw)) problems.push(`${where}: a job must be a mapping`);
  for (const key of Object.keys(job)) if (!JOB_KEYS.has(key)) problems.push(`${where}: unknown job key '${key}'`);
  const needsRaw = job.needs;
  const needs =
    needsRaw === undefined || needsRaw === null
      ? []
      : Array.isArray(needsRaw)
        ? needsRaw.map((need) => asString(need) ?? "")
        : [asString(needsRaw) ?? ""];
  const strategyRaw = job.strategy;
  const strategy: Strategy | null = isRecord(strategyRaw)
    ? {
        matrix: field(strategyRaw, "matrix"),
        failFast: field(strategyRaw, "fail-fast"),
        maxParallel: field(strategyRaw, "max-parallel"),
      }
    : null;
  const uses = asString(job.uses);
  const stepsRaw = job.steps;
  if (uses === null && !Array.isArray(stepsRaw)) problems.push(`${where}: a job needs steps or uses`);
  if (uses !== null && stepsRaw !== undefined) problems.push(`${where}: a reusable workflow call cannot have steps`);
  const steps = Array.isArray(stepsRaw)
    ? stepsRaw.map((step, index) => parseStep(step, `${where}.steps[${index}]`, problems))
    : [];
  const secretsRaw = job.secrets;
  return {
    id,
    name: asString(job.name),
    needs,
    if: asString(job.if),
    runsOn: field(job, "runs-on"),
    environment: field(job, "environment"),
    timeoutMinutes: field(job, "timeout-minutes"),
    strategy,
    continueOnError: field(job, "continue-on-error"),
    concurrency: field(job, "concurrency"),
    env: asRecord(job.env),
    outputs: asRecord(job.outputs),
    permissions: field(job, "permissions"),
    services: asRecord(job.services),
    container: field(job, "container"),
    steps,
    uses,
    with: asRecord(job.with),
    secrets: secretsRaw === "inherit" ? "inherit" : asRecord(secretsRaw),
    raw: job,
  };
};

const parseTriggers = (raw: Value | undefined, path: string, problems: string[]): Record<string, ValueObject | null> => {
  const out: Record<string, ValueObject | null> = {};
  if (typeof raw === "string") out[raw] = null;
  else if (Array.isArray(raw)) for (const item of raw) out[asString(item) ?? ""] = null;
  else if (isRecord(raw)) for (const [event, config] of Object.entries(raw)) out[event] = isRecord(config) ? config : null;
  else problems.push(`${path}: missing 'on'`);
  return out;
};

const parseWorkflowCall = (config: ValueObject | null): WorkflowCall => {
  const inputs: Record<string, WorkflowCallInput> = {};
  for (const [name, spec] of Object.entries(asRecord(config?.inputs))) {
    const input = asRecord(spec);
    inputs[name] = {
      type: asString(input.type) ?? "string",
      required: input.required === true,
      default: input.default ?? null,
    };
  }
  const secrets: Record<string, { required: boolean }> = {};
  for (const [name, spec] of Object.entries(asRecord(config?.secrets))) {
    secrets[name] = { required: asRecord(spec).required === true };
  }
  const outputs: Record<string, Value> = {};
  for (const [name, spec] of Object.entries(asRecord(config?.outputs))) outputs[name] = asRecord(spec).value ?? null;
  return { inputs, outputs, secrets };
};

export const parseWorkflow = (text: string, path: string): Workflow => {
  const problems: string[] = [];
  const raw = loadYaml(text, path);
  if (!isRecord(raw)) throw new WorkflowError(path, ["a workflow must be a mapping"]);
  const on = parseTriggers(raw.on, path, problems);
  const jobsRaw = raw.jobs;
  if (!isRecord(jobsRaw)) throw new WorkflowError(path, [...problems, "missing 'jobs'"]);
  const jobs = Object.entries(jobsRaw).map(([id, job]) => parseJob(id, job, problems));
  const ids = new Set(jobs.map((job) => job.id));
  for (const job of jobs) {
    for (const need of job.needs) {
      if (!ids.has(need)) problems.push(`jobs.${job.id}: needs unknown job '${need}'`);
    }
  }
  if (problems.length > 0) throw new WorkflowError(path, problems);
  const callConfig = Object.hasOwn(on, "workflow_call") ? (on.workflow_call ?? null) : undefined;
  return {
    path,
    name: asString(raw.name),
    runName: asString(raw["run-name"]),
    on,
    env: asRecord(raw.env),
    permissions: field(raw, "permissions"),
    concurrency: field(raw, "concurrency"),
    defaults: field(raw, "defaults"),
    jobs,
    workflowCall: callConfig === undefined ? null : parseWorkflowCall(callConfig),
  };
};

export const parseAction = (text: string, path: string): Action => {
  const problems: string[] = [];
  const raw = loadYaml(text, path);
  if (!isRecord(raw)) throw new WorkflowError(path, ["an action must be a mapping"]);
  const runs = asRecord(raw.runs);
  const using = asString(runs.using);
  if (using === null) problems.push("runs.using is required");
  const inputs: Record<string, ActionInput> = {};
  for (const [name, spec] of Object.entries(asRecord(raw.inputs))) {
    const input = asRecord(spec);
    inputs[name] = { required: input.required === true, default: input.default ?? null };
  }
  const outputs: Record<string, Value> = {};
  for (const [name, spec] of Object.entries(asRecord(raw.outputs))) outputs[name] = asRecord(spec).value ?? null;
  const stepsRaw = runs.steps;
  const steps = Array.isArray(stepsRaw)
    ? stepsRaw.map((step, index) => parseStep(step, `runs.steps[${index}]`, problems))
    : [];
  if (using === "composite") {
    steps.forEach((step, index) => {
      if (step.run !== null && step.shell === null) problems.push(`runs.steps[${index}]: a composite run step needs shell`);
    });
  }
  if (problems.length > 0) throw new WorkflowError(path, problems);
  return {
    path,
    name: asString(raw.name),
    inputs,
    outputs,
    using: using ?? "",
    steps,
    main: asString(runs.main),
    pre: asString(runs.pre),
    post: asString(runs.post),
    image: asString(runs.image),
  };
};
