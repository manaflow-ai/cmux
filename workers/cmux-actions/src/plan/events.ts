/**
 * The events cmux Actions consumes (push, same-repo pull_request,
 * workflow_dispatch) and the `github` and `inputs` contexts built from them.
 */

import { type Value, type ValueObject } from "../expr/value.ts";
import type { Workflow } from "../workflow/model.ts";

export interface RunEvent {
  readonly name: "push" | "pull_request" | "workflow_dispatch";
  /** Full ref, e.g. `refs/heads/main` or `refs/pull/12/merge`. */
  readonly ref: string;
  readonly sha: string;
  readonly repository: string;
  readonly actor: string;
  readonly payload: ValueObject;
}

export interface RunIdentity {
  readonly runId: string;
  readonly runNumber: string;
  readonly runAttempt: string;
  readonly workflowPath: string;
  readonly workflowName: string;
}

const owner = (repository: string): string => repository.split("/")[0] ?? "";
const repoName = (repository: string): string => repository.split("/")[1] ?? "";

const repositoryPayload = (repository: string): ValueObject => ({
  full_name: repository,
  name: repoName(repository),
  owner: { login: owner(repository) },
  default_branch: "main",
});

export const pushEvent = (options: {
  readonly repository: string;
  readonly ref: string;
  readonly sha: string;
  readonly before?: string;
  readonly actor?: string;
}): RunEvent => {
  const actor = options.actor ?? "lawrencecchen";
  return {
    name: "push",
    ref: options.ref,
    sha: options.sha,
    repository: options.repository,
    actor,
    payload: {
      ref: options.ref,
      before: options.before ?? "0000000000000000000000000000000000000000",
      after: options.sha,
      created: false,
      deleted: false,
      forced: false,
      repository: repositoryPayload(options.repository),
      head_commit: { id: options.sha, message: "commit" },
      pusher: { name: actor },
      sender: { login: actor },
    },
  };
};

export const pullRequestEvent = (options: {
  readonly repository: string;
  readonly number: number;
  readonly headRef: string;
  readonly headSha: string;
  readonly baseRef: string;
  readonly baseSha: string;
  readonly mergeSha: string;
  readonly headRepository?: string;
  readonly action?: string;
  readonly labels?: readonly string[];
  readonly actor?: string;
}): RunEvent => {
  const actor = options.actor ?? "lawrencecchen";
  const headRepository = options.headRepository ?? options.repository;
  return {
    name: "pull_request",
    ref: `refs/pull/${options.number}/merge`,
    sha: options.mergeSha,
    repository: options.repository,
    actor,
    payload: {
      action: options.action ?? "synchronize",
      number: options.number,
      pull_request: {
        number: options.number,
        draft: false,
        user: { login: actor },
        labels: (options.labels ?? []).map((name) => ({ name })),
        head: { ref: options.headRef, sha: options.headSha, repo: repositoryPayload(headRepository) },
        base: { ref: options.baseRef, sha: options.baseSha, repo: repositoryPayload(options.repository) },
      },
      repository: repositoryPayload(options.repository),
      sender: { login: actor },
    },
  };
};

/** Same-repo check from DESIGN.md section 4: fork pull requests never run. */
export const isForkPullRequest = (event: RunEvent): boolean => {
  if (event.name !== "pull_request") return false;
  const pullRequest = event.payload.pull_request;
  if (typeof pullRequest !== "object" || pullRequest === null || Array.isArray(pullRequest)) return true;
  const head = (pullRequest as ValueObject).head;
  if (typeof head !== "object" || head === null || Array.isArray(head)) return true;
  const repo = (head as ValueObject).repo;
  if (typeof repo !== "object" || repo === null || Array.isArray(repo)) return true;
  return (repo as ValueObject).full_name !== event.repository;
};

/**
 * Dispatch inputs: `inputs` is typed (booleans and numbers keep their type),
 * `github.event.inputs` holds strings. Missing inputs take their defaults; a
 * choice input without a default takes its first option.
 */
export const workflowDispatchEvent = (options: {
  readonly repository: string;
  readonly ref: string;
  readonly sha: string;
  readonly workflow: Workflow;
  readonly inputs?: Readonly<Record<string, Value>>;
  readonly actor?: string;
}): { readonly event: RunEvent; readonly inputs: ValueObject } => {
  const actor = options.actor ?? "lawrencecchen";
  const declared = options.workflow.on.workflow_dispatch?.inputs;
  const typed: Record<string, Value> = {};
  if (typeof declared === "object" && declared !== null && !Array.isArray(declared)) {
    for (const [name, specValue] of Object.entries(declared as ValueObject)) {
      const spec = typeof specValue === "object" && specValue !== null && !Array.isArray(specValue) ? (specValue as ValueObject) : {};
      const type = typeof spec.type === "string" ? spec.type : "string";
      const options_ = Array.isArray(spec.options) ? spec.options : [];
      const given = options.inputs?.[name];
      const fallback = spec.default ?? (type === "choice" ? (options_[0] ?? null) : type === "boolean" ? false : "");
      const raw = given ?? fallback;
      if (type === "boolean") typed[name] = raw === true || raw === "true";
      else if (type === "number") typed[name] = typeof raw === "number" ? raw : Number(raw);
      else typed[name] = raw === null ? "" : typeof raw === "string" ? raw : String(raw);
    }
  }
  const eventInputs: Record<string, Value> = {};
  for (const [name, value] of Object.entries(typed)) eventInputs[name] = typeof value === "string" ? value : JSON.stringify(value);
  return {
    event: {
      name: "workflow_dispatch",
      ref: options.ref,
      sha: options.sha,
      repository: options.repository,
      actor,
      payload: {
        ref: options.ref,
        inputs: eventInputs,
        workflow: options.workflow.path,
        repository: repositoryPayload(options.repository),
        sender: { login: actor },
      },
    },
    inputs: typed,
  };
};

export const githubContext = (event: RunEvent, run: RunIdentity): ValueObject => {
  const refType = event.ref.startsWith("refs/tags/") ? "tag" : "branch";
  const refName = event.ref.replace(/^refs\/(heads|tags)\//, "");
  const pullRequest = event.payload.pull_request;
  const pr = typeof pullRequest === "object" && pullRequest !== null && !Array.isArray(pullRequest) ? (pullRequest as ValueObject) : null;
  const headRef = pr === null ? "" : String(((pr.head ?? {}) as ValueObject).ref ?? "");
  const baseRef = pr === null ? "" : String(((pr.base ?? {}) as ValueObject).ref ?? "");
  return {
    event_name: event.name,
    event: event.payload,
    sha: event.sha,
    ref: event.ref,
    ref_name: event.name === "pull_request" ? `${String(pr?.number ?? "")}/merge` : refName,
    ref_type: refType,
    ref_protected: false,
    head_ref: headRef,
    base_ref: baseRef,
    repository: event.repository,
    repository_owner: owner(event.repository),
    actor: event.actor,
    triggering_actor: event.actor,
    workflow: run.workflowName,
    workflow_ref: `${event.repository}/${run.workflowPath}@${event.ref}`,
    workflow_sha: event.sha,
    run_id: run.runId,
    run_number: run.runNumber,
    run_attempt: run.runAttempt,
    retention_days: "14",
    server_url: "https://github.com",
    api_url: "https://api.github.com",
    graphql_url: "https://api.github.com/graphql",
    workspace: `/home/runner/work/${repoName(event.repository)}/${repoName(event.repository)}`,
    action: "",
    action_path: "",
    job: "",
    token: "",
  };
};
