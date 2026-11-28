import type { CloudStartAnswer } from "./cloudRun";
import { cloudStartBegun, cloudStartEnded, cloudStartPushed, type CloudStartProgress } from "./cloudStartProgress";
import { harnessLabel } from "./subagents/agentRuns";

/// A Cloud start an earlier page of this pane sent, as the host kept it (AgentPaneCloudStartResume.swift): a page
/// built again while the start ran (the health check's reload of a page that stopped answering, a hibernated page
/// shown again) gets it in its handshake (`cloudStartResume`), so it shows the start and, once the host pushes its
/// end, the chat or the failure with Retry. Before it, such a page drew an empty New Tab: the prompt was gone and the
/// start's answer, a failure included, went to the page that was no longer there.
export type CloudStartResume = {
  key: string;
  task: string;
  cwd?: string;
  home?: boolean;
  harness?: string;
  /// The start's progress pushes so far, their fields merged.
  progress?: Record<string, unknown>;
  /// Set when the start ended before this page was built.
  ended?: CloudStartAnswer;
};

const text = (value: unknown, max: number): string | undefined =>
  typeof value === "string" && value && value.length <= max ? value : undefined;

/// The host's `ended` (`{ok, code?, message?, retryable?}`) as the page's own answer reads it; nil for anything else.
export function readCloudStartEnd(value: unknown): CloudStartAnswer | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const fields = value as Record<string, unknown>;
  if (fields.ok === true) return { ok: true };
  if (fields.ok !== false) return undefined;
  const message = text(fields.message, 4000);
  return {
    ok: false,
    code: text(fields.code, 128) ?? "cloud_start_failed",
    ...(message ? { message } : {}),
    ...(fields.retryable === true ? { retryable: true } : {}),
  };
}

/// The handshake's `cloudStartResume`, each field checked; nil for anything else.
export function readCloudStartResume(value: unknown): CloudStartResume | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const fields = value as Record<string, unknown>;
  const key = text(fields.key, 128);
  const task = typeof fields.task === "string" ? fields.task : undefined;
  if (!key || task === undefined) return undefined;
  const cwd = text(fields.cwd, 4096);
  const harness = text(fields.harness, 128);
  const progress =
    typeof fields.progress === "object" && fields.progress !== null && !Array.isArray(fields.progress)
      ? (fields.progress as Record<string, unknown>)
      : undefined;
  const ended = readCloudStartEnd(fields.ended);
  return {
    key,
    task,
    ...(cwd ? { cwd } : {}),
    ...(fields.home === true ? { home: true } : {}),
    ...(harness ? { harness } : {}),
    ...(progress ? { progress } : {}),
    ...(ended ? { ended } : {}),
  };
}

/// The card a page built again shows for `resume`: the start with its steps so far, or its failure. A page that
/// already shows a start (a reconnect of the same page, or a newer start of its own) keeps it.
export function resumedCloudStart(
  current: CloudStartProgress | undefined,
  resume: CloudStartResume,
  now: number = Date.now(),
): CloudStartProgress | undefined {
  if (current) return current;
  const begun: CloudStartProgress = {
    ...cloudStartBegun(
      resume.key,
      resume.task,
      resume.cwd,
      resume.harness ? harnessLabel(resume.harness) : undefined,
      resume.home,
    ),
    resumed: true,
  };
  const shown = resume.progress
    ? (cloudStartPushed(begun, { ...resume.progress, key: resume.key }, now) ?? begun)
    : begun;
  return resume.ended ? cloudStartEnded(shown, resume.key, resume.ended) : shown;
}

/// The host's push of a start's end (`{key, ended}`), for a page that did not send it (`resumed`): the start's card
/// ends with it as the sending page's answer would have ended it. The page that sent the start ends it with its own
/// answer and leaves this push alone. Nil `ended`: the push is no end, or not this page's to take.
export function cloudStartEndPushed(
  current: CloudStartProgress | undefined,
  push: unknown,
): { next: CloudStartProgress | undefined; ended?: CloudStartAnswer } {
  if (typeof push !== "object" || push === null) return { next: current };
  const fields = push as Record<string, unknown>;
  const ended = readCloudStartEnd(fields.ended);
  if (!ended || !current?.resumed || current.state !== "starting" || fields.key !== current.key)
    return { next: current };
  return { next: cloudStartEnded(current, current.key, ended), ended };
}
