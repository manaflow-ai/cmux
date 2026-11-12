import type { CloudStartAnswer } from "./cloudRun";
import { cloudPlanTeamRefusal, type CloudPlanTeamRefusal } from "./cloudPlanTeams";
import { translate } from "./i18n";
import { errorMessage } from "./transportErrors";
import { sliceWhole } from "../../ui/wholeChars";

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
  /// A stable host refusal code, used to attach recovery to the matching failure.
  code?: string;
  /// A plan refusal in a team (`cloud_plan_required` with the host's teams): the card says "This team
  /// has no Cloud plan", names the team and offers the person's own (cloudPlanTeams.ts).
  planTeam?: CloudPlanTeamRefusal;
  /// The start waits on the person's browser sign-in (`cloud.signIn`): the card says so, not "starting".
  signingIn?: true;
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
  /// A question the start waits on, shown in the card (CloudStartAsk.tsx): the host's words and buttons.
  ask?: CloudStartAsk;
  /// A failure another try of the same start can help: the card offers Retry.
  retryable?: boolean;
  /// This Mac's pane refused the start before it reached Cloud (a `transport.*` code: a folder that
  /// is not the tab's own, a Send without a gesture): no step ran, so the checklist marks none failed.
  refusedHere?: boolean;
  /// The host has said nothing about this start for CLOUD_START_STALL_MS (no push, no answer) while
  /// nothing waits on the person: the card says so. The composer is open throughout a start and what
  /// is typed moves to the chat as a draft. It holds until the start ends.
  stalled?: true;
  /// A folder too big to copy that is not a git repository (`cloud_folder_too_big`, the host's check before
  /// any machine): the card says why and offers the repositories inside it, another folder or none.
  tooBig?: CloudFolderTooBig;
};

/// The host's `cloud_folder_too_big` details (CloudMoveCLI.StartChatPreflightRefusal `details`).
export type CloudFolderTooBig = {
  /// The folder as the person reads it (`~/Projects`).
  folder: string;
  /// The git working copies right inside it, by name below it (`cmux`, `work/api`), each a one-click start.
  repos: { name: string; path: string }[];
  /// More repositories than `repos` names.
  more: boolean;
};

/// The most repositories the card offers, as the host bounds them (cmux-tui `preflight::MAX_REPOS`).
const MAX_TOO_BIG_REPOS = 24;

/// The host's details of a `cloud_folder_too_big`, each field checked; the card's words for it.
export function cloudFolderTooBig(details: unknown): { tooBig: CloudFolderTooBig; message: string } {
  const record = asRecord(details) ?? {};
  const folder = typeof record.folder === "string" && record.folder ? sliceWhole(record.folder, 160) : "";
  const repos = (Array.isArray(record.repos) ? record.repos : [])
    .map((repo) => asRecord(repo))
    .filter(
      (repo): repo is Record<string, unknown> =>
        Boolean(repo) &&
        typeof repo?.name === "string" &&
        repo.name.length > 0 &&
        typeof repo.path === "string" &&
        repo.path.startsWith("/"),
    )
    .slice(0, MAX_TOO_BIG_REPOS)
    .map((repo) => ({ name: sliceWhole(repo.name as string, 120), path: repo.path as string }));
  const bytes = number(record.bytes);
  const files = number(record.files);
  const size =
    bytes !== undefined && files !== undefined
      ? translate("cloudStartup.folderSize", { size: folderSizeText(bytes), files: files.toLocaleString() })
      : bytes !== undefined
        ? folderSizeText(bytes)
        : "?";
  const named = folder || "~";
  const message = repos.length
    ? translate("cloudStartup.folderTooBigRepos", { folder: named, size })
    : translate("cloudStartup.folderTooBig", { folder: named, size });
  return {
    tooBig: { folder: named, repos, more: record.more === true },
    message,
  };
}

/// `bytes` as the copy's limit words it (cmux-tui size_cap `size`): GB of 1024³, one decimal under 100 GB; MB under 1 GB.
export function folderSizeText(bytes: number): string {
  const gb = 1024 ** 3;
  if (bytes >= 100 * gb) return `${Math.round(bytes / gb)} GB`;
  if (bytes >= gb) return `${(Math.round((bytes / gb) * 10) / 10).toString()} GB`;
  return `${Math.round(bytes / 1024 ** 2)} MB`;
}

