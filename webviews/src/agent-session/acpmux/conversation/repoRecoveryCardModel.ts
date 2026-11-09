import type { AcpmuxActivity } from "../model";

type Choice = { fullName: string; private?: boolean; source?: string };
export type RepoRecovery = {
  code: string;
  org?: string;
  installUrl?: string;
  choices?: Choice[];
  retry?: { action: string; args: Record<string, unknown>; wait_action?: string };
};

function payload(text: string | undefined): Record<string, unknown> | undefined {
  if (!text) return undefined;
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end <= start) return undefined;
  try {
    const parsed = JSON.parse(text.slice(start, end + 1));
    if (parsed && typeof parsed === "object") return parsed as Record<string, unknown>;
  } catch {
    // Tool output may have a prose prefix; try the next JSON object below.
  }
  return undefined;
}

export function githubInstallUrl(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.hostname === "github.com" ? url.toString() : undefined;
  } catch {
    return undefined;
  }
}

export function repoRecoveryFor(tool: NonNullable<AcpmuxActivity["tool"]>): RepoRecovery | undefined {
  if (
    tool.title !== "list_repos" &&
    tool.title !== "add_repo" &&
    !tool.title.endsWith(".list_repos") &&
    !tool.title.endsWith(".add_repo")
  )
    return undefined;
  const data = payload(tool.output);
  const code = data?.code;
  if (code !== "repo.needs_github" && code !== "repo.no_access" && code !== "repo.ambiguous") return undefined;
  const retry = data?.retry;
  const rawArgs = retry && typeof retry === "object" ? (retry as { args?: unknown }).args : undefined;
  const args = rawArgs && typeof rawArgs === "object" ? (rawArgs as Record<string, unknown>) : undefined;
  const safeArgs =
    typeof args?.repo === "string"
      ? { repo: args.repo, ...(typeof args.ref === "string" ? { ref: args.ref } : {}) }
      : undefined;
  return {
    code,
    org: typeof data?.org === "string" ? data.org : undefined,
    installUrl: githubInstallUrl(data?.install_url),
    choices: Array.isArray(data?.choices)
      ? data.choices.filter((choice): choice is Choice => Boolean(choice) && typeof choice.fullName === "string")
      : undefined,
    retry:
      (retry as { action?: unknown } | undefined)?.action === "cloud.repo.add" && safeArgs
        ? {
            action: "cloud.repo.add",
            args: safeArgs,
            wait_action:
              (retry as { wait_action?: unknown }).wait_action === "cloud.repo.wait_github"
                ? "cloud.repo.wait_github"
                : undefined,
          }
        : undefined,
  };
}

/** How long the card waits for GitHub to confirm the install. The host caps one wait at 60 s. */
export const GITHUB_WAIT_MS = 60_000;

/** Where the card is. Every phase but the two with a call in flight (`linking`, `retrying`) offers a next step. */
export type RepoRecoveryPhase =
  | { kind: "idle" }
  /** Asking the app for a GitHub connect link, because the tool's error carried none. */
  | { kind: "linking" }
  /** The app had no connect link either. */
  | { kind: "noLink" }
  /** The install page is open; the host checks GitHub until `until` (epoch ms). */
  | { kind: "waiting"; until: number }
  /** The wait ended and GitHub still isn't connected. */
  | { kind: "notConnected" }
  | { kind: "retrying" }
  /** Attached. `connected`: the card verified a GitHub connection on the way. */
  | { kind: "done"; connected: boolean }
  | { kind: "failed" };

export type RepoRecoveryActionId =
  | "connect"
  | "getLink"
  | "reopen"
  | "checkAgain"
  | "retry"
  | "requestAccess"
  | "choose";

/** The catalog keys this card uses. The component translates them, so this module stays free of i18n. */
export type RepoRecoveryKey =
  | "cloudRepository.connectNeeded"
  | "cloudRepository.connect"
  | "cloudRepository.linking"
  | "cloudRepository.noLink"
  | "cloudRepository.waitingGithub"
  | "cloudRepository.openGithubAgain"
  | "cloudRepository.notConnectedYet"
  | "cloudRepository.checkAgain"
  | "cloudRepository.pending"
  | "cloudRepository.attached"
  | "cloudRepository.attachedRepo"
  | "cloudRepository.connectedAttached"
  | "cloudRepository.attachFailedRepo"
  | "cloudRepository.tryAgain"
  | "cloudRepository.noAccess"
  | "cloudRepository.installOn"
  | "cloudRepository.requestAccess"
  | "cloudRepository.which"
  | "cloudRepository.thisRepository"
  | "cloudRepository.repositories"
  | "cloudRepository.github";

