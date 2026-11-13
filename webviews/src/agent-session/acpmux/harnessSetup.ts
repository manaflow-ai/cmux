// A model picked whose harness this Mac cannot run yet (Lawrence 2026-11-07: "we should make it
// possible to search for any model in cmux model picker and it needs to 'just work' aka download
// the relevant harness"): its CLI installs in place (the Harnesses page's own install command, run
// on the host; no terminal), acpmux looks for it again, a signed-out harness signs in through its
// login (the same terminal tab Log In opens), and then the composer starts the chat on the picked
// model (ComposerPickers). One setup at a time, page-wide, so the model menu and its chip show the
// same progress however often the menu opens and closes; a new pick replaces it.
import { useSyncExternalStore } from "react";
import { type HarnessHealth, needsLogin } from "./harnessHealthNoticeModel";
import { HostCommandFailed, runHostCommand } from "./harnesses/hostCommand";

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// The pick waiting on its harness: what the chat starts on once the harness can run.
export type SetupPick = {
  /// The harness id the pick names (acpmux's, else the catalog's for one acpmux has not listed).
  harness: string;
  /// Its display name ("Gemini CLI").
  name: string;
  model: string;
  effort?: string;
  fast?: boolean;
};

/// Where the setup is: its CLI installing (`line`: the installer's last output line); acpmux
/// looking for it and its sign-in checked; a sign-in that waits for the person's Sign In click (the
/// install spent the pick's gesture, and the host opens a login terminal only on one); a login
/// terminal open, checked until it lands; ready (the composer starts the chat once acpmux lists the
/// harness); or failed (`reason`: the installer's last line, else a pane string key).
export type SetupPhase =
  | { kind: "installing"; line?: string }
  | { kind: "checking" }
  | { kind: "signIn" }
  | { kind: "signingIn" }
  | { kind: "ready" }
  | { kind: "failed"; reason?: string; reasonKey?: "harnesses.commandFailed" | "harnesses.stillCannotRun" };

export type HarnessSetup = { pick: SetupPick; phase: SetupPhase; docsUrl?: string };

export type SetupDeps = {
  native: Native;
  /// The chat's folder: where the install and the login run.
  cwd?: string;
  /// The command that installs the harness's CLI (harnessRows.ts INSTALL_COMMANDS); absent when the
  /// harness is installed and only signed out.
  install?: string;
  /// The login command acpmux last named for the harness, when it found it signed out.
  login?: string;
  /// The harness's setup page, offered when the install fails.
  docsUrl?: string;
  /// Reads acpmux's harness list and the model catalog again, once acpmux looked again.
  refreshCatalog?(): Promise<void>;
  /// Opens `login` in a terminal tab (SignIn.logIn); false when the host refused it.
  logIn(login: string): Promise<boolean>;
  /// How often a login started here is checked, and for how long.
  pollMs?: number;
  waitMs?: number;
  /// How long a ready harness may take to show in acpmux's list before the setup says it cannot run.
  listMs?: number;
};

const POLL_MS = 3000;
const WAIT_MS = 3 * 60 * 1000;
const LIST_MS = 20_000;

let current: HarnessSetup | undefined;
let deps: SetupDeps | undefined;
/// The login command a waiting sign-in runs.
let login: string | undefined;
/// Bumped by every new pick, cancel and reset: work of an older one stops at its next step.
let generation = 0;
let timer: ReturnType<typeof setTimeout> | undefined;
const listeners = new Set<() => void>();

function publish(next: HarnessSetup | undefined) {
  current = next;
  for (const listener of listeners) listener();
}

function phase(run: number, next: SetupPhase) {
  if (run !== generation || !current) return;
  if (timer) clearTimeout(timer);
  timer = undefined;
  publish({ ...current, phase: next });
  // A ready harness acpmux never lists (an install that put the CLI where acpmux does not look)
  // fails rather than leaving the chip on Starting.
  if (next.kind === "ready")
    timer = setTimeout(
      () => phase(run, { kind: "failed", reasonKey: "harnesses.stillCannotRun" }),
      deps?.listMs ?? LIST_MS,
    );
}

const alive = (run: number) => run === generation;

/// The harness's health as acpmux checks it now (`rescan`: after an install, it looks for the CLI
/// again first); undefined when the host did not answer.
async function health(run: number, setup: SetupDeps, id: string, rescan: boolean): Promise<HarnessHealth | undefined> {
  try {
    const reply = (await setup.native("harness.health", {
      id,
      refresh: true,
      ...(rescan ? { rescan: true } : {}),
    })) as {
      health?: HarnessHealth | null;
    } | null;
    return reply?.health ?? { id, auth: "unknown" };
  } catch {
    return undefined;
  } finally {
    if (alive(run)) await setup.refreshCatalog?.().catch(() => undefined);
  }
}

