import { environmentReady, type Environment } from "./environments";

export type AutoEnvironmentSession = {
  cwd?: string;
  peer?: string;
  host?: string;
  hostKind?: string;
};

export type AutoEnvironmentChoice = {
  environment: Environment;
  reason: "machine" | "project" | "prompt" | "local";
  /** A folder known to exist on the selected remote machine, when one is known. */
  cwd?: string;
};

const REMOTE_WORDS = /\b(?:cloud|remote|server|vm|deploy|build|ci|linux)\b/i;
const LOCAL_WORDS = /\b(?:local(?:ly)?|here|this mac|on my mac|on this computer)\b/i;

/// Resolve the default destination for a new prompt. The local machine is the safe default;
/// an explicitly named machine, a project that already runs on a remote machine, or a prompt
/// that asks for remote work can make a ready remote row win.
export function chooseAutoEnvironment({
  prompt,
  project,
  environments,
  sessions = [],
}: {
  prompt: string;
  project?: string;
  environments: readonly Environment[];
  sessions?: readonly AutoEnvironmentSession[];
}): AutoEnvironmentChoice {
  const ready = environments.filter(environmentReady);
  const remotes = ready.filter((environment) => environment.kind !== "local");
  const words = prompt.trim().toLocaleLowerCase();
  const local = environments.find((environment) => environment.kind === "local") ?? {
    id: "local",
    label: "This Mac",
    kind: "local" as const,
  };

  if (LOCAL_WORDS.test(words)) return { environment: local, reason: "local" };

  const normalizedProject = normalizePath(project);
  const projectSession = normalizedProject
    ? sessions
        .map((session) => {
          const id = session.peer ?? (session.hostKind === "cloud" ? session.host : undefined);
          return id && normalizePath(session.cwd) === normalizedProject ? session : undefined;
        })
        .find((session) => {
          const id = session?.peer ?? (session?.hostKind === "cloud" ? session.host : undefined);
          return id !== undefined && remotes.some((environment) => environment.id === id);
        })
    : undefined;
  const projectMachine =
    projectSession?.peer ?? (projectSession?.hostKind === "cloud" ? projectSession.host : undefined);

  const named = [...remotes]
    .sort((left, right) => right.label.length - left.label.length)
    .find((environment) => containsMachineReference(words, environment.label));
  if (named) {
    const namedProject = normalizedProject
      ? sessions.find(
          (session) =>
            normalizePath(session.cwd) === normalizedProject &&
            (session.peer ?? (session.hostKind === "cloud" ? session.host : undefined)) === named.id,
        )
      : undefined;
    return {
      environment: named,
      reason: "machine",
      ...(namedProject?.cwd ? { cwd: namedProject.cwd } : {}),
    };
  }

  const projectEnvironment = projectMachine ? remotes.find((candidate) => candidate.id === projectMachine) : undefined;
  if (projectEnvironment) return { environment: projectEnvironment, reason: "project", cwd: projectSession?.cwd };

  if (REMOTE_WORDS.test(words)) {
    const cloud = remotes.find((environment) => environment.kind === "cloud");
    if (cloud) return { environment: cloud, reason: "prompt" };
    const ssh = remotes.find((environment) => environment.kind === "ssh");
    if (ssh) return { environment: ssh, reason: "prompt" };
  }

  return {
    environment: local,
    reason: "local",
  };
}

function containsMachineReference(prompt: string, label: string): boolean {
  const escaped = label.toLocaleLowerCase().replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`(?:^|[^\\p{L}\\p{N}_])${escaped}(?=$|[^\\p{L}\\p{N}_])`, "u").test(prompt);
}

function normalizePath(path?: string): string | undefined {
  if (!path) return undefined;
  const normalized = path.replace(/\/+$/, "");
  return normalized || (path.startsWith("/") ? "/" : path);
}
