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

/// The model picker's one-click install (cmux#38191). `request` opens the prompt for a harness and
/// the pick to make once it is there (`then`); `install` runs its command in place; when the
/// command ends well acpmux looks for the harness again, the catalog is read again, and `then`
/// makes the pick. One install at a time: a request while one runs shows that one.
export function useHarnessInstall({
  callNative,
  cwd,
  refreshCatalog,
}: {
  callNative: Native;
  cwd?: string;
  refreshCatalog?(): Promise<void>;
}) {
  const t = useT();
  const [state, setState] = useState<HarnessInstallState>();
  const then = useRef<(() => void) | undefined>(undefined);
  const live = useRef(true);
  const running = useRef(false);
  useEffect(() => {
    live.current = true;
    return () => {
      // The composer went away: a running install stops with it (runInstallCommand's live()).
      live.current = false;
    };
  }, []);
  const update = (next: (current: HarnessInstallState) => HarnessInstallState | undefined) => {
    if (live.current) setState((current) => (current ? next(current) : current));
  };

  const request = useCallback((target: HarnessInstallTarget, pick?: () => void) => {
    if (running.current) {
      setState((current) => (current ? { ...current, open: true } : current));
      return;
    }
    then.current = pick;
    setState({ target, phase: { kind: "confirm" }, open: true });
  }, []);

  const install = useCallback(() => {
    const target = state?.target;
    if (!target?.command || running.current) return;
    running.current = true;
    update((current) => ({ ...current, phase: { kind: "installing" } }));
    void (async () => {
      try {
        // Straight from the click: the host runs a command only on the user's gesture.
        const ended = await runInstallCommand({
          callNative,
          command: target.command!,
          cwd,
          live: () => live.current,
          onLine: (line) => update((current) => ({ ...current, phase: { kind: "installing", line } })),
          failedText: t("harnesses.commandFailed"),
        });
        if (ended === "stopped") return;
        await rescanHarness(callNative, target.harness);
        await refreshCatalog?.();
        if (!live.current) return;
        running.current = false;
        setState(undefined);
        const pick = then.current;
        then.current = undefined;
        pick?.();
      } catch (error) {
        running.current = false;
        // A failure shows even when the dialog was hidden.
        update((current) => ({
          ...current,
          open: true,
          phase: { kind: "failed", reason: error instanceof Error ? error.message : String(error) },
        }));
      }
    })();
  }, [callNative, cwd, refreshCatalog, state?.target, t]);

  /// Cancel before an install drops the pick; Hide during one keeps it running (and its pick).
  const dismiss = useCallback(() => {
    if (running.current) {
      setState((current) => (current ? { ...current, open: false } : current));
      return;
    }
    then.current = undefined;
    setState(undefined);
  }, []);

  const setupGuide = useCallback(() => {
    const url = state?.target.docsUrl;
    if (!url) return;
    void callNative("tab.open", { kind: "browser", text: url, keep: true }).catch(() => undefined);
    if (!running.current) {
      then.current = undefined;
      setState(undefined);
    }
  }, [callNative, state?.target.docsUrl]);

  return { state, request, install, dismiss, setupGuide };
}
