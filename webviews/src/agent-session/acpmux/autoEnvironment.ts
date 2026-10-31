import { environmentReady, type Environment } from "./environments";
import type { RunLocation } from "./runLocationDefault";

export type AutoEnvironmentSession = {
  cwd?: string;
  peer?: string;
  host?: string;
  hostKind?: string;
};

/// Where Auto sends a new chat's first prompt. `cloud` is the picker's Cloud row (cloudRun.ts: the
/// app picks a machine and copies the folder); `machine` a ready machine acpmux lists; `local` this
/// Mac. `folder`: the folder's run location (runLocationDefault.ts), the default for every prompt
/// that asks for no destination of its own; `prompt`: the prompt asked for it.
export type AutoEnvironmentChoice =
  | { to: "local"; environment: Environment; reason: "folder" | "prompt" }
  | { to: "cloud"; reason: "folder" | "prompt" }
  | {
      to: "machine";
      environment: Environment;
      reason: "prompt";
      /** A folder known to exist on the selected remote machine, when one is known. */
      cwd?: string;
    };

// Only an affirmative execution instruction can change destination. Mentions in ordinary
// coding tasks and negated instructions keep the folder's run location.
const EXECUTION = /^(?:please\s+)?(?:run|build|test|deploy|execute|start|continue|work|use)\b/i;
const NEGATED = /\b(?:not|never|avoid|without|don['’]t|do not)\b/i;
const REMOTE_DESTINATION =
  /\b(?:(?:in|on|to|using)\s+(?:(?:the|a|my|our)\s+)?(?:cloud|remote machine|remote server|vm)|remotely|cloud (?:build|job|task|test))\b/i;
// Local as a destination, not a word: "locally" or "on this Mac"; "the local dataset" is no ask.
const LOCAL_DESTINATION = /\b(?:locally|(?:on|using)\s+(?:this|my)\s+(?:mac|computer|machine|laptop))\b/i;

/// Resolve where a new prompt runs under Auto. The folder's run location (`folder`: Cloud when its
/// newest chat went to Cloud, else this Mac) holds for every ordinary prompt. Only an explicit
/// execution request moves it, first match wins: a complete ready machine name, an ask to run
/// locally, an ask for cloud or remote work. Cloud is the Cloud row when the picker offers it (`cloudRow`), else a
/// ready Cloud machine, else a ready SSH machine.
export function chooseAutoEnvironment({
  prompt,
  folder = "local",
  cloudRow = false,
  project,
  environments,
  sessions = [],
}: {
  prompt: string;
  folder?: RunLocation;
  cloudRow?: boolean;
  /** The chat's folder: kept for a named machine that already has a chat in it. */
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
  const destinationIntent = EXECUTION.test(words) && !NEGATED.test(words);

  const named = [...remotes]
    .sort((left, right) => right.label.length - left.label.length)
    .find((environment) => destinationIntent && containsMachineReference(words, environment.label));
  if (named) {
    const normalizedProject = normalizePath(project);
    const namedProject = normalizedProject
      ? sessions.find(
          (session) =>
            normalizePath(session.cwd) === normalizedProject &&
            (session.peer ?? (session.hostKind === "cloud" ? session.host : undefined)) === named.id,
        )
      : undefined;
    return {
      to: "machine",
      environment: named,
      reason: "prompt",
      ...(namedProject?.cwd ? { cwd: namedProject.cwd } : {}),
    };
  }

  if (destinationIntent && LOCAL_DESTINATION.test(words)) return { to: "local", environment: local, reason: "prompt" };

  if (destinationIntent && REMOTE_DESTINATION.test(words)) {
    if (cloudRow) return { to: "cloud", reason: "prompt" };
    const remote =
      remotes.find((environment) => environment.kind === "cloud") ??
      remotes.find((environment) => environment.kind === "ssh");
    if (remote) return { to: "machine", environment: remote, reason: "prompt" };
  }

  if (folder === "cloud" && cloudRow) return { to: "cloud", reason: "folder" };
  return { to: "local", environment: local, reason: "folder" };
}

function containsMachineReference(prompt: string, label: string): boolean {
  const escaped = label.toLocaleLowerCase().replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  // The name ends the word: at the end, before a non-name character, or before a full stop that
  // ends the sentence ("on gpu-box."), never one inside a longer host name ("gpu-box.example.com").
  return new RegExp(
    `\\b(?:on|to|using|use)\\s+(?:(?:the|my|our)\\s+)?${escaped}(?=$|[^\\p{L}\\p{N}_.-]|\\.(?:$|\\s))`,
    "u",
  ).test(prompt);
}

function normalizePath(path?: string): string | undefined {
  if (!path) return undefined;
  const normalized = path.replace(/\/+$/, "");
  return normalized || (path.startsWith("/") ? "/" : path);
}
