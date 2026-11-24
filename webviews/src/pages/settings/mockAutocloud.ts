// l10n-allow-file: mock cloud automations data; the real labels come from cmux-tui cli/autocloud.rs.
// The mock Settings > Automations: a view model shaped like `cmux autocloud overview --json` and the
// CLI's answers to each action (SettingsAutomationsCloud), so the card and its gallery run with no
// CLI and no platform. Pure data: the gallery imports these fixtures.
import type {
  AutocloudAction,
  AutocloudAnswer,
  AutocloudAutomation,
  AutocloudCatalog,
  AutocloudCondition,
  AutocloudOverview,
  AutocloudRun,
  AutocloudSpec,
  AutocloudState,
  AutocloudTemplate,
} from "./ops";

const GITHUB_EVENTS: Array<[string, string]> = [
  ["ci_failure", "CI fails"],
  ["pr_opened", "A pull request opens"],
  ["review_requested", "A review is requested"],
  ["issue_labeled", "An issue is labeled"],
  ["pr_comment", "A pull request comment"],
  ["pr_review_comment", "A review comment"],
  ["push", "A push"],
];

const OPS: Array<[string, string]> = [
  ["equals", "equals"],
  ["not_equals", "does not equal"],
  ["in", "is one of"],
  ["not_in", "is none of"],
  ["contains", "contains"],
  ["prefix", "starts with"],
  ["exists", "exists"],
  ["missing", "is missing"],
  ["gt", "is more than"],
  ["gte", "is at least"],
  ["lt", "is less than"],
  ["lte", "is at most"],
];

const HARNESSES: Array<[string, string]> = [
  ["claude", "Claude Code"],
  ["codex", "Codex"],
];

const choices = (list: Array<[string, string]>) => list.map(([value, label]) => ({ value, label }));

export const MOCK_AUTOCLOUD_CATALOG: AutocloudCatalog = {
  triggerTypes: choices([
    ["github", "GitHub event"],
    ["webhook", "Webhook"],
    ["schedule", "Schedule"],
  ]),
  githubEvents: choices(GITHUB_EVENTS),
  ops: choices(OPS),
  harnesses: choices(HARNESSES),
  samples: [
    ...GITHUB_EVENTS.map(([value, label]) => ({
      value,
      label: `GitHub: ${label.toLowerCase()}`,
    })),
    { value: "webhook", label: "Webhook: a JSON body" },
    { value: "schedule", label: "Schedule: the time it fired" },
  ],
};

export const MOCK_AUTOCLOUD_TEMPLATES: AutocloudTemplate[] = [
  {
    id: "ci-fix",
    title: "When CI fails on a PR, start an agent to fix it and push to the PR",
    summary:
      "GitHub CI fails on a pull request's branch: an agent reads the failure, fixes it and pushes to the same branch.",
    spec: {
      name: "Fix CI on pull requests",
      trigger: { type: "github", events: ["ci_failure"], repository: "" },
      conditions: [
        { path: "workflow_run.event", op: "equals", value: "pull_request" },
        { path: "workflow_run.pull_requests.0.number", op: "exists" },
      ],
      action: {
        type: "start_agent",
        repo: "",
        ref: "{{event.workflow_run.head_branch}}",
        harness: "claude",
        prompt:
          "CI ({{event.workflow_run.name}}) failed on pull request #{{event.workflow_run.pull_requests.0.number}} in {{event.repository.full_name}}: {{event.workflow_run.html_url}}\n\nRead the failing job's log, find the cause, fix it, run the failing check locally if you can, and push the fix to the branch {{event.workflow_run.head_branch}}. Do not open a new pull request.",
        postBack: "comment",
        openPr: false,
      },
      guardrails: {
        cooldownSeconds: 1800,
        maxRunsPerDay: 10,
        maxConcurrent: 1,
        maxMinutesPerRun: 30,
      },
    },
  },
  {
    id: "review-requested",
    title: "When a review is requested, have an agent review the PR",
    summary: "A person asks for a review: an agent reads the diff and comments on the pull request.",
    spec: {
      name: "Review requested pull requests",
      trigger: { type: "github", events: ["review_requested"], repository: "" },
      conditions: [{ path: "pull_request.draft", op: "equals", value: "false" }],
      action: {
        type: "start_agent",
        repo: "",
        ref: "{{event.pull_request.head.ref}}",
        harness: "codex",
        prompt:
          "Review pull request #{{event.pull_request.number}} ({{event.pull_request.title}}) in {{event.repository.full_name}}: {{event.pull_request.html_url}}\n\nRead the diff against {{event.pull_request.base.ref}}, and reply with what would break, what is missing and what to change. Do not push.",
        postBack: "comment",
        openPr: false,
      },
      guardrails: {
        cooldownSeconds: 600,
        maxRunsPerDay: 20,
        maxConcurrent: 2,
        maxMinutesPerRun: 20,
      },
    },
  },
  {
    id: "labeled-issue",
    title: "When an issue is labeled autofix, start an agent and open a PR",
    summary: "Label an issue autofix: an agent works on it and opens a pull request with the fix.",
    spec: {
      name: "Fix issues labeled autofix",
      trigger: { type: "github", events: ["issue_labeled"], repository: "" },
      conditions: [{ path: "label.name", op: "in", value: ["autofix", "agent"] }],
      action: {
        type: "start_agent",
        repo: "",
        ref: "{{event.repository.default_branch}}",
        harness: "claude",
        prompt:
          "Fix issue #{{event.issue.number}} ({{event.issue.title}}) in {{event.repository.full_name}}: {{event.issue.html_url}}\n\nWork on a new branch and end with a summary of the change for the pull request.",
        postBack: "comment",
        openPr: true,
      },
      guardrails: {
        cooldownSeconds: 0,
        maxRunsPerDay: 10,
        maxConcurrent: 2,
        maxMinutesPerRun: 45,
      },
    },
  },
];

