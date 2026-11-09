// "Set Up cmux" on Home, as values: what this Mac still lacks for a first run (an agent that can
// answer, a cmux account, the `cmux` command in any terminal, and classic cmux's workspaces when a
// classic session was found), which row comes next, and how far along it is. The host reads each
// row's state (acpmux's harness health, the account, `CLIInstallReport`, the classic migration's
// plan) and runs each action; this file decides nothing the host can answer. Not wired yet: the
// gallery shows it (goal next-first-run-setup, cmuxterm-hq goals/next-first-run-setup.md).
import type { Strings } from "../strings";

/** One agent CLI's row inside the agents step. */
export interface SetupAgent {
  id: string;
  /** The product's own name ("Claude Code", "Codex"): never translated. */
  name: string;
  state: "missing" | "installing" | "failed" | "signedOut" | "signedIn";
}

export interface SetupState {
  agents: readonly SetupAgent[];
  account: { signedIn: boolean; email?: string };
  /** `missing`: no `cmux` on the login PATH; `other`: another cmux app's CLI (classic, a moved copy), which
   * Replace overwrites; `foreign`: a `cmux` that is no cmux app's, never touched; `fromImage`: cmux runs from
   * its disk image, so nothing installs until it runs from Applications; `installing`: an install runs. */
  cli: "missing" | "other" | "installed" | "foreign" | "fromImage" | "installing";
  /** Chats from other agents on this Mac (the host found some): the row opens the history import; `done` once
   * that page showed or the row was dismissed. Null or absent: none found (the row does not show). */
  history?: { done: boolean } | null;
  /** Classic's saved session, when one was found and not answered yet; null: none (the row does not show). */
  classic: { workspaces: number; saved: string; answered?: "imported" | "declined" } | null;
}

export type SetupStepID = "agents" | "history" | "account" | "cli" | "classic";

/** What a row's button asks the host to do. */
export type SetupAction =
  | { kind: "installAgent"; id: string }
  | { kind: "signInAgent"; id: string }
  | { kind: "signInAccount" }
  | { kind: "installCLI" }
  | { kind: "importHistory" }
  | { kind: "declineHistory" }
  | { kind: "importClassic" }
  | { kind: "declineClassic" };

export interface SetupStep {
  id: SetupStepID;
  done: boolean;
  title: string;
  detail: string;
  /** The row's one button; absent once done (the slot keeps its room). */
  action?: { label: string; run: SetupAction };
  /** A quieter second button (classic's Not Now). */
  secondary?: { label: string; run: SetupAction };
  /** An action is running (an install): the slot shows a spinner. */
  busy?: boolean;
}

/** The agent a person is closest to talking to: signed in, else signed out, else the first. */
function leadAgent(agents: readonly SetupAgent[]): SetupAgent | undefined {
  const rank = { signedIn: 0, signedOut: 1, installing: 2, failed: 3, missing: 4 } as const;
  return [...agents].sort((a, b) => rank[a.state] - rank[b.state])[0];
}

/** The rows in their order: classic first when found (its answer decides what Home holds), then
 * agents, the chat history when found, account and the command line. */
export function setupSteps(state: SetupState, strings: Strings): SetupStep[] {
  const { t, format } = strings;
  const steps: SetupStep[] = [];
  if (state.classic) {
    const { workspaces, saved, answered } = state.classic;
    steps.push({
      id: "classic",
      done: answered !== undefined,
      title: t("home.setup.classic"),
      detail:
        answered === "imported"
          ? t("home.setup.classic.imported")
          : answered === "declined"
            ? t("home.setup.classic.declined")
            : format("home.setup.classic.detail", String(workspaces), saved),
      ...(answered === undefined && {
        action: { label: t("home.setup.import"), run: { kind: "importClassic" } as const },
        secondary: { label: t("home.setup.notNow"), run: { kind: "declineClassic" } as const },
      }),
    });
  }
  const names = state.agents.map((agent) => agent.name).join(", ");
  const lead = leadAgent(state.agents);
  const ready = state.agents.find((agent) => agent.state === "signedIn");
  steps.push({
    id: "agents",
    done: ready !== undefined,
    title: t("home.setup.agents"),
    detail: ready
      ? format("home.setup.agents.ready", ready.name)
      : lead?.state === "failed"
        ? format("home.setup.agents.failed", lead.name)
        : names,
    busy: lead?.state === "installing",
    ...(ready === undefined &&
      lead !== undefined && {
        action:
          lead.state === "signedOut"
            ? {
                label: format("home.setup.signInTo", lead.name),
                run: { kind: "signInAgent", id: lead.id } as const,
              }
            : {
                label: format("home.setup.installAgent", lead.name),
                run: { kind: "installAgent", id: lead.id } as const,
              },
      }),
  });
  if (state.history) {
    const { done } = state.history;
    steps.push({
      id: "history",
      done,
      title: t("home.setup.history"),
      detail: t("home.setup.history.detail"),
      ...(!done && {
        action: { label: t("home.setup.import"), run: { kind: "importHistory" } as const },
        secondary: { label: t("home.setup.notNow"), run: { kind: "declineHistory" } as const },
      }),
    });
  }
  steps.push({
    id: "account",
    done: state.account.signedIn,
    title: t("home.setup.account"),
    detail: state.account.signedIn ? (state.account.email ?? t("home.setup.signedIn")) : t("home.setup.account.detail"),
    ...(!state.account.signedIn && {
      action: { label: t("home.setup.signIn"), run: { kind: "signInAccount" } as const },
    }),
  });
  steps.push({
    id: "cli",
    done: state.cli === "installed",
    title: t("home.setup.cli"),
    detail:
      state.cli === "other"
        ? t("home.setup.cli.other")
        : state.cli === "foreign"
          ? t("home.setup.cli.foreign")
          : state.cli === "fromImage"
            ? t("home.setup.cli.fromImage")
            : t("home.setup.cli.detail"),
    busy: state.cli === "installing",
    ...((state.cli === "missing" || state.cli === "other") && {
      action: {
        label: t(state.cli === "other" ? "home.setup.replace" : "home.setup.install"),
        run: { kind: "installCLI" } as const,
      },
    }),
  });
  return steps;
}

/** The first row not done; undefined when every row is. */
export function nextStep(steps: readonly SetupStep[]): SetupStep | undefined {
  return steps.find((step) => !step.done);
}

/** Rows done of rows shown. */
export function setupProgress(steps: readonly SetupStep[]): { done: number; total: number } {
  return { done: steps.filter((step) => step.done).length, total: steps.length };
}
