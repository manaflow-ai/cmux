import { useCallback, useEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import { type Native, rescanHarness, runInstallCommand } from "./harnessInstall";

/// What the install prompt installs, and the pick it was opened from.
export type HarnessInstallTarget = {
  /// The acpmux harness id (`chat.new`'s harness, `harness.health`'s id).
  harness: string;
  name: string;
  /// The brand its mark draws.
  mark: string;
  /// The command Install runs (harnessRows' INSTALL_COMMANDS); none: only its setup page.
  command?: string;
  docsUrl?: string;
};

export type HarnessInstallPhase =
  | { kind: "confirm" }
  | { kind: "installing"; line?: string }
  | { kind: "failed"; reason: string };

export type HarnessInstallState = {
  target: HarnessInstallTarget;
  phase: HarnessInstallPhase;
  /// Hide closes the dialog over a running install; a failure opens it again.
  open: boolean;
};

/// The pane's one-click install (cmux#38191). `request` opens the prompt for a harness and the pick
/// to make once it is there; `install` runs its command in place; when the command ends well acpmux
/// looks for the harness again, the catalog is read again, and the pick lands. One install at a
/// time: a request while one runs shows that one (a pick of the same harness replaces its pick).
/// `cancelPick` drops the pick when the person picks something else meanwhile. The callbacks keep
/// their identity, so the pane's context value does too.
export function useHarnessInstall({
  callNative,
  refreshCatalog,
}: {
  callNative: Native;
  refreshCatalog?(): Promise<void>;
}) {
  const t = useT();
  const [state, setState] = useState<HarnessInstallState>();
  const current = useRef<HarnessInstallState | undefined>(undefined);
  current.current = state;
  const then = useRef<(() => void) | undefined>(undefined);
  const cwd = useRef<string | undefined>(undefined);
  const live = useRef(true);
  const running = useRef(false);
  // The host calls and the catalog read of the latest render: an install outlives the render
  // that started it.
  const deps = useRef({ callNative, refreshCatalog, t });
  deps.current = { callNative, refreshCatalog, t };
  useEffect(() => {
    live.current = true;
    return () => {
      // The pane went away: a running install stops with it (runInstallCommand's live()).
      live.current = false;
    };
  }, []);
  const update = useCallback((next: (state: HarnessInstallState) => HarnessInstallState | undefined) => {
    if (live.current) setState((state) => (state ? next(state) : state));
  }, []);
  const finish = useCallback(() => {
    running.current = false;
    then.current = undefined;
    if (live.current) setState(undefined);
  }, []);

  const request = useCallback((target: HarnessInstallTarget, pick?: () => void, folder?: string) => {
    if (running.current) {
      // The same harness picked again: its newest pick lands when it is installed.
      if (current.current?.target.harness === target.harness && pick) then.current = pick;
      setState((state) => (state ? { ...state, open: true } : state));
      return;
    }
    then.current = pick;
    cwd.current = folder;
    setState({ target, phase: { kind: "confirm" }, open: true });
  }, []);

  const cancelPick = useCallback(() => {
    then.current = undefined;
  }, []);

  const install = useCallback(() => {
    const target = current.current?.target;
    if (!target?.command || running.current) return;
    running.current = true;
    update((state) => ({ ...state, phase: { kind: "installing" } }));
    const { callNative, t } = deps.current;
    void (async () => {
      try {
        // Straight from the click: the host runs a command only on the user's gesture.
        const ended = await runInstallCommand({
          callNative,
          command: target.command!,
          ...(cwd.current ? { cwd: cwd.current } : {}),
          live: () => live.current,
          onLine: (line) => update((state) => ({ ...state, phase: { kind: "installing", line } })),
          failedText: t("harnesses.commandFailed"),
        });
        if (ended === "stopped") return finish();
        await rescanHarness(callNative, target.harness);
        // The command installed it: a catalog read that fails is no install failure, and the
        // pick still starts the chat on it (acpmux has found it).
        await deps.current.refreshCatalog?.().catch(() => undefined);
        if (!live.current) return finish();
        const pick = then.current;
        finish();
        pick?.();
      } catch (error) {
        running.current = false;
        // A failure shows even when the dialog was hidden.
        update((state) => ({
          ...state,
          open: true,
          phase: { kind: "failed", reason: error instanceof Error ? error.message : String(error) },
        }));
      }
    })();
  }, [finish, update]);

  /// Cancel before an install drops the pick; Hide during one keeps it running (and its pick).
  const dismiss = useCallback(() => {
    if (running.current) {
      setState((state) => (state ? { ...state, open: false } : state));
      return;
    }
    finish();
  }, [finish]);

  const setupGuide = useCallback(() => {
    const url = current.current?.target.docsUrl;
    if (!url) return;
    void deps.current.callNative("tab.open", { kind: "browser", text: url, keep: true }).catch(() => undefined);
    if (!running.current) finish();
  }, [finish]);

  return { state, request, cancelPick, install, dismiss, setupGuide };
}