const ciSpec: AutocloudSpec = {
  ...structuredClone(MOCK_AUTOCLOUD_TEMPLATES[0]!.spec),
  trigger: { type: "github", events: ["ci_failure"], repository: "acme/web" },
  action: {
    ...structuredClone(MOCK_AUTOCLOUD_TEMPLATES[0]!.spec.action),
    repo: "acme/web",
  },
};

export const MOCK_AUTOCLOUD_RUNS: AutocloudRun[] = [
  {
    id: "run_mock_3",
    status: "failed",
    statusLabel: "Failed",
    tone: "bad",
    eventText: "CI failed on acme/web#42 (fix-login-redirect)",
    whenText: "3 minutes ago",
    minutesText: "12 minutes",
    machine: "cloud-4",
    links: [
      {
        label: "Comment",
        url: "https://github.com/acme/web/pull/42#issuecomment-3",
      },
      { label: "Session", url: "https://cmux.com/runs/run_mock_3" },
    ],
    matchedText: "workflow_run.event equals pull_request · workflow_run.pull_requests.0.number exists",
    errorText: "The agent's push was rejected: the branch moved while it worked.",
  },
  {
    id: "run_mock_2",
    status: "succeeded",
    statusLabel: "Succeeded",
    tone: "good",
    eventText: "CI failed on acme/web#38 (bump-eslint)",
    whenText: "2 hours ago",
    minutesText: "8 minutes",
    machine: "cloud-2",
    links: [
      { label: "Pull request", url: "https://github.com/acme/web/pull/38" },
      { label: "Session", url: "https://cmux.com/runs/run_mock_2" },
    ],
    matchedText: null,
    errorText: null,
  },
  {
    id: "run_mock_1",
    status: "skipped",
    statusLabel: "Skipped",
    tone: "plain",
    eventText: "CI failed on main (push)",
    whenText: "1 day ago",
    minutesText: null,
    machine: null,
    links: [],
    matchedText: "workflow_run.event equals pull_request: the event has push",
    errorText: null,
  },
];

export const MOCK_AUTOCLOUD_CI: AutocloudAutomation = {
  id: "auto_mock_ci",
  name: "Fix CI on pull requests",
  enabled: true,
  revision: 3,
  triggerType: "github",
  triggerText: "GitHub · CI fails · acme/web",
  conditionsText: "Only when workflow_run.event equals pull_request, workflow_run.pull_requests.0.number exists",
  actionText: "Starts Claude Code on acme/web",
  lastRun: MOCK_AUTOCLOUD_RUNS[0]!,
  lastRunText: "Failed 3 minutes ago",
  webhookUrl: null,
  spec: ciSpec,
};

