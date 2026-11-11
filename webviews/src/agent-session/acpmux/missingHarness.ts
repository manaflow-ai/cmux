// A chat that could not start because its agent CLI is not on this Mac (MissingHarnessNotice.tsx):
// which agent, what the notice offers, and the one flow its Install runs (Leo 2026-11-11: a friend
// "tried to start a chat, didn't have Claude or Codex installed, ran into" setup text "and then
// there was no recovery mechanism"). Install is the model picker's own in-place install
// (harnessSetup.ts: the installer, acpmux's rescan, a sign-in when the CLI is signed out); once the
// agent is ready the failed start runs again and the message the person typed, which the failed
// start handed back to the composer, goes.
import { useEffect, useRef } from "react";
import { CHIEF_FAMILY } from "./agents";
import {
  clearHarnessSetup,
  type SetupDeps,
  signInHarnessSetup,
  startHarnessSetup,
  useHarnessSetup,
} from "./harnessSetup";
import { INSTALL_COMMANDS } from "./harnesses/harnessRows";
import type { AcpmuxSnapshot } from "./model";
import type { PickerCatalog } from "./modelCatalogData";
import type { MissingHarnessNoticeProps } from "./MissingHarnessNotice";
import { startNotInstalled } from "./startFailure";

/// acpmux's built-in UniiChat harness: like the Chief, a chat starts on it only when it is picked.
const UNII_FAMILY = "unii";

/// The agent this Mac has that a chat can start on instead of `missing`: a coding agent that runs
/// (installed, pickable, not unavailable), never the Chief or UniiChat. Codex, then Claude Code,
/// then the catalog's order.
export function installedAlternative(
  catalog: PickerCatalog | undefined,
  missing: string,
): { harness: string; name: string } | undefined {
  const usable = (catalog?.harnesses ?? []).filter((entry) => {
    const id = entry.acpmuxHarness;
    const family = entry.family ?? id;
    return (
      id !== null &&
      id !== missing &&
      entry.installed &&
      entry.pickable &&
      (!entry.unavailable || entry.probeFailed === true) &&
      family !== CHIEF_FAMILY &&
      family !== UNII_FAMILY
    );
  });
  const rank = (id: string | null) => (id === "codex" ? 0 : id === "claude" ? 1 : 2);
  const best = [...usable].sort((a, b) => rank(a.acpmuxHarness) - rank(b.acpmuxHarness))[0];
  return best?.acpmuxHarness ? { harness: best.acpmuxHarness, name: best.name } : undefined;
}

/// The failed start the notice answers: a chat on this Mac whose agent is not installed.
export function missingStart(
  switching: AcpmuxSnapshot["switching"],
  local: boolean,
): NonNullable<AcpmuxSnapshot["switching"]> | undefined {
  return local && switching?.phase === "failed" && startNotInstalled(switching) ? switching : undefined;
}

export type MissingHarnessDeps = {
  switching: AcpmuxSnapshot["switching"];
  /// Prompts of a chat with no session yet that acpmux refused as not installed (sendFailure.ts
  /// `not-installed`): a send with no agent named, on a Mac with no coding agent.
  failedRows: readonly string[];
  /// The agent such a send asked for: the composer's (its chip's), which acpmux's own default
  /// would also be (Claude Code when this Mac has none).
  composerHarness?: { harness: string; name: string };
  /// The chat runs on this Mac: an installer runs only here.
  local: boolean;
  catalog: PickerCatalog | undefined;
  /// The host calls an install makes (`shell.run`, `shell.read`, `shell.stop`, `harness.health`
  /// answered by this Mac's acpmux, `chat.new`).
  native: SetupDeps["native"];
  /// The chat's folder: where the installer and the login run.
  cwd?: string;
  refreshCatalog?(): Promise<void>;
  /// Opens the agent's login in a terminal tab; false when the host refused.
  logIn(harness: string, login: string): Promise<boolean>;
  /// Starts the failed start again (`chat.harness.retry`).
  retry(): Promise<unknown>;
  /// Sends the composer's message (the prompt the failed start handed back).
  send(): void;
  /// Sends the refused prompts again (the failure card's Retry), or takes them back into the
  /// composer (its Edit).
  retryRows(rowIds: readonly string[]): void;
  editRows(rowIds: readonly string[]): void;
  /// The agents page, for an agent cmux has no installer for.
  setUp(): void;
  /// How often a sign-in started here is checked (harnessSetup.ts); tests shorten it.
  pollMs?: number;
};

/// The notice's props while a chat's agent is missing (or its install runs), else undefined.
export function useMissingHarness(deps: MissingHarnessDeps): MissingHarnessNoticeProps | undefined {
  const setup = useHarnessSetup();
  const latest = useRef(deps);
  latest.current = deps;
  /// An install this notice started (`from: "notice"`): its ready step starts the chat here. A pick
  /// in the model menu replaces it, and the notice no longer drives that one.
  const ours = setup?.pick.from === "notice" ? setup : undefined;
  const ready = ours?.phase.kind === "ready";
  useEffect(() => {
    if (!ready) return;
    // The chat starts here, not in the model menu's own ready step (it would only pick a model).
    clearHarnessSetup();
    const { switching, local, failedRows, retry, send, retryRows } = latest.current;
    if (missingStart(switching, local)) void retry().then(send, () => undefined);
    else if (failedRows.length) retryRows(failedRows);
  }, [ready]);
  const failed = missingStart(deps.switching, deps.local);
  const refused = deps.local && deps.failedRows.length > 0 ? deps.composerHarness : undefined;
  const target = failed
    ? { harness: failed.harness, name: failed.name }
    : (refused ?? (ours ? { harness: ours.pick.harness, name: ours.pick.name } : undefined));
  if (!target) return undefined;
  const install = INSTALL_COMMANDS[target.harness];
  const alternative = installedAlternative(deps.catalog, target.harness);
  return {
    name: target.name,
    ...(ours ? { phase: ours.phase } : {}),
    installable: install !== undefined,
    ...(alternative ? { alternative: alternative.name } : {}),
    onInstall: () => {
      const { catalog, native, cwd, refreshCatalog, logIn, pollMs } = latest.current;
      const entry = catalog?.harnesses.find(
        (candidate) => (candidate.acpmuxHarness ?? candidate.id) === target.harness,
      );
      // Straight from the click: the host runs an installer only on the person's gesture.
      startHarnessSetup(
        {
          harness: target.harness,
          name: target.name,
          model: entry?.defaultModel ?? entry?.models[0]?.id ?? "default",
          from: "notice",
        },
        {
          native,
          ...(cwd ? { cwd } : {}),
          ...(install ? { install } : {}),
          ...(entry?.docsUrl ? { docsUrl: entry.docsUrl } : {}),
          ...(refreshCatalog ? { refreshCatalog } : {}),
          logIn: (login) => logIn(target.harness, login),
          ...(pollMs ? { pollMs } : {}),
        },
      );
    },
    ...(alternative
      ? {
          onUseInstead: () => {
            const { native, cwd, send, failedRows, editRows } = latest.current;
            // Refused prompts come back to the composer first; the chat then starts there with them.
            if (failedRows.length) editRows(failedRows);
            void native("chat.new", { harness: alternative.harness, ...(cwd ? { cwd } : {}) }).then(
              send,
              () => undefined,
            );
          },
        }
      : {}),
    onSignIn: signInHarnessSetup,
    onSetUp: () => latest.current.setUp(),
  };
}
