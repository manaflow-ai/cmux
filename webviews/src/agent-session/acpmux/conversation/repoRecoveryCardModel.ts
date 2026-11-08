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

function githubInstallUrl(value: unknown): string | undefined {
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