export const MOCK_AUTOCLOUD_DEPLOY: AutocloudAutomation = {
  id: "auto_mock_deploy",
  name: "Investigate failed deploys",
  enabled: true,
  revision: 1,
  triggerType: "webhook",
  triggerText: "Webhook · a signed POST",
  conditionsText: "Only when type equals deploy.failed",
  actionText: "Starts Codex on acme/api",
  lastRun: {
    ...MOCK_AUTOCLOUD_RUNS[1]!,
    id: "run_mock_d1",
    whenText: "yesterday",
  },
  lastRunText: "Succeeded 1 day ago",
  webhookUrl: "https://api.cmux.com/v1/automations/auto_mock_deploy/webhook",
  spec: {
    name: "Investigate failed deploys",
    trigger: { type: "webhook" },
    conditions: [{ path: "type", op: "equals", value: "deploy.failed" }],
    action: {
      type: "start_agent",
      repo: "acme/api",
      ref: "main",
      harness: "codex",
      prompt:
        "The {{event.service}} deploy to {{event.environment}} failed: {{event.url}}\n\nFind why and open a pull request with the fix.",
      postBack: "none",
      openPr: true,
    },
    guardrails: {
      cooldownSeconds: 900,
      maxRunsPerDay: 5,
      maxConcurrent: 1,
      maxMinutesPerRun: 30,
    },
  },
};

export const MOCK_AUTOCLOUD_NIGHTLY: AutocloudAutomation = {
  id: "auto_mock_nightly",
  name: "Weekday dependency check",
  enabled: false,
  revision: 2,
  triggerType: "schedule",
  triggerText: "Schedule · 0 9 * * 1-5 · America/Los_Angeles",
  conditionsText: null,
  actionText: "Starts Claude Code on acme/web",
  lastRun: null,
  lastRunText: "Never ran",
  webhookUrl: null,
  spec: {
    name: "Weekday dependency check",
    trigger: {
      type: "schedule",
      cron: "0 9 * * 1-5",
      timeZone: "America/Los_Angeles",
    },
    conditions: [],
    action: {
      type: "start_agent",
      repo: "acme/web",
      ref: "main",
      harness: "claude",
      prompt: "Check for outdated dependencies with known advisories and open one pull request that updates them.",
      postBack: "none",
      openPr: true,
    },
    guardrails: {
      cooldownSeconds: 0,
      maxRunsPerDay: 1,
      maxConcurrent: 1,
      maxMinutesPerRun: 30,
    },
  },
};

export function mockAutocloudOverview(
  patch: Partial<Extract<AutocloudOverview, { ok: true }>> = {},
): AutocloudOverview {
  return {
    ok: true,
    available: true,
    platform: "https://api.cmux.com",
    team: "acme",
    automations: [MOCK_AUTOCLOUD_CI, MOCK_AUTOCLOUD_DEPLOY, MOCK_AUTOCLOUD_NIGHTLY].map((a) => structuredClone(a)),
    templates: structuredClone(MOCK_AUTOCLOUD_TEMPLATES),
    catalog: structuredClone(MOCK_AUTOCLOUD_CATALOG),
    ...patch,
  };
}

export function mockAutocloudState(overview: AutocloudOverview | null = mockAutocloudOverview()): AutocloudState {
  return { loading: false, problem: null, overview, error: null };
}

// ---- the preview, as cli/autocloud.rs `preview` renders it (a small mirror for the mock only) ----

const SAMPLE_REPOSITORY = {
  full_name: "acme/web",
  name: "web",
  owner: { login: "acme" },
  default_branch: "main",
};
const PR = {
  number: 42,
  title: "Fix the login redirect",
  html_url: "https://github.com/acme/web/pull/42",
  draft: false,
  user: { login: "octocat" },
  head: { ref: "fix-login-redirect" },
  base: { ref: "main" },
};
const SAMPLES: Record<string, unknown> = {
  ci_failure: {
    action: "completed",
    repository: SAMPLE_REPOSITORY,
    sender: { login: "octocat" },
    workflow_run: {
      name: "CI",
      conclusion: "failure",
      head_branch: "fix-login-redirect",
      head_sha: "4f2c9e1",
      html_url: "https://github.com/acme/web/actions/runs/1234",
      event: "pull_request",
      pull_requests: [
        {
          number: 42,
          head: { ref: "fix-login-redirect" },
          base: { ref: "main" },
        },
      ],
    },
  },
  pr_opened: {
    action: "opened",
    repository: SAMPLE_REPOSITORY,
    sender: { login: "octocat" },
    pull_request: PR,
  },
  review_requested: {
    action: "review_requested",
    repository: SAMPLE_REPOSITORY,
    sender: { login: "octocat" },
    requested_reviewer: { login: "cmux-bot" },
    pull_request: PR,
  },
  issue_labeled: {
    action: "labeled",
    repository: SAMPLE_REPOSITORY,
    sender: { login: "octocat" },
    label: { name: "autofix" },
    issue: {
      number: 7,
      title: "Search returns stale results",
      html_url: "https://github.com/acme/web/issues/7",
    },
  },
  pr_comment: {
    action: "created",
    repository: SAMPLE_REPOSITORY,
    comment: { body: "@cmux please fix the flaky test" },
    issue: { number: 42 },
  },
  pr_review_comment: {
    action: "created",
    repository: SAMPLE_REPOSITORY,
    comment: { body: "nit" },
    pull_request: PR,
  },
  push: {
    ref: "refs/heads/main",
    repository: SAMPLE_REPOSITORY,
    head_commit: { id: "4f2c9e1" },
  },
  webhook: {
    type: "deploy.failed",
    service: "api",
    environment: "staging",
    url: "https://deploys.example.com/991",
  },
  schedule: { scheduledAt: "2026-11-24T17:00:00Z" },
};

