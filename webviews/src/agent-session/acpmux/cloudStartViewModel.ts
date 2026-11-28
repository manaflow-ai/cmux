import {
  CLOUD_START_STEPS,
  type CloudStartProgress,
  type CloudStartupOperation,
  type CloudStartupSetup,
} from "./cloudStartProgress";
import { fileSizeLabel } from "./fileAttachmentModel";
import { githubFolderRepo } from "./githubRepos";
import { paneLanguage, type StringKey, type Translate } from "./i18n";

type ChecklistStatus = "done" | "running" | "pending" | "skipped" | "error";
export type ChecklistStep = {
  id: "machine" | "clone" | "setup" | "harness";
  label: string;
  status: ChecklistStatus;
  duration?: string;
  detail?: string;
  logTail?: string;
  action?: boolean;
  link?: { href: string; label: string };
};

/// A Cloud start step's clock: whole seconds under a minute ("42s"), then minutes and seconds
/// ("1:05"), then hours ("1:02:03"). Rounded down, so it never reads more than has passed
/// (Austin, 2026-11-24: "show the seconds", in place of how long a step usually takes).
export function stageClock(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000));
  if (total < 60) return `${total}s`;
  const s = String(total % 60).padStart(2, "0");
  const minutes = Math.floor(total / 60);
  if (minutes < 60) return `${minutes}:${s}`;
  return `${Math.floor(minutes / 60)}:${String(minutes % 60).padStart(2, "0")}:${s}`;
}

function elapsed(startedAt: number | undefined, finishedAt: number | undefined, now = Date.now()): string | undefined {
  if (startedAt === undefined) return undefined;
  const ms = Math.max(0, (finishedAt ?? now) - startedAt);
  // A step under a second reads "0s", never "<1s", like the turn's Working for (#60596).
  return stageClock(ms);
}

function operationStatus(operation: CloudStartupOperation | undefined): ChecklistStatus | undefined {
  if (!operation) return undefined;
  return operation.state === "done"
    ? "done"
    : operation.state === "failed"
      ? "error"
      : operation.state === "running"
        ? "running"
        : "pending";
}

function setupStatus(setup: CloudStartupSetup | undefined): ChecklistStatus | undefined {
  if (!setup) return undefined;
  if (setup.state === "skipped") return "skipped";
  if (setup.status === "ready" || setup.state === "done") return "done";
  if (setup.status === "failed" || setup.state === "failed") return "error";
  if (setup.status === "building" || setup.state === "running") return "running";
  return "pending";
}

/** Words for a seed's phase (cmux-tui `link/seed_cli.rs`); any other phase shows as it came. */
const PHASE_KEYS: Record<string, StringKey> = {
  clone: "cloudStartup.phase.clone",
  fetch: "cloudStartup.phase.fetch",
  bundle: "cloudStartup.phase.bundle",
  checkout: "cloudStartup.phase.checkout",
  submodules: "cloudStartup.phase.submodules",
  lfs: "cloudStartup.phase.lfs",
  // A copy's steps before its first file (cmux-tui `link/sync_cli.rs`).
  prepare: "cloudStartup.phase.prepare",
  folders: "cloudStartup.phase.folders",
};

/** Why a seed copied the folder instead, by its `fallback_code` (cmux-tui `link/seed/plan.rs`, `link/seed_cli.rs`). */
const FALLBACK_KEYS: Record<string, StringKey> = {
  not_git: "cloudStartup.because.notGit",
  no_remote: "cloudStartup.because.noRemote",
  ambiguous_remote: "cloudStartup.because.noRemote",
  not_github: "cloudStartup.because.notGithub",
  no_base: "cloudStartup.because.noBase",
  unmerged: "cloudStartup.because.unmerged",
  submodule_local_work: "cloudStartup.because.submodule",
  "seed.needs_github": "cloudStartup.because.needsGithub",
  "seed.base_missing": "cloudStartup.because.noBase",
  "seed.clone_failed": "cloudStartup.because.cloneFailed",
  machine_outdated: "cloudStartup.because.machineOutdated",
  "seed.unavailable": "cloudStartup.because.machineOutdated",
};

/** "Copying the folder instead", with why in plain words when the code is one the card knows. */
function copyInstead(fallback: string, t: Translate): string {
  const reason = FALLBACK_KEYS[fallback];
  return reason ? t("cloudStartup.copyInsteadBecause", { reason: t(reason) }) : t("cloudStartup.copyInstead");
}

