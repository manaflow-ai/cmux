import {
  CLOUD_START_STEPS,
  type CloudStartProgress,
  type CloudStartupOperation,
  type CloudStartupSetup,
} from "./cloudStartProgress";
import { fileSizeLabel } from "./fileAttachmentModel";
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

function elapsed(startedAt: number | undefined, finishedAt: number | undefined, now = Date.now()): string | undefined {
  if (startedAt === undefined) return undefined;
  const ms = Math.max(0, (finishedAt ?? now) - startedAt);
  if (ms < 1000) return "<1s";
  if (ms < 60_000) return `${Math.round(ms / 100) / 10}s`;
  const seconds = Math.round(ms / 1000);
  return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
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
};

function cloneDetail(operation: CloudStartupOperation | undefined, t: Translate, language: string): string | undefined {
  if (!operation) return undefined;
  const progress = operation.progress;
  const size = (bytes: number | undefined) => fileSizeLabel(bytes, language);
  const parts: (string | undefined)[] = [];
  if (operation.phase === "cached") parts.push(t("cloudStartup.cached"));
  else if (operation.phase === "complete") {
    // The row's check mark says it finished; only a seed that copied instead says so.
    if (operation.fallback) parts.push(t("cloudStartup.copyInstead"));
  } else if (operation.phase === "copy" || progress?.filesTotal !== undefined) {
    // The streamed copy: files, then bytes.
    if (operation.fallback) parts.push(t("cloudStartup.copyInstead"));
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
    const key = operation.phase ? PHASE_KEYS[operation.phase] : undefined;
    parts.push(key ? t(key) : operation.phase);
    const total = progress?.totalObjects;
    if (progress?.objects !== undefined && total)
      parts.push(`${Math.min(100, Math.floor((progress.objects / total) * 100))}%`);
    else if (progress?.receivedBytes) parts.push(size(progress.receivedBytes));
  }
  return parts.filter(Boolean).join(" · ") || operation.error;
}

const DEFAULT_STARTUP_STRINGS: Record<string, string> = {
  "cloudStartup.machine": "Set up a Cloud machine",
  "cloudStartup.clone": "Clone repository",
  "cloudStartup.setup": "Run setup script",
  "cloudStartup.setupHint": "Add a setup script to install dependencies and configure your environment.",
  "cloudStartup.cached": "cached",
  "cloudStartup.harness": "Started {harness}",
  "cloudStartup.harnessStarting": "Starting {harness}",
  "cloudStartup.copyInstead": "Copying the folder instead",
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
};
export function startupChecklist(
  start: CloudStartProgress,
  t: Translate = (key, values = {}) =>
    (DEFAULT_STARTUP_STRINGS[key] ?? key)
      .replace("{harness}", String(values.harness ?? "Harness"))
      .replace(/\{(\w+)\}/g, (whole, name: string) => (name in values ? String(values[name]) : whole)),
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
    ...(hasScript === false ? { detail: t("cloudStartup.setupHint"), action: true } : {}),
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
