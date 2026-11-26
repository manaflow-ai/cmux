// "Set Up cmux" on Home, as values: what this Mac still lacks for a first run (an agent that can
// answer, a cmux account, the `cmux` command in any terminal, and classic cmux's workspaces when a
// classic session was found), which row comes next, and how far along it is. The host reads each
// row's state (acpmux's harness health, the account, `CLIInstallReport`, the classic migration's
// plan) and runs each action; this file decides nothing the host can answer. Not wired yet: the
// gallery shows it (goal next-first-run-setup, cmuxterm-hq goals/next-first-run-setup.md).
import type { Strings } from "./strings";

/** One agent CLI's row inside the agents step. */
export interface SetupAgent {
  id: string;
  /** The product's own name ("Claude Code", "Codex"): never translated. */
  name: string;
  state: "missing" | "installing" | "failed" | "signedOut" | "unverified" | "signedIn";
}

export interface SetupState {
  agents: readonly SetupAgent[];
  /** `signInBackend`: signed out, what Sign In signs in to ("Signs in to cmux.com"), made by the app. */
  account: { signedIn: boolean; email?: string; signInBackend?: string };
  /** `missing`: no `cmux` on the login PATH; `other`: another cmux app's CLI (classic, a moved copy), which
   * Replace overwrites; `foreign`: a `cmux` that is no cmux app's, never touched; `fromImage`: cmux runs from
   * its disk image, so nothing installs until it runs from Applications; `installing`: an install runs. */
  cli: "missing" | "other" | "installed" | "foreign" | "fromImage" | "installing";
  /** Classic's saved session, when one was found and not answered yet; null: none (the row does not show). */
  classic: { workspaces: number; saved: string; answered?: "imported" | "declined" } | null;
  /** The app's text size and density (Set Up cmux's Text Size and Density row; David Beyer, Nov 20): `textSize` is
   * appearance.metrics.chromeFontSize in points or null (the density's own), `density` the density's id, `body` its
   * chrome body text in points. Null or absent: an app that has no such row (the row does not show). */
  look?: { textSize: number | null; density: string; body: number } | null;
  /** The card's Chief form (first-run findings rows 1 and 4): shown in Chief's chat because the agent Chief
   * answers through (Claude Code) is missing or signed out. Only the agents row, under a title that says why. */
  forChief?: boolean;
}

/** The card's title: what Chief needs in its Chief form, else Set Up cmux. */
export function setupTitle(state: SetupState, { t, format }: Strings): string {
  const agent = state.forChief ? state.agents[0] : undefined;
  return agent ? format("home.setup.chiefNeeds", agent.name) : t("home.setup.title");
}

export type SetupStepID = "agents" | "account" | "cli" | "classic" | "look";

/** What a row's button asks the host to do. */
export type SetupAction =
  | { kind: "installAgent"; id: string }
  | { kind: "signInAgent"; id: string }
  | { kind: "confirmAgent"; id: string }
  | { kind: "signInAccount" }
  | { kind: "installCLI" }
  | { kind: "setTextSize"; points: number | null }
  | { kind: "setDensity"; id: string }
  | { kind: "importClassic" }
  | { kind: "declineClassic" };

export interface SetupStep {
  id: SetupStepID;
  done: boolean;
  title: string;
  detail: string;
  /** The row's one button; absent once done (the slot keeps its room). */
  action?: { label: string; run: SetupAction };
  /** A quieter second button (classic's Not Now, the next agent); it stays while the row is busy, greyed
   * (`disabled`) when it waits on the run in flight. */
  secondary?: { label: string; run: SetupAction; disabled?: boolean };
  /** A third, quieter still: only while an agent waits for its sign-in to be confirmed and another agent
   * exists, so Sign In Again and the other agent both stay one click away. */
  tertiary?: { label: string; run: SetupAction };
  /** An action is running (an install): the slot shows a spinner. */
  busy?: boolean;
  /** A quiet line under the detail: the account row's backend while signed out ("Signs in to cmux.com"). */
  note?: string;
  /** A choice, not a to-do (Text Size and Density): never counted in the progress, never the next step, and its
   * controls sit under its words instead of in the slot. */
  optional?: boolean;
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
 * agents, account and the command line. */
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
  // Chief's form: the agents row is the whole card.
  if (state.forChief) return steps;
  steps.push({
    id: "account",
    done: state.account.signedIn,
    title: t("home.setup.account"),
    detail: state.account.signedIn ? (state.account.email ?? t("home.setup.signedIn")) : t("home.setup.account.detail"),
    ...(!state.account.signedIn && {
      action: { label: t("home.setup.signIn"), run: { kind: "signInAccount" } as const },
      ...(state.account.signInBackend ? { note: state.account.signInBackend } : {}),
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
  // Text Size and Density: a choice offered at the first run, never a to-do (its controls are the row's own).
  if (state.look)
    steps.push({
      id: "look",
      done: true,
      optional: true,
      title: t("home.setup.look"),
      detail: t("home.setup.look.detail"),
    });
  return steps;
}

/** The first row not done; undefined when every row is. */
export function nextStep(steps: readonly SetupStep[]): SetupStep | undefined {
  return steps.find((step) => !step.done && !step.optional);
}

/** Rows done of rows shown. */
export function setupProgress(steps: readonly SetupStep[]): { done: number; total: number } {
  const todos = steps.filter((step) => !step.optional);
  return { done: todos.filter((step) => step.done).length, total: todos.length };
}
