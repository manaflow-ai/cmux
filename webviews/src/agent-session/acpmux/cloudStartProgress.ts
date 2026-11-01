import type { CloudStartAnswer } from "./cloudRun";

/// A chat starting in Cloud, as the chat shows it (CloudStartView; cloud work mode, leo-workspace
/// design/cloud-work-mode.md): while the host's `cloud.startChat` runs (a new machine boots in
/// minutes), the new chat shows the person's message and how the start goes as metadata under it:
/// the step it is on, the folder it copies, the machine, the secrets the machine gets and its
/// network. Never a sheet or a modal, and no Full Access warning: the chat runs on the machine.
///
/// The page knows the message and the folder from the send. The rest comes from the host as it
/// learns it (`cloudStartProgress` on the page bridge, keyed by the start's `key`), the folder too
/// when the send named none (the host copies the tab's own); a host that sends none leaves the card
/// at "Starting in Cloud". A start that succeeds closes
/// this tab (the chat is the machine's), so the card has no done state; a failure shows the host's
/// words, and the message stays in the composer for another send.

/// Where a start is, in order: a machine taken or booted, the folder copied, the chat opened.
export const CLOUD_START_STEPS = ["machine", "folder", "opening"] as const;
export type CloudStartStep = (typeof CLOUD_START_STEPS)[number];

export type CloudStartProgress = {
  /// The start's key (`cloud.startChat {key}`): a push for another start is dropped.
  key: string;
  /// The person's message.
  task: string;
  state: "starting" | "failed";
  /// The folder's name (its last path part).
  folder?: string;
  step?: CloudStartStep;
  /// The machine's name, and its size as the host words it ("4 CPU, 16 GB").
  machine?: string;
  size?: string;
  /// How many of the account's secrets the machine gets.
  secrets?: number;
  /// The machine's network: the open internet, or only what its policy allows.
  network?: "full" | "limited";
  /// A failure's words, the host's own.
  message?: string;
  /// The agent the chat starts, by name ("Claude Code"), for the opening step.
  agent?: string;
  /// No project: nothing is copied, so the card shows no copy step.
  home?: boolean;
  /// A repository was selected for this chat. `false` is explicit: the clone step is skipped.
  hasRepository?: boolean;
  repository?: string;
  /// The environment whose setup status is being reported by cmux-platform.
  environmentId?: string;
  /// Client-side timing for the machine and harness phases. Milliseconds since epoch.
  machineStartedAt?: number;
  machineFinishedAt?: number;
  harnessStartedAt?: number;
  harnessFinishedAt?: number;
  /// The git-seed status, forwarded from `git.seed.status`.
  clone?: CloudStartupOperation;
  /// The derived environment setup status, forwarded from GET /v1/environments/{id}.
  setup?: CloudStartupSetup;
  /// True after the harness has started. The checklist stays available but folds to one quiet line.
  initialized?: boolean;
};

export type CloudStartupOperation = {
  state: "pending" | "running" | "done" | "failed";
  startedAt?: number;
  finishedAt?: number;
  error?: string;
  phase?: string;
  progress?: {
    receivedBytes?: number;
    objects?: number;
    totalObjects?: number;
  };
};

export type CloudStartupSetup = {
  state: "pending" | "running" | "done" | "failed" | "skipped";
  startedAt?: number;
  finishedAt?: number;
  error?: string;
  /// `ready` means the setup snapshot is cached; `building` is still running.
  status?: "ready" | "building" | "failed";
  logTail?: string;
  hasScript?: boolean;
};

/// The start the page just sent: the message, and the folder by its name.
export function cloudStartBegun(
  key: string,
  task: string,
  cwd: string | undefined,
  agent?: string,
  home?: boolean,
): CloudStartProgress {
  const folder = cwd?.replace(/\/+$/, "").split("/").pop();
  return {
    key,
    task,
    state: "starting",
    ...(folder ? { folder } : {}),
    ...(agent ? { agent } : {}),
    ...(home ? { home: true } : {}),
  };
}