/// What a start asks (AgentPaneCloudAsk): its first Claude login, the one-time login copy consent, Codex's
/// Mac sign-in consent, Codex's device code. The host words it; the card draws it and answers with the
/// clicked button's id (`cloud.answerStart`). One filled button at most; a page to open is a link.
export type CloudStartAskKind = "firstLogin" | "loginCopy" | "codexDevice" | "codexConsent";
export type CloudStartAskButton = { id: string; title: string; role: "default" | "cancel" | "normal" };
export type CloudStartAsk = {
  id: string;
  kind: CloudStartAskKind;
  title: string;
  lines: string[];
  buttons: CloudStartAskButton[];
  /// A one-time code the card shows with Copy.
  code?: string;
  link?: { url: string; title: string };
};

const ASK_KINDS = new Set<CloudStartAskKind>(["firstLogin", "loginCopy", "codexDevice", "codexConsent"]);

/// The host's `ask`, each field checked; undefined for anything malformed.
export function cloudStartAsk(value: unknown): CloudStartAsk | undefined {
  const record = asRecord(value);
  if (!record || typeof record.id !== "string" || !record.id || record.id.length > 64) return undefined;
  if (!ASK_KINDS.has(record.kind as CloudStartAskKind)) return undefined;
  const title = line(record.title, 160);
  if (!title || !Array.isArray(record.lines) || !Array.isArray(record.buttons)) return undefined;
  const lines = record.lines.slice(0, 6).flatMap((text) => line(text, 400) ?? []);
  const buttons = record.buttons.slice(0, 4).flatMap((raw): CloudStartAskButton[] => {
    const button = asRecord(raw);
    const label = line(button?.title, 40);
    const role = button?.role === "default" || button?.role === "cancel" ? button.role : "normal";
    return button && typeof button.id === "string" && button.id && button.id.length <= 64 && label
      ? [{ id: button.id, title: label, role }]
      : [];
  });
  if (buttons.length === 0) return undefined;
  const code = line(record.code, 32);
  const linkRecord = asRecord(record.link);
  const url = httpsUrl(linkRecord?.url);
  const linkTitle = line(linkRecord?.title, 40);
  return {
    id: record.id,
    kind: record.kind as CloudStartAskKind,
    title,
    lines,
    buttons,
    ...(code ? { code } : {}),
    ...(url && linkTitle ? { link: { url, title: linkTitle } } : {}),
  };
}