function cloneDetail(operation: CloudStartupOperation | undefined, t: Translate, language: string): string | undefined {
  if (!operation) return undefined;
  const progress = operation.progress;
  const size = (bytes: number | undefined) => fileSizeLabel(bytes, language);
  const parts: (string | undefined)[] = [];
  if (operation.phase === "cached") parts.push(t("cloudStartup.cached"));
  else if (operation.phase === "complete") {
    // The row's check mark says it finished; only a seed that copied instead says so.
    if (operation.fallback) parts.push(copyInstead(operation.fallback, t));
  } else if (operation.phase === "copy" || progress?.filesTotal !== undefined) {
    // The streamed copy: files, then bytes.
    if (operation.fallback) parts.push(copyInstead(operation.fallback, t));
    if (progress?.filesTotal !== undefined)
      parts.push(
        t("cloudStartup.copyingFiles", {
          done: (progress.filesDone ?? 0).toLocaleString(language),
          total: progress.filesTotal.toLocaleString(language),
        }),
      );
    if (progress?.receivedBytes !== undefined && progress.bytesTotal !== undefined)
      parts.push(
        t("cloudStartup.ofSize", { done: size(progress.receivedBytes) ?? "", total: size(progress.bytesTotal) ?? "" }),
      );
  } else if (operation.phase === "upload") {
    parts.push(t("cloudStartup.phase.upload", { size: size(progress?.bytesTotal ?? progress?.receivedBytes) ?? "" }));
  } else {
    // A copy's steps before its files keep saying why it copies.
    if (operation.fallback) parts.push(copyInstead(operation.fallback, t));
    const key = operation.phase ? PHASE_KEYS[operation.phase] : undefined;
    parts.push(key ? t(key) : operation.phase);
    const total = progress?.totalObjects;
    if (progress?.objects !== undefined && total)
      parts.push(`${Math.min(100, Math.floor((progress.objects / total) * 100))}%`);
    else if (progress?.receivedBytes) parts.push(size(progress.receivedBytes));
  }
  // A first pass of a very large folder: the files it left here, so the copy does not read as complete.
  if (operation.leftOnMac)
    parts.push(
      t("cloudStartup.leftOnMac", { n: operation.leftOnMac, count: operation.leftOnMac.toLocaleString(language) }),
    );
  return parts.filter(Boolean).join(" · ") || operation.error;
}

const DEFAULT_STARTUP_STRINGS: Record<string, string> = {
  "cloudStartup.machine": "Set up a Cloud machine",
  "cloudStartup.waking": "Waking machine",
  "cloudStartup.clone": "Clone repository",
  "cloudStartup.setup": "Run setup script",
  "cloudStartup.setupHint": "Add a setup script to install dependencies and configure your environment.",
  "cloudStartup.cached": "cached",
  "cloudStartup.harness": "Started {harness}",
  "cloudStartup.harnessStarting": "Starting {harness}",
  "cloudStartup.copyInstead": "Copying the folder instead",
  "cloudStartup.copyInsteadBecause": "Copying the folder instead, because {reason}",
  "cloudStartup.because.notGit": "it is not a git repository",
  "cloudStartup.because.noRemote": "its repository has no remote to clone from",
  "cloudStartup.because.notGithub": "its remote is not on GitHub",
  "cloudStartup.because.noBase": "none of its commits are on GitHub",
  "cloudStartup.because.unmerged": "it has unresolved merge conflicts",
  "cloudStartup.because.submodule": "a submodule is at a commit that is not on GitHub",
  "cloudStartup.because.needsGithub": "the Cloud machine can't read the repository",
  "cloudStartup.because.cloneFailed": "the Cloud machine could not clone the repository",
  "cloudStartup.because.machineOutdated": "the Cloud machine needs an update to clone",
  "cloudStartup.phase.prepare": "Checking files",
  "cloudStartup.phase.folders": "Making folders",
  "cloudStartup.copyingFiles": "{done} of {total} files",
  "cloudStartup.ofSize": "{done} of {total}",
  "cloudStartup.installApp": "Install the cmux GitHub App to clone it next time",
  "cloudStartup.phase.upload": "Sending your changes ({size})",
  "cloudStartup.phase.clone": "Cloning from GitHub",
  "cloudStartup.phase.fetch": "Fetching from GitHub",
  "cloudStartup.phase.bundle": "Applying your changes",
  "cloudStartup.phase.checkout": "Checking out files",
  "cloudStartup.phase.submodules": "Getting submodules",
  "cloudStartup.phase.lfs": "Getting large files",
  "cloudStart.stage.machine": "Starting your Cloud machine",
  "cloudStart.stage.clone": "Copying your project",
  "cloudStart.stage.project": "Connecting your project",
  "cloudStart.stage.setup": "Running your setup script",
  "cloudStart.eta.longer": "taking longer than usual",
  "cloudStartup.leftOnMac": "{count} files stayed on this Mac",
  "cloudStartup.leftOnMac#one": "{count} file stayed on this Mac",
};
const defaultTranslate: Translate = (key, values = {}) =>
  (DEFAULT_STARTUP_STRINGS[values.n === 1 ? `${key}#one` : key] ?? DEFAULT_STARTUP_STRINGS[key] ?? key)
    .replace("{harness}", String(values.harness ?? "Harness"))
    .replace(/\{(\w+)\}/g, (whole, name: string) => (name in values ? String(values[name]) : whole));