/// Text the card shows from the host: one line, at most `max` characters.
function line(value: unknown, max: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const text = value.replace(/\s+/g, " ").trim();
  return text ? (text.length > max ? `${text.slice(0, max - 1)}…` : text) : undefined;
}

function logLine(value: unknown, max: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const text = value.trim();
  return text ? (text.length > max ? `${text.slice(0, max - 1)}…` : text) : undefined;
}

/// `current` with the host's push `push` taken in: only for the same start while it runs, field by
/// field, each checked (anything else in it is ignored). A step never goes back.
export function cloudStartPushed(
  current: CloudStartProgress | undefined,
  push: unknown,
): CloudStartProgress | undefined {
  if (!current || current.state !== "starting" || typeof push !== "object" || push === null) return current;
  const fields = push as Record<string, unknown>;
  if (fields.key !== current.key) return current;
  const next = { ...current };
  const step = CLOUD_START_STEPS.indexOf(fields.step as CloudStartStep);
  if (step >= 0 && step >= (current.step ? CLOUD_START_STEPS.indexOf(current.step) : -1))
    next.step = CLOUD_START_STEPS[step];
  if (fields.initialized === true || fields.harnessStarted === true || fields.harness_started === true) {
    next.initialized = true;
  }
  if (fields.initialized === false) next.initialized = false;
  if (typeof fields.hasRepository === "boolean") next.hasRepository = fields.hasRepository;
  if (typeof fields.has_repo === "boolean") next.hasRepository = fields.has_repo;
  const repository = line(fields.repository ?? fields.repo, 160);
  if (repository) {
    next.repository = repository;
    next.hasRepository = true;
  }
  const environmentId = line(fields.environmentId ?? fields.environment_id, 128);
  if (environmentId) next.environmentId = environmentId;
  const directMachineStarted = number(fields.machineStartedAt ?? fields.machine_started_at);
  const directMachineFinished = number(fields.machineFinishedAt ?? fields.machine_finished_at);
  const directHarnessStarted = number(fields.harnessStartedAt ?? fields.harness_started_at);
  const directHarnessFinished = number(fields.harnessFinishedAt ?? fields.harness_finished_at);
  if (directMachineStarted !== undefined) next.machineStartedAt = directMachineStarted;
  if (directMachineFinished !== undefined) next.machineFinishedAt = directMachineFinished;
  if (directHarnessStarted !== undefined) next.harnessStartedAt = directHarnessStarted;
  if (directHarnessFinished !== undefined) next.harnessFinishedAt = directHarnessFinished;
  const folder = line(fields.folder, 64);
  if (folder && !folder.includes("/")) next.folder = folder;
  const machine = line(fields.machine, 64);
  if (machine) next.machine = machine;
  const size = line(fields.size, 32);
  if (size) next.size = size;
  if (typeof fields.secrets === "number" && Number.isSafeInteger(fields.secrets) && fields.secrets >= 0)
    next.secrets = fields.secrets;
  if (fields.network === "full" || fields.network === "limited") next.network = fields.network;
  const timings = asRecord(fields.timings);
  if (timings) {
    const machineTiming = timing(timings.machine);
    const harnessTiming = timing(timings.harness);
    if (machineTiming) Object.assign(next, prefixedTiming("machine", machineTiming));
    if (harnessTiming) Object.assign(next, prefixedTiming("harness", harnessTiming));
  }
  const clone = operation(fields.clone ?? fields.gitSeed ?? fields.seed ?? fields["git.seed"]);
  if (clone) next.clone = clone;
  const setup = setupStatus(fields.setup ?? fields.environment);
  if (setup) next.setup = setup;
  return next;
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function number(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;
}

function timing(value: unknown): { startedAt?: number; finishedAt?: number } | undefined {
  const record = asRecord(value);
  if (!record) return undefined;
  const startedAt = number(record.startedAt ?? record.started_at);
  const finishedAt = number(record.finishedAt ?? record.finished_at);
  return startedAt === undefined && finishedAt === undefined
    ? undefined
    : { ...(startedAt !== undefined && { startedAt }), ...(finishedAt !== undefined && { finishedAt }) };
}

function prefixedTiming(
  prefix: "machine" | "harness",
  value: { startedAt?: number; finishedAt?: number },
): Record<string, number> {
  return {
    ...(value.startedAt !== undefined && { [`${prefix}StartedAt`]: value.startedAt }),
    ...(value.finishedAt !== undefined && { [`${prefix}FinishedAt`]: value.finishedAt }),
  } as Record<string, number>;
}

function operation(value: unknown): CloudStartupOperation | undefined {
  const record = asRecord(value);
  if (!record) return undefined;
  const raw = record.state ?? record.status;
  const state =
    raw === "done" || raw === "complete"
      ? "done"
      : raw === "failed" || raw === "error"
        ? "failed"
        : raw === "running"
          ? "running"
          : raw === "pending"
            ? "pending"
            : undefined;
  if (!state) return undefined;
  const startedAt = number(record.startedAt ?? record.started_at);
  const finishedAt = number(record.finishedAt ?? record.finished_at);
  const error = line(record.error ?? record.message, 240);
  const phase = line(record.phase, 80);
  const progressRecord = asRecord(record.progress);
  const receivedBytes = number(progressRecord?.receivedBytes ?? progressRecord?.received_bytes);
  const objects = number(progressRecord?.objects);
  const totalObjects = number(progressRecord?.totalObjects ?? progressRecord?.total_objects);
  const progress = progressRecord
    ? {
        ...(receivedBytes !== undefined && { receivedBytes }),
        ...(objects !== undefined && { objects }),
        ...(totalObjects !== undefined && { totalObjects }),
      }
    : undefined;
  return {
    state,
    ...(startedAt !== undefined && { startedAt }),
    ...(finishedAt !== undefined && { finishedAt }),
    ...(error && { error }),
    ...(phase && { phase }),
    ...(progress && Object.keys(progress).length > 0 && { progress }),
  };
}

function setupStatus(value: unknown): CloudStartupSetup | undefined {
  const record = asRecord(value);
  if (!record) return undefined;
  // The platform endpoint reports phase timings under `steps.install`; hosts may forward that
  // object as-is so the page does not need to know the rest of the environment response.
  const steps = asRecord(record.steps);
  const install = steps && (steps.install ?? steps.setup ?? steps.run);
  if (install && asRecord(install)) {
    const merged = { ...record };
    delete merged.steps;
    Object.assign(merged, asRecord(install));
    if (record.status !== undefined) merged.status = record.status;
    return setupStatus(merged);
  }
  const raw = record.status ?? record.state;
  const status = raw === "ready" || raw === "building" || raw === "failed" ? raw : undefined;
  const base = operation({
    ...record,
    state:
      status === "ready" ? "done" : status === "building" ? "running" : status === "failed" ? "failed" : record.state,
  });
  if (!base && raw !== "skipped") return undefined;
  const startedAt = number(record.startedAt ?? record.started_at);
  const finishedAt = number(record.finishedAt ?? record.finished_at);
  const hasScript =
    typeof record.hasScript === "boolean"
      ? record.hasScript
      : typeof record.has_script === "boolean"
        ? record.has_script
        : undefined;
  const logTail = logLine(record.logTail ?? record.log_tail, 1200);
  return {
    ...(base ?? { state: "skipped" as const }),
    ...(status && { status }),
    ...(startedAt !== undefined && { startedAt }),
    ...(finishedAt !== undefined && { finishedAt }),
    ...(hasScript !== undefined && { hasScript }),
    ...(logTail && { logTail }),
  };
}

/// `current` once the host answered start `key`: none when the chat opened on the machine (this tab
/// closes), failed with the host's words when it didn't. Another start's answer changes nothing.
export function cloudStartEnded(
  current: CloudStartProgress | undefined,
  key: string,
  answer: CloudStartAnswer,
): CloudStartProgress | undefined {
  if (current?.key !== key) return current;
  if (answer.ok) return undefined;
  const message = line(answer.message, 240);
  return { ...current, state: "failed", ...(message ? { message } : {}) };
}
