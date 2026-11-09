// "Set Up cmux" on Home, as values: what this Mac still lacks for a first run (an agent that can
// answer, a cmux account, the `cmux` command in any terminal, and classic cmux's workspaces when a
// classic session was found), which row comes next, and how far along it is. The host reads each
// row's state (acpmux's harness health, the account, `CLIInstallReport`, the classic migration's
// plan) and runs each action; this file decides nothing the host can answer (goal next-first-run-setup,
// cmuxterm-hq goals/next-first-run-setup.md).
import type { Strings } from "../strings";

/** One agent CLI's row inside the agents step. */
export interface SetupAgent {
  id: string;
  /** The product's own name ("Claude Code", "Codex"): never translated. */
  name: string;
  state: "missing" | "installing" | "failed" | "signedOut" | "unverified" | "signedIn";
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
  /** The launch's classic import while it asks on this row, and its answer; null: nothing to import (the row
   * does not show). `app` is the classic app that saved it, as its Dock names it; `savedAt` when (ms since
   * 1970); `running`: that app is still open, so this is its autosave; `resumes`: importing reconnects saved
   * SSH hosts or resumes saved agent chats. */
  classic: {
    workspaces: number;
    app: string;
    savedAt: number;
    running?: boolean;
    resumes?: boolean;
    answered?: "imported" | "declined";
  } | null;
}

export type SetupStepID = "agents" | "history" | "account" | "cli" | "classic";

/** What a row's button asks the host to do. */
export type SetupAction =
  | { kind: "installAgent"; id: string }
  | { kind: "signInAgent"; id: string }
  | { kind: "confirmAgent"; id: string }
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
  /** A second line under the detail: what the row's action also does. */
  note?: string;
  /** The row's one button; absent once done (the slot keeps its room). */
  action?: { label: string; run: SetupAction };
  /** A quieter second button (classic's Skip, the next agent); it stays while the row is busy, greyed
   * (`disabled`) when it waits on the run in flight. */
  secondary?: { label: string; run: SetupAction; disabled?: boolean };
  /** A third, quieter still: only while an agent waits for its sign-in to be confirmed and another agent
   * exists, so Sign In Again and the other agent both stay one click away. */
  tertiary?: { label: string; run: SetupAction };
  /** An action is running (an install): the slot shows a spinner. */
  busy?: boolean;
}

/** The agent a person is closest to talking to: signed in, else signed out, else the first. */
function leadAgent(agents: readonly SetupAgent[]): SetupAgent | undefined {
  const rank = { signedIn: 0, unverified: 1, signedOut: 2, installing: 3, failed: 4, missing: 5 } as const;
  return [...agents].sort((a, b) => rank[a.state] - rank[b.state])[0];
}

/** An agent's button: sign in once installed, else install. */
function agentAction(agent: SetupAgent, { format }: Strings): { label: string; run: SetupAction } {
  return agent.state === "signedOut" || agent.state === "unverified"
    ? { label: format("home.setup.signInTo", agent.name), run: { kind: "signInAgent", id: agent.id } }
    : { label: format("home.setup.installAgent", agent.name), run: { kind: "installAgent", id: agent.id } };
}

/** The rows in their order: classic first when found (its answer decides what Home holds), then
 * agents, the chat history when found, account and the command line. */
export function setupSteps(state: SetupState, strings: Strings): SetupStep[] {
  const { t, format } = strings;
  const steps: SetupStep[] = [];
  if (state.classic) {
    const { workspaces, app, savedAt, running, resumes, answered } = state.classic;
    const saved = new Intl.DateTimeFormat(strings.language, { dateStyle: "medium", timeStyle: "short" }).format(savedAt);
    steps.push({
      id: "classic",
      done: answered !== undefined,
      title: t("home.setup.classic"),
      detail:
        answered === "imported"
          ? t("home.setup.classic.imported")
          : answered === "declined"
            ? t("home.setup.classic.declined")
            : running
              ? format("home.setup.classic.open", app, saved)
              : format("home.setup.classic.detail", new Intl.NumberFormat(strings.language).format(workspaces), app, saved),
      // Skip is a No the migration keeps (later launches don't ask; Settings › Import still brings them), so
      // the row says what Import also does before the person presses it, as the classic import dialog did.
      ...(answered === undefined && {
        ...(resumes && { note: t("home.setup.classic.resumes") }),
        action: { label: t("home.setup.import"), run: { kind: "importClassic" } as const },
        secondary: { label: t("home.setup.skip"), run: { kind: "declineClassic" } as const },
      }),
    });
  }
  const names = state.agents.map((agent) => agent.name).join(", ");
  const lead = leadAgent(state.agents);
  const ready = state.agents.find((agent) => agent.state === "signedIn");
  // Every agent stays one click away: the lead gets the row's button, the next one a quieter one,
  // so a failed or slow install of one never hides the other. Installs run one at a time, so while
  // one runs the next agent's Install waits, greyed, with the row saying so.
  const other =
    ready === undefined ? state.agents.find((agent) => agent !== lead && agent.state !== "installing") : undefined;
  const installing = state.agents.find((agent) => agent.state === "installing");
  const waits = installing !== undefined && other !== undefined && other.state !== "signedOut";
  // A login opened here whose sign-in cannot be read (Claude Code's Keychain login reads as unknown until a
  // session proves it): the person says when it is done, or signs in again. Opening the login is no proof.
  const unverified = ready === undefined && lead?.state === "unverified" ? lead : undefined;
  steps.push({
    id: "agents",
    done: ready !== undefined,
    title: t("home.setup.agents"),
    detail: ready
      ? format("home.setup.agents.ready", ready.name)
      : unverified
        ? format("home.setup.agents.unverified", unverified.name)
        : waits
          ? format("home.setup.agents.after", other.name, installing.name)
          : lead?.state === "failed"
            ? format("home.setup.agents.failed", lead.name)
            : names,
    busy: lead?.state === "installing",
    ...(ready === undefined &&
      lead !== undefined &&
      lead.state !== "installing" &&
      !unverified && { action: agentAction(lead, strings) }),
    ...(unverified
      ? {
          action: { label: t("home.setup.confirmSignedIn"), run: { kind: "confirmAgent", id: unverified.id } as const },
          secondary: { label: t("home.setup.signInAgain"), run: { kind: "signInAgent", id: unverified.id } as const },
          // The other agent stays one click away while this one waits (every agent keeps a button).
          ...(other !== undefined && { tertiary: agentAction(other, strings) }),
        }
      : other !== undefined && { secondary: { ...agentAction(other, strings), ...(waits && { disabled: true }) } }),
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