export type CloudStartupOperation = {
  state: "pending" | "running" | "done" | "failed";
  startedAt?: number;
  finishedAt?: number;
  error?: string;
  phase?: string;
  /// A seed that copied the folder instead: the reason's code (`not_git`, `seed.needs_github`, ...).
  fallback?: string;
  /// The cmux GitHub App's install page, when the machine could not read a private repository.
  installUrl?: string;
  progress?: {
    receivedBytes?: number;
    objects?: number;
    totalObjects?: number;
    /// The upload's or the copy's whole size, beside `receivedBytes` done.
    bytesTotal?: number;
    /// The copy's files done and in all.
    filesDone?: number;
    filesTotal?: number;
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
  signingIn?: boolean,
): CloudStartProgress {
  const folder = cwd?.replace(/\/+$/, "").split("/").pop();
  return {
    key,
    task,
    state: "starting",
    ...(folder ? { folder } : {}),
    ...(agent ? { agent } : {}),
    ...(home ? { home: true } : {}),
    ...(signingIn ? { signingIn: true } : {}),
  };
}

/// Start `key`'s sign-in came back signed in and the start goes on: the card leaves its waiting for
/// sign-in state for the normal start. Another start, or one not waiting on a sign-in, is unchanged.
export function cloudStartSignedIn(
  current: CloudStartProgress | undefined,
  key: string,
): CloudStartProgress | undefined {
  if (current?.key !== key || !current.signingIn) return current;
  const { signingIn: _signedIn, ...started } = current;
  return started;
}

/// Text the card shows from the host: one line, at most `max` characters.
function line(value: unknown, max: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const text = value.replace(/\s+/g, " ").trim();
  return text ? (text.length > max ? `${sliceWhole(text, max - 1)}…` : text) : undefined;
}

function logLine(value: unknown, max: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const text = value.trim();
  return text ? (text.length > max ? `${sliceWhole(text, max - 1)}…` : text) : undefined;
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
  // A stalled start stays stalled until it ends; the steps still move.
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
  // The copy's final answer does not repeat why a seed copied: its live lines said so, and it stays.
  const ended = clone?.state === "done" || clone?.state === "failed";
  if (clone) next.clone = ended ? { ...pick(next.clone, ["fallback", "installUrl"]), ...clone } : clone;
  const setup = setupStatus(fields.setup ?? fields.environment);
  if (setup) next.setup = setup;
  // The host's question: `null` takes it away (answered, or the wait ended); a malformed one changes nothing.
  if (fields.ask === null) delete next.ask;
  else {
    const ask = cloudStartAsk(fields.ask);
    if (ask) next.ask = ask;
  }
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

/** An `https:` address, else undefined; the card links to it. */
function httpsUrl(value: unknown): string | undefined {
  if (typeof value !== "string" || value.length > 2048) return undefined;
  try {
    return new URL(value).protocol === "https:" ? value : undefined;
  } catch {
    return undefined;
  }
}

/** The named fields of `value` that are set. */
function pick<T extends object, K extends keyof T>(value: T | undefined, keys: readonly K[]): Partial<Pick<T, K>> {
  const picked: Partial<Pick<T, K>> = {};
  for (const key of keys) if (value?.[key] !== undefined) picked[key] = value[key];
  return picked;
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
  const bytesTotal = number(progressRecord?.bytesTotal ?? progressRecord?.bytes_total);
  const filesDone = number(progressRecord?.filesDone ?? progressRecord?.files_done);
  const filesTotal = number(progressRecord?.filesTotal ?? progressRecord?.files_total);
  const progress = progressRecord
    ? {
        ...(receivedBytes !== undefined && { receivedBytes }),
        ...(objects !== undefined && { objects }),
        ...(totalObjects !== undefined && { totalObjects }),
        ...(bytesTotal !== undefined && { bytesTotal }),
        ...(filesDone !== undefined && { filesDone }),
        ...(filesTotal !== undefined && { filesTotal }),
      }
    : undefined;
  const fallback = line(record.fallback, 80);
  const installUrl = httpsUrl(record.installUrl ?? record.install_url);
  return {
    state,
    ...(startedAt !== undefined && { startedAt }),
    ...(finishedAt !== undefined && { finishedAt }),
    ...(error && { error }),
    ...(phase && { phase }),
    ...(fallback && { fallback }),
    ...(installUrl && { installUrl }),
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
  // The pane's own refusal (AgentPaneCloudStart: the folder check, the gesture) is worded by its
  // code, never the host's generic "The app refused the agent connection." (cloudRefusalText).
  const refusedHere = answer.code.startsWith("transport.") || REFUSED_HERE.has(answer.code);
  // The team's spending cap or the member's own budget refused the machine's start (cmux-platform SpendCap.ts):
  // the host passes the backend's words, which name it; the card says it in the person's language, with
  // Run on This Mac (CloudStartView), since another try fails the same way until an admin raises it.
  const spend = refusedHere ? undefined : spendRefusal(answer.code, answer.message);
  if (spend) {
    const { signingIn: _s, ask: _a, retryable: _r, ...rest } = current;
    return { ...rest, state: "failed", code: spend, message: translate(SPEND_WORDS[spend]) };
  }
  // A folder too big to copy (the host's check before any machine): no step ran, no Retry, the folder's way on instead.
  if (answer.code === "cloud_folder_too_big") {
    const { signingIn: _s, ask: _a, retryable: _r, planTeam: _p, stalled: _st, ...rest } = current;
    const tooBig = cloudFolderTooBig(answer.details);
    return {
      ...rest,
      state: "failed",
      code: answer.code,
      message: tooBig.message,
      tooBig: tooBig.tooBig,
      refusedHere: true,
    };
  }
  const message = refusedHere ? cloudRefusalText(answer.code, answer.message) : line(answer.message, 240);
  // A failed start waits on no sign-in (its card offers the sign in again instead) and asks nothing more.
  const { signingIn: _signingIn, ask: _ask, planTeam: _planTeam, stalled: _stalled, ...ended } = current;
  const planTeam = answer.code === "cloud_plan_required" ? cloudPlanTeamRefusal(answer.details) : undefined;
  return {
    ...ended,
    state: "failed",
    code: answer.code,
    ...(message ? { message } : {}),
    ...(refusedHere ? { refusedHere } : {}),
    ...(answer.retryable ? { retryable: true } : {}),
    ...(planTeam ? { planTeam } : {}),
  };
}

/// The words for a Cloud start this Mac's pane refused: a folder that is not one of the tab's own
/// asks the person to pick it (a pick grants it, `workspace.useFolder`); a folder that is gone, home
/// or above it, or a credential folder each says so (AgentPaneCloudFolderRefusal; the secret's host
/// words are its `~/` spelling); any other `transport.*` code reads as the pane's refusal text
/// (transportErrors.ts).
export function cloudRefusalText(code: string, hostWords?: string): string {
  if (code === "transport.path_outside_roots") return translate("cloudStartup.folderNotOpen");
  if (code === "cloud_folder_missing") return translate("cloudStartup.folderMissing");
  if (code === "cloud_folder_home") return translate("cloudStartup.folderHome");
  if (code === "cloud_folder_secret")
    return translate("cloudStartup.folderSecret", { folder: line(hostWords, 120) ?? "~" });
  if (code === "cloud_team_switching") return translate("cloudStart.planTeam.switching");
  // The host's "not now": a chat is starting or opening in this tab (AgentPaneHandOff), said as such.
  if (code === "unavailable_now") return translate("cloudStart.chatStartingHere");
  if (code.startsWith("transport.")) return errorMessage({ code });
  // The attachment refusal's words are the host's own sentence; the others carry only their code.
  if (code === "cloud_attachments")
    return line(hostWords, 240) ?? translate("composer.offloadNotRun", { action: translate("composer.cloud") });
  return translate("composer.offloadNotRun", { action: translate("composer.cloud") });
}

/// A Cloud start the team's spending cap (`cloud.spend_cap.reached`) or the member's monthly budget
/// (`cloud.member_budget.reached`) refused, read from the host's code or the backend's words it passes on
/// ("this team has spent … of its … spending cap; an admin can raise it").
const SPEND_CAP =
  /\bcloud\.spend_cap\.reached\b|\bspend_cap_reached\b|\bspent [^;]*? of its [^;]*? spending cap\b|\breached its spending cap\b/i;
const MEMBER_BUDGET =
  /\bcloud\.member_budget\.reached\b|\bmember_budget_reached\b|\bspent [^;]*? of your [^;]*? monthly budget\b/i;
export type SpendRefusalCode = "cloud_spend_cap" | "cloud_member_budget";
const SPEND_WORDS = {
  cloud_spend_cap: "cloudStart.spendCap",
  cloud_member_budget: "cloudStart.memberBudget",
} as const;

export function spendRefusal(code: string, message?: string): SpendRefusalCode | undefined {
  const words = `${code} ${message ?? ""}`;
  if (SPEND_CAP.test(words)) return "cloud_spend_cap";
  if (MEMBER_BUDGET.test(words)) return "cloud_member_budget";
  return undefined;
}

/// The codes the pane refuses a Cloud start with before it reaches Cloud, besides `transport.*`
/// (AgentPaneHandOff.refusedHereCodes, the same list): no step ran, so none is marked failed.
const REFUSED_HERE = new Set([
  "cloud_attachments",
  "unsupported",
  "unavailable_now",
  "sandbox_busy",
  "sandbox_spent",
  "cloud_folder_missing",
  "cloud_folder_home",
  "cloud_folder_secret",
  "cloud_team_switching",
]);

/// How long a start may go with no word from the host (no progress push, no answer) before the card
/// says it stalled. Nothing on the host bounds a whole start
/// (CloudStartChat `reply`: a Codex sign-in broker, the approvals prep and a tab open's hand-off wait
/// have no deadline, and each CLI step may take 30 minutes), so without this a start that never
/// answers showed "Starting in Cloud" for good.
/// A folder copy pushes about 4 lines a second; a new machine's boot says nothing for up to its 180 s
/// link wait (CloudStartSession.connectWait) after its create, so this is longer than that.
export const CLOUD_START_STALL_MS = 5 * 60_000;

/// Start `key` had no word from the host for CLOUD_START_STALL_MS: stalled, unless it waits on the
/// person (a question in the card, a browser sign-in), already ended, or is another start.
export function cloudStartStalled(
  current: CloudStartProgress | undefined,
  key: string,
): CloudStartProgress | undefined {
  if (!current || current.key !== key || !cloudStartMayStall(current)) return current;
  return { ...current, stalled: true };
}

/// Whether `start` is out with nothing waiting on the person, so silence from the host counts.
function cloudStartMayStall(start: CloudStartProgress): boolean {
  return start.state === "starting" && !start.stalled && !start.ask && !start.signingIn;
}

/// Arms the stall timer for `start` as it is now: `stall(key)` runs once after `ms` with no newer
/// state (each push makes a new `start`, and the caller disarms the old timer). Returns the disarm.
export function watchCloudStartStall(
  start: CloudStartProgress | undefined,
  stall: (key: string) => void,
  ms: number = CLOUD_START_STALL_MS,
  schedule: (run: () => void, ms: number) => () => void = (run, after) => {
    const timer = setTimeout(run, after);
    return () => clearTimeout(timer);
  },
): () => void {
  if (!start || !cloudStartMayStall(start)) return () => undefined;
  const key = start.key;
  return schedule(() => stall(key), ms);
}
