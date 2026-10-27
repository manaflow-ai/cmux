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
};

const REMOTE_WORDS = /\b(?:cloud|remote|server|vm|deploy|build|ci|linux)\b/i;

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

  const named = [...remotes]
    .sort((left, right) => right.label.length - left.label.length)
    .find((environment) => words.includes(environment.label.toLocaleLowerCase()));
  if (named) return { environment: named, reason: "machine" };

  const normalizedProject = normalizePath(project);
  if (normalizedProject) {
    const projectMachine = sessions
      .map((session) => {
        const id = session.peer ?? (session.hostKind === "cloud" ? session.host : undefined);
        return id && normalizePath(session.cwd) === normalizedProject ? id : undefined;
      })
      .find((id) => id && remotes.some((environment) => environment.id === id));
    const environment = projectMachine ? remotes.find((candidate) => candidate.id === projectMachine) : undefined;
    if (environment) return { environment, reason: "project" };
  }

  if (REMOTE_WORDS.test(words)) {
    const cloud = remotes.find((environment) => environment.kind === "cloud");
    if (cloud) return { environment: cloud, reason: "prompt" };
    const ssh = remotes.find((environment) => environment.kind === "ssh");
    if (ssh) return { environment: ssh, reason: "prompt" };
  }

  return {
    environment: environments.find((environment) => environment.kind === "local") ?? {
      id: "local",
      label: "This Mac",
      kind: "local",
    },
    reason: "local",
  };
}

function normalizePath(path?: string): string | undefined {
  if (!path) return undefined;
  const normalized = path.replace(/\/+$/, "");
  return normalized || (path.startsWith("/") ? "/" : path);
}