export function startupChecklist(
  start: CloudStartProgress,
  t: Translate = defaultTranslate,
  now = Date.now(),
  language: string = paneLanguage(),
): ChecklistStep[] {
  const oldStep = start.step ? CLOUD_START_STEPS.indexOf(start.step) : -1;
  // A start this Mac refused before it reached Cloud ran no step: none is marked failed.
  const failedStep =
    start.state === "failed" && !start.refusedHere
      ? oldStep === 0
        ? "machine"
        : oldStep === 1
          ? "clone"
          : oldStep === 2
            ? "harness"
            : start.clone?.state === "running" || start.clone?.state === "failed"
              ? "clone"
              : start.setup?.state === "running" || start.setup?.state === "failed"
                ? "setup"
                : "machine"
      : undefined;
  const machine: ChecklistStep = {
    id: "machine",
    label: t("cloudStartup.machine"),
    status:
      failedStep === "machine"
        ? "error"
        : oldStep > 0 || start.initialized
          ? "done"
          : oldStep === 0
            ? "running"
            : "pending",
    duration: elapsed(start.machineStartedAt, start.machineFinishedAt, now),
  };
  if (start.waking && (machine.status === "running" || machine.status === "pending"))
    machine.detail = t("cloudStartup.waking");
  const hasRepository =
    start.hasRepository ?? (Boolean(start.repository || start.folder || start.clone) && !start.home);
  const cloneStatus = operationStatus(start.clone);
  const stoppedCloneStatus =
    start.state === "failed" && failedStep !== "clone" && cloneStatus === "running" ? "pending" : cloneStatus;
  const clone: ChecklistStep = {
    id: "clone",
    label: t("cloudStartup.clone"),
    status: !hasRepository
      ? "skipped"
      : failedStep === "clone"
        ? "error"
        : (stoppedCloneStatus ?? (oldStep > 1 ? "done" : oldStep === 1 ? "running" : "pending")),
    duration: elapsed(start.clone?.startedAt, start.clone?.finishedAt, now),
    ...(cloneDetail(start.clone, t, language) || start.clone?.error
      ? { detail: cloneDetail(start.clone, t, language) || start.clone?.error }
      : {}),
    ...(start.clone?.installUrl && { link: { href: start.clone.installUrl, label: t("cloudStartup.installApp") } }),
  };
  const hasScript = start.setup?.hasScript;
  const setupState = setupStatus(start.setup);
  const stoppedSetupState =
    start.state === "failed" && failedStep !== "setup" && setupState === "running" ? "pending" : setupState;
  const setup: ChecklistStep = {
    id: "setup",
    label: t("cloudStartup.setup"),
    status:
      hasScript === false
        ? "skipped"
        : failedStep === "setup"
          ? "error"
          : (stoppedSetupState ?? (start.initialized ? "done" : "pending")),
    duration: elapsed(start.setup?.startedAt, start.setup?.finishedAt, now),
    ...(start.setup?.status === "ready" ? { detail: t("cloudStartup.cached") } : {}),
    ...(start.setup?.logTail || start.setup?.error
      ? {
          detail: start.setup.logTail || start.setup.error,
          ...(start.setup.logTail ? { logTail: start.setup.logTail } : {}),
        }
      : {}),
    ...(hasScript === false ||
    (start.state === "failed" && setupState === "error" && Boolean(start.environmentId ?? start.environment))
      ? {
          detail: hasScript === false ? t("cloudStartup.setupHint") : start.setup?.logTail || start.setup?.error,
          action: true,
        }
      : {}),
  };
  const harnessStatus: ChecklistStatus =
    failedStep === "harness" ? "error" : start.initialized ? "done" : oldStep === 2 ? "running" : "pending";
  const harness: ChecklistStep = {
    id: "harness",
    // "Started Claude" only once it has; before that the row says what it will do.
    label: t(harnessStatus === "done" ? "cloudStartup.harness" : "cloudStartup.harnessStarting", {
      harness: start.agent || "Harness",
    }),
    status: harnessStatus,
    duration: elapsed(start.harnessStartedAt, start.harnessFinishedAt, now),
  };
  return [machine, clone, setup, harness];
}