/// One pick's setup: install (when it needs one), look again, sign in (when it needs one), ready.
/// `gesture`: the pick's own gesture is still unspent, so a login terminal may open at once.
async function setUp(run: number, setup: SetupDeps, id: string, gesture: boolean) {
  if (setup.install) {
    phase(run, { kind: "installing" });
    try {
      const ended = await runHostCommand(setup.native, setup.install, {
        ...(setup.cwd ? { cwd: setup.cwd } : {}),
        alive: () => alive(run),
        onLine: (line) => phase(run, { kind: "installing", line }),
      });
      if (ended === "stopped") return;
    } catch (error) {
      phase(
        run,
        error instanceof HostCommandFailed
          ? error.line
            ? { kind: "failed", reason: error.line }
            : { kind: "failed", reasonKey: "harnesses.commandFailed" }
          : { kind: "failed", reason: error instanceof Error ? error.message : String(error) },
      );
      return;
    }
    // The install spent the pick's gesture: a login terminal now needs the person's own click.
    gesture = false;
  }
  if (!alive(run)) return;
  phase(run, { kind: "checking" });
  const checked = await health(run, setup, id, setup.install !== undefined);
  if (!alive(run)) return;
  // Signed out by this check, or by acpmux's last one when this one went unanswered (a harness
  // acpmux found signed out never starts a chat on no evidence). An unanswered check of a harness
  // with no such report is no evidence of a problem: the chat's own start says.
  const signedOut = checked ? needsLogin(checked.auth) : !setup.install && setup.login !== undefined;
  if (!signedOut) {
    phase(run, { kind: "ready" });
    return;
  }
  login = checked?.login?.trim() || setup.login;
  if (gesture && login) await signIn(run, setup, id);
  else phase(run, { kind: "signIn" });
}

/// Opens the login terminal and waits (bounded) until acpmux finds the harness signed in.
async function signIn(run: number, setup: SetupDeps, id: string) {
  if (!login) return;
  // Signing in from here on, so a second click while the host opens the tab opens no second one.
  phase(run, { kind: "signingIn" });
  if (!(await setup.logIn(login).catch(() => false))) {
    phase(run, { kind: "signIn" });
    return;
  }
  const ends = Date.now() + (setup.waitMs ?? WAIT_MS);
  while (alive(run) && Date.now() < ends) {
    await new Promise((resolve) => setTimeout(resolve, setup.pollMs ?? POLL_MS));
    if (!alive(run)) return;
    // Only an answered check ends the wait: an unanswered one is no sign-in.
    const checked = await health(run, setup, id, false);
    if (checked && !needsLogin(checked.auth)) {
      phase(run, { kind: "ready" });
      return;
    }
  }
  // The wait ended: Sign In again is the person's.
  phase(run, { kind: "signIn" });
}

/// Starts setting up `pick`'s harness, replacing any setup still running (its command stops).
/// Call it straight from the pick: the install and a login terminal run on the pick's gesture.
export function startHarnessSetup(pick: SetupPick, next: SetupDeps): void {
  const run = ++generation;
  deps = next;
  login = next.login;
  if (timer) clearTimeout(timer);
  timer = undefined;
  publish({
    pick,
    phase: next.install ? { kind: "installing" } : { kind: "checking" },
    ...(next.docsUrl ? { docsUrl: next.docsUrl } : {}),
  });
  void setUp(run, next, pick.harness, true);
}

/// The strip's Sign In: opens the login terminal on this click, then waits for the sign-in.
export function signInHarnessSetup(): void {
  if (current?.phase.kind !== "signIn" || !deps) return;
  void signIn(generation, deps, current.pick.harness);
}

/// Try Again on a failed setup: the same pick, from its start.
export function retryHarnessSetup(): void {
  if (!current || !deps || current.phase.kind !== "failed") return;
  startHarnessSetup(current.pick, deps);
}

/// Drops the setup: Cancel, or the composer took the ready pick and starts the chat.
export function clearHarnessSetup(): void {
  generation++;
  if (timer) clearTimeout(timer);
  timer = undefined;
  deps = undefined;
  login = undefined;
  if (current) publish(undefined);
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/// The setup a pick started, if any.
export function useHarnessSetup(): HarnessSetup | undefined {
  return useSyncExternalStore(
    subscribe,
    () => current,
    () => current,
  );
}

/// Test seam: no setup, and nothing of an earlier one still running.
export function resetHarnessSetupForTests(): void {
  clearHarnessSetup();
}