/** A string to show: a catalog key whose values may themselves be catalog strings, or a literal (a repository name). */
export type RepoRecoveryText =
  | { key: RepoRecoveryKey; values?: Record<string, string | RepoRecoveryText> }
  | { literal: string };
export type RepoRecoveryAction = { id: RepoRecoveryActionId; label: RepoRecoveryText; repo?: string };
export type RepoRecoveryView = {
  tone: "plain" | "quiet" | "error" | "done";
  message: RepoRecoveryText;
  actions: RepoRecoveryAction[];
  /** `waiting` counts down to this (epoch ms) beside its message: the wait's reason and its ETA. */
  until?: number;
  /** Set on the choice list, a named group. */
  group?: boolean;
};

/** The repository the failed call named, when the tool's retry contract carries an owner/name. */
export function recoveryRepo(recovery: RepoRecovery, chosen?: string): string | undefined {
  if (chosen) return chosen;
  const repo = recovery.retry?.args.repo;
  return typeof repo === "string" && repo.includes("/") ? repo : undefined;
}

const text = (key: RepoRecoveryKey, values?: Record<string, string | RepoRecoveryText>): RepoRecoveryText =>
  values ? { key, values } : { key };

/** "m:ss" left until `until`, never below 0:00. */
export function waitLeft(until: number, now: number): string {
  const seconds = Math.max(0, Math.ceil((until - now) / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

/**
 * Every phase of the card to what it says and the one-click steps it offers. A phase a person can
 * act in is never left without an action: a failure offers Try again, a connect that didn't take
 * offers Check again (and the install page again), and a missing install link offers to fetch one.
 */
export function repoRecoveryView(
  recovery: RepoRecovery,
  phase: RepoRecoveryPhase,
  chosen?: string,
): RepoRecoveryView | undefined {
  const repo = recoveryRepo(recovery, chosen);
  const target: RepoRecoveryText = repo ? { literal: repo } : text("cloudRepository.thisRepository");
  const canVerify = Boolean(recovery.retry);
  const reopen: RepoRecoveryAction[] = recovery.installUrl
    ? [{ id: "reopen", label: text("cloudRepository.openGithubAgain") }]
    : [];
  switch (phase.kind) {
    case "linking":
      return { tone: "quiet", message: text("cloudRepository.linking"), actions: [] };
    case "noLink":
      return {
        tone: "error",
        message: text("cloudRepository.noLink"),
        actions: [
          { id: "getLink", label: text("cloudRepository.tryAgain") },
          ...(canVerify ? [{ id: "checkAgain" as const, label: text("cloudRepository.checkAgain") }] : []),
        ],
      };
    case "waiting":
      return { tone: "quiet", message: text("cloudRepository.waitingGithub"), actions: reopen, until: phase.until };
    case "notConnected":
      return {
        tone: "error",
        message: text("cloudRepository.notConnectedYet"),
        actions: [{ id: "checkAgain", label: text("cloudRepository.checkAgain") }, ...reopen],
      };
    case "retrying":
      return { tone: "quiet", message: text("cloudRepository.pending"), actions: [] };
    case "done":
      return {
        tone: "done",
        message: repo
          ? text(phase.connected ? "cloudRepository.connectedAttached" : "cloudRepository.attachedRepo", { repo })
          : text("cloudRepository.attached"),
        actions: [],
      };
    case "failed":
      return {
        tone: "error",
        message: text("cloudRepository.attachFailedRepo", { target }),
        actions: canVerify ? [{ id: "retry", label: text("cloudRepository.tryAgain") }] : [],
      };
    case "idle":
      break;
  }
  if (recovery.code === "repo.needs_github")
    return {
      tone: "plain",
      message: text("cloudRepository.connectNeeded", { target }),
      actions: [{ id: recovery.installUrl ? "connect" : "getLink", label: text("cloudRepository.connect") }],
    };
  if (recovery.code === "repo.no_access")
    return {
      tone: "plain",
      message: text("cloudRepository.noAccess", {
        target: recovery.org
          ? text("cloudRepository.repositories", { org: recovery.org })
          : text("cloudRepository.thisRepository"),
      }),
      actions: [
        ...(recovery.installUrl
          ? [
              {
                id: "connect" as const,
                label: text("cloudRepository.installOn", {
                  target: recovery.org ?? text("cloudRepository.github"),
                }),
              },
            ]
          : []),
        { id: "requestAccess", label: text("cloudRepository.requestAccess") },
      ],
    };
  if (recovery.code === "repo.ambiguous" && recovery.choices?.length)
    return {
      tone: "plain",
      group: true,
      message: text("cloudRepository.which"),
      actions: recovery.choices.map((item) => ({
        id: "choose" as const,
        label: { literal: item.fullName },
        repo: item.fullName,
      })),
    };
  return undefined;
}
