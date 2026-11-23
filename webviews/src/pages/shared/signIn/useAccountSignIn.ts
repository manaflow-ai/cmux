// The in-place sign-in's controller (logins done right), one for every page that signs accounts
// in: Settings > Accounts (`cmux.settings.accounts.run`) and onboarding's agents step
// (`cmux.onboarding.accounts.run`) pass their own transport; the gestures, the replies and what
// the card shows are the same. Leo, 2026-11-22: "WE ABSOLUELY MUST ERR ON THE SIDE OF BEING NOT
// ANNOYING". One click starts the daemon's sign-in, the code goes on the clipboard and shows in
// the card, an approve-in-page or device code finishes by itself, an expired code says so, and a
// finished sign-in shows "Signed in as" for a moment. The code lives in this hook's state only:
// never a store, a log or a data attribute.
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { copyTextResult } from "../../../agent-session/acpmux/conversation/clipboard";
import {
  ACCOUNT_ACTIONS,
  failedView,
  parseSignInFinish,
  parseSignInStart,
  signInFailure,
  type AccountFamily,
  type AccountRowWire,
  type AccountRunParams,
  type AccountRunResult,
  type SignInStarted,
} from "./accountSignIn";
import type { ActiveSignIn } from "./AccountSwitcher";
import type { DeviceSignInCardProps } from "./DeviceSignInCard";

/** A finished sign-in's "Signed in as" stays this long, then the row is just the account. */
export const SIGNED_IN_SHOWN_MS = 4000;

/** How a page reaches its host. */
export type AccountSignInTransport = {
  run(params: AccountRunParams): Promise<AccountRunResult>;
  /** A host that answers a start without a sign-in: the page's older (terminal) sign-in. */
  fallback?(family: AccountFamily, account: string | null): void;
};

export type AccountSignInController = {
  /** The sign-in in progress or just ended, for the card; null when there is none. */
  running: ActiveSignIn | null;
  /** The account a Use, Sign Out or Remove runs on. */
  busy: string | null;
  /** `name`: a new account's typed name (only with no `account`). */
  start(family: AccountFamily, account: string | null, name?: string): void;
  cancel(): void;
  gesture(action: string, account: AccountRowWire): void;
  /** The card's gestures for `running`. */
  card: Omit<DeviceSignInCardProps, "family" | "view" | "look">;
};

type Running = ActiveSignIn & { loginId: string | null; started: SignInStarted | null; name?: string };

export function useAccountSignIn(transport: AccountSignInTransport): AccountSignInController {
  const [running, setRunning] = useState<Running | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  // The latest transport, so the gestures stay the same functions across renders.
  const via = useRef(transport);
  via.current = transport;
  // The login the card belongs to: an answer for an older one (cancelled, retried) is dropped.
  const current = useRef<string | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const clearTimer = () => {
    if (timer.current) clearTimeout(timer.current);
    timer.current = null;
  };
  useEffect(() => clearTimer, []);

  const failed = useCallback(
    (family: AccountFamily, account: string | null, reply: AccountRunResult, name?: string) => {
      const failure = reply.ok ? signInFailure({ reason: reply.value.reason }) : signInFailure(reply.error);
      setRunning({
        family,
        account,
        loginId: null,
        started: null,
        view: failedView(failure),
        ...(name ? { name } : {}),
      });
    },
    [],
  );

  const finish = useCallback(
    async (run: Running, code?: string) => {
      if (!run.loginId) return;
      const loginId = run.loginId;
      const reply = await via.current.run({ action: ACCOUNT_ACTIONS.finish, loginId, ...(code ? { code } : {}) });
      if (current.current !== loginId) return;
      clearTimer();
      current.current = null;
      const finished = reply.ok ? parseSignInFinish(reply.value.finished) : undefined;
      if (!reply.ok || !finished || !finished.signedIn || reply.value.reason) {
        failed(run.family, run.account, reply, run.name);
        return;
      }
      setRunning({
        ...run,
        loginId: null,
        started: null,
        view: { state: "signedIn", account: finished.account || null },
      });
      timer.current = setTimeout(
        () => setRunning((now) => (now?.view.state === "signedIn" ? null : now)),
        SIGNED_IN_SHOWN_MS,
      );
    },
    [failed],
  );

  const start = useCallback(
    async (family: AccountFamily, account: string | null, name?: string) => {
      clearTimer();
      const previous = current.current;
      current.current = null;
      if (previous) void via.current.run({ action: ACCOUNT_ACTIONS.cancel, loginId: previous });
      const named = !account && name?.trim() ? name.trim() : undefined;
      setRunning({ family, account, loginId: null, started: null, view: { state: "starting" } });
      const reply = await via.current.run({
        action: ACCOUNT_ACTIONS.start,
        provider: family,
        family,
        ...(account ? { account } : {}),
        ...(named ? { name: named } : {}),
      });
      if (!reply.ok || reply.value.reason) {
        failed(family, account, reply, named);
        return;
      }
      const started = parseSignInStart(reply.value.signIn);
      if (!started) {
        setRunning(null);
        via.current.fallback?.(family, account);
        return;
      }
      current.current = started.loginId;
      const copied = started.way.kind === "code" ? await copyTextResult(started.way.code) : false;
      if (current.current !== started.loginId) return;
      const run: Running = {
        family,
        account: started.account,
        loginId: started.loginId,
        started,
        ...(named ? { name: named } : {}),
        view: { state: "waiting", way: started.way, copied, url: started.url },
      };
      setRunning(run);
      if (Number.isFinite(started.expiresAtMs)) {
        timer.current = setTimeout(
          () => {
            if (current.current !== started.loginId) return;
            current.current = null;
            void via.current.run({ action: ACCOUNT_ACTIONS.cancel, loginId: started.loginId });
            setRunning({ ...run, loginId: null, started: null, view: { state: "expired" } });
          },
          Math.max(0, started.expiresAtMs - Date.now()),
        );
      }
      // Approve-in-page and device codes finish by themselves; a pasted code waits for Continue.
      if (started.way.kind !== "paste") void finish(run);
    },
    [failed, finish],
  );

  const cancel = useCallback(() => {
    clearTimer();
    const loginId = current.current;
    current.current = null;
    setRunning(null);
    if (loginId) void via.current.run({ action: ACCOUNT_ACTIONS.cancel, loginId });
  }, []);

  const gesture = useCallback(async (action: string, account: AccountRowWire) => {
    setBusy(account.id);
    await via.current.run({ action, account: account.id, provider: account.family });
    setBusy(null);
  }, []);

  const card = useMemo<AccountSignInController["card"]>(
    () => ({
      onCopy: () => {
        const way = running?.started?.way;
        if (way?.kind !== "code" || !running) return;
        void copyTextResult(way.code).then((copied) =>
          setRunning((now) =>
            now && now.loginId === running.loginId && now.view.state === "waiting"
              ? { ...now, view: { ...now.view, copied } }
              : now,
          ),
        );
      },
      onCancel: cancel,
      onRetry: () => running && void start(running.family, running.account, running.name),
      onDone: () => {
        clearTimer();
        setRunning(null);
      },
      onSubmitCode: (code) => {
        if (!running || running.view.state !== "waiting") return;
        setRunning({ ...running, view: { ...running.view, busy: true } });
        void finish(running, code);
      },
    }),
    [running, cancel, start, finish],
  );

  return {
    running,
    busy,
    start: (family, account, name) => void start(family, account, name),
    cancel,
    gesture: (action, account) => void gesture(action, account),
    card,
  };
}