/// The one line the quiet start view shows while a Cloud start is on its way: the stage it is on
/// and a live clock of how long it has run, never a bare "Thinking" (Leo, 2026-11-09: "the
/// ergonomic part is super big for us.") and never a guess at how long it usually takes (Austin,
/// 2026-11-24: "show the seconds, dont need to show usually under a minute that stuff"). `step` and
/// `steps` count the stages this start runs (a skipped clone or setup is not one), for a progress hint.
export type QuietStage = {
  id: ChecklistStep["id"];
  /// What the start does now: "Starting your Cloud machine".
  label: string;
  /// The copy's own progress ("1,200 of 3,000 files"), when the host reports it.
  detail?: string;
  /// When this stage began (ms since epoch), when the host said: the line's clock counts from it.
  /// Without it the view counts from when it first showed the stage (`useStageSince`).
  since?: number;
  step: number;
  steps: number;
};

/// The stage a start on its way is at, from the same rows the checklist shows (`startupChecklist`):
/// the running row, else the first that has not run after the last that finished. Setup counts only
/// once the host reports it, so a host that sends only the older `step` never reads as running a
/// setup script. None once the agent has started or the start failed: the view falls back to its
/// Thinking line or its failure.
export function quietStage(
  start: CloudStartProgress,
  rows: ChecklistStep[] = startupChecklist(start),
  t: Translate = defaultTranslate,
): QuietStage | undefined {
  if (start.state === "failed" || start.initialized) return undefined;
  const counted = rows.filter((row) => row.status !== "skipped" && (row.id !== "setup" || start.setup !== undefined));
  // A host that reports only timestamps leaves an earlier row pending after a later one finished
  // (a machine with no `step` once its clone is done): the stage is the first pending row after the
  // last finished one.
  const lastDone = counted.reduce((last, row, index) => (row.status === "done" ? index : last), -1);
  const current =
    counted.find((row) => row.status === "running") ??
    counted.find((row, index) => index > lastDone && row.status === "pending");
  if (!current) return undefined;
  const detail =
    current.id === "clone" && current.status === "running" && current.detail && !start.clone?.error
      ? current.detail
      : undefined;
  const since =
    current.id === "machine"
      ? start.machineStartedAt
      : current.id === "clone"
        ? // A copy whose lines carry no start time began when the machine was done.
          (start.clone?.startedAt ?? start.machineFinishedAt)
        : current.id === "setup"
          ? start.setup?.startedAt
          : start.harnessStartedAt;
  const label =
    current.id === "machine"
      ? (current.detail ?? t("cloudStart.stage.machine"))
      : current.id === "clone"
        ? // A GitHub repository is cloned on the machine, nothing of this Mac copied: the line says so (cmux#53226).
          githubFolderRepo(start.cwd)
          ? t("cloudStartup.phase.clone")
          : // A folder of this Mac is projected by default (cmux-tui `link project`): nothing is copied, its files
            // are read from this Mac on first use, so the line says it connects the project. Only a seed or a
            // copy under way (its phase or its file counts) says it copies.
            start.clone?.phase || start.clone?.progress?.filesTotal !== undefined
            ? t("cloudStart.stage.clone")
            : t("cloudStart.stage.project")
        : current.id === "setup"
          ? t("cloudStart.stage.setup")
          : current.label;
  return {
    id: current.id,
    label,
    ...(detail ? { detail } : {}),
    ...(since !== undefined ? { since } : {}),
    step: counted.indexOf(current) + 1,
    steps: counted.length,
  };
}

/// How long an agent usually takes to start on a Cloud machine before its line says the start is
/// taking longer than usual.
export const AGENT_START_SLOW_MS = 30_000;

/// The line a Cloud chat's first prompt shows on the machine's own chat page while that agent
/// starts: the same "Starting Claude Code" and clock the Mac's start view ended on,
/// never a bare "Thinking" (Leo, 2026-11-24: "what would a new user be seeing here?"). Past
/// `AGENT_START_SLOW_MS` the usual wait gives way to "taking longer than usual".
export function agentStartStage(
  agent: string,
  since: number | undefined,
  now: number,
  t: Translate = defaultTranslate,
): QuietStage {
  const slow = since !== undefined && now - since >= AGENT_START_SLOW_MS;
  return {
    id: "harness",
    label: t("cloudStartup.harnessStarting", { harness: agent }),
    ...(slow ? { detail: t("cloudStart.eta.longer") } : {}),
    since,
    step: 1,
    steps: 1,
  };
}