function lookup(root: unknown, path: string): unknown {
  let at: unknown = root;
  for (const part of path.split(".")) {
    if (at === null || typeof at !== "object") return undefined;
    at = (at as Record<string, unknown>)[part];
  }
  return at;
}

function render(template: string, scope: Record<string, unknown>): [string, string[]] {
  const missing: string[] = [];
  const text = template.replace(/\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}/g, (whole, path: string) => {
    const value = lookup(scope, path);
    if (value === undefined || value === null || typeof value === "object") {
      if (!missing.includes(path)) missing.push(path);
      return whole;
    }
    return String(value);
  });
  return [text, missing];
}

function conditionText(c: AutocloudCondition): string {
  const label = OPS.find(([v]) => v === c.op)?.[1] ?? c.op;
  const value = Array.isArray(c.value) ? c.value.join(", ") : (c.value ?? "");
  return `${c.path} ${label}${value ? ` ${value}` : ""}`.trim();
}

function holds(c: AutocloudCondition, event: unknown): [boolean, string | null] {
  const raw = lookup(event, c.path);
  const actual =
    raw === undefined || raw === null || typeof raw === "object" ? (raw == null ? null : "a value") : String(raw);
  const value = c.value ?? "";
  const list = Array.isArray(value) ? value : value.split(",").map((s) => s.trim());
  switch (c.op) {
    case "exists":
      return [raw !== undefined && raw !== null, actual];
    case "equals":
      return [actual === value, actual];
    case "not_equals":
      return [actual !== value, actual];
    case "contains":
      return [actual !== null && actual.includes(String(value)), actual];
    case "in":
      return [actual !== null && list.includes(actual), actual];
    case "not_in":
      return [actual === null || !list.includes(actual), actual];
    case "prefix":
      return [actual !== null && actual.startsWith(String(value)), actual];
    case "missing":
      return [raw === undefined || raw === null, actual];
    case "gt":
    case "gte":
    case "lt":
    case "lte": {
      const a = Number(actual);
      const w = Number(value);
      if (
        actual === null ||
        actual.trim() === "" ||
        Number.isNaN(a) ||
        String(value).trim() === "" ||
        Number.isNaN(w)
      ) {
        return [false, actual];
      }
      const ok = c.op === "gt" ? a > w : c.op === "gte" ? a >= w : c.op === "lt" ? a < w : a <= w;
      return [ok, actual];
    }
    default:
      return [false, actual];
  }
}

export function mockAutocloudPreview(spec: AutocloudSpec, sample?: string): AutocloudAnswer {
  const kind =
    sample ??
    (spec.trigger.type === "webhook"
      ? "webhook"
      : spec.trigger.type === "schedule"
        ? "schedule"
        : ((spec.trigger as { events?: string[] }).events?.[0] ?? "ci_failure"));
  const event = SAMPLES[kind] ?? SAMPLES.ci_failure;
  const scope = {
    event,
    trigger: spec.trigger,
    run: { url: "https://cmux.com/runs/sample", id: "run_sample" },
  };
  const [ref, missingRef] = render(spec.action.ref, scope);
  const [prompt, missingPrompt] = render(spec.action.prompt, scope);
  const missing = [...new Set([...missingRef, ...missingPrompt])];
  const conditions = spec.conditions.map((c) => {
    const [ok, actual] = holds(c, event);
    return {
      text: conditionText(c),
      holds: ok,
      actualText: actual === null ? "The event has nothing there" : `The event has ${actual}`,
    };
  });
  const matches = conditions.every((c) => c.holds);
  return {
    ok: true,
    sample: kind,
    ref,
    prompt,
    missing,
    missingText: missing.length ? `Nothing in the event for ${missing.map((m) => `{{${m}}}`).join(", ")}` : null,
    conditions,
    matches,
    matchText: matches ? "This event would start the agent" : "This event would be skipped",
  };
}

// ---- the edits ----

function triggerText(spec: AutocloudSpec): string {
  const t = spec.trigger as Record<string, unknown> & { type: string };
  if (t.type === "github") {
    const events = ((t.events as string[] | undefined) ?? [])
      .map((e) => GITHUB_EVENTS.find(([v]) => v === e)?.[1] ?? e)
      .join(", ");
    return `GitHub · ${events} · ${(t.repository as string) || "any repository"}`;
  }
  if (t.type === "webhook") return "Webhook · a signed POST";
  if (t.type === "schedule") return `Schedule · ${String(t.cron ?? "")} · ${String(t.timeZone ?? "UTC")}`;
  const name = t.type.replace(/_/g, " ");
  return name.charAt(0).toUpperCase() + name.slice(1);
}

function viewOf(id: string, spec: AutocloudSpec, enabled: boolean, revision: number): AutocloudAutomation {
  const harness = HARNESSES.find(([v]) => v === spec.action.harness)?.[1] ?? spec.action.harness;
  return {
    id,
    name: spec.name,
    enabled,
    revision,
    triggerType: spec.trigger.type,
    triggerText: triggerText(spec),
    conditionsText: spec.conditions.length ? `Only when ${spec.conditions.map(conditionText).join(", ")}` : null,
    actionText: `Starts ${harness} on ${spec.action.repo}`,
    lastRun: null,
    lastRunText: "Never ran",
    webhookUrl: spec.trigger.type === "webhook" ? `https://api.cmux.com/v1/automations/${id}/webhook` : null,
    spec: structuredClone(spec),
  };
}

function refuse(
  state: AutocloudState,
  action: string,
  message: string,
): { answer: AutocloudAnswer; state: AutocloudState } {
  const error = { code: "cli.invalid_spec", message };
  return {
    answer: { ok: false, error },
    state: { ...state, error: { action, ...error } },
  };
}

/** The mock CLI's answer to one action, and the state the card reads after it. */
export function runMockAutocloud(
  state: AutocloudState,
  run: AutocloudAction,
): { answer: AutocloudAnswer; state: AutocloudState } {
  const overview = state.overview;
  if (run.action === "refresh") return { answer: { ok: true }, state };
  if (run.action === "preview") return { answer: mockAutocloudPreview(run.spec, run.sample), state };
  if (!overview?.ok || !overview.available)
    return {
      answer: {
        ok: false,
        error: {
          code: "host.unavailable",
          message: "Automations are not here yet.",
        },
      },
      state,
    };
  const list = overview.automations;
  const withList = (automations: AutocloudAutomation[]): AutocloudState => ({
    ...state,
    error: null,
    overview: { ...overview, automations },
  });
  switch (run.action) {
    case "runs": {
      const runs = run.id === MOCK_AUTOCLOUD_CI.id ? structuredClone(MOCK_AUTOCLOUD_RUNS) : [];
      return { answer: { ok: true, runs }, state };
    }
    case "toggle": {
      const next = list.map((a) => (a.id === run.id ? { ...a, enabled: run.enabled, revision: a.revision + 1 } : a));
      return { answer: { ok: true }, state: withList(next) };
    }
    case "remove":
      return {
        answer: { ok: true },
        state: withList(list.filter((a) => a.id !== run.id)),
      };
    case "create":
    case "update": {
      if (!run.spec.name.trim()) return refuse(state, run.action, "Name the automation.");
      if (!/^[\w.-]+\/[\w.-]+$/.test(run.spec.action.repo))
        return refuse(state, run.action, "Name the repository as owner/name.");
      if (!run.spec.action.prompt.trim()) return refuse(state, run.action, "Write the prompt the agent starts with.");
      if (run.action === "update") {
        const old = list.find((a) => a.id === run.id);
        if (!old) return refuse(state, run.action, "That automation is gone.");
        const view = {
          ...viewOf(old.id, run.spec, old.enabled, old.revision + 1),
          lastRun: old.lastRun,
          lastRunText: old.lastRunText,
        };
        return {
          answer: { ok: true, automation: view },
          state: withList(list.map((a) => (a.id === old.id ? view : a))),
        };
      }
      const id = `auto_mock_${list.length + 1}`;
      const view = viewOf(id, run.spec, true, 1);
      const answer: AutocloudAnswer = { ok: true, automation: view };
      if (run.spec.trigger.type === "webhook") {
        answer.secret = "whsec_mock_9f3b7c1e2d4a6b8c0e1f";
        answer.secretText =
          "Copy this secret now; it will not show again. Sign each POST: x-cmux-webhook-signature is sha256= and the HMAC-SHA256 of the timestamp, delivery id and body.";
      }
      return { answer, state: withList([...list, view]) };
    }
  }
}
