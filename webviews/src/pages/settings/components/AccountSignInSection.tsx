// Settings > Accounts' in-place sign-in (logins done right). Leo, 2026-11-22: "we likewise want gh
// auth or device stuff to be much more convienient ui/ux wise ... WE ABSOLUELY MUST ERR ON THE SIDE
// OF BEING NOT ANNOYING". One click on Add account or Sign in starts the daemon's sign-in through
// the host (`cmux.settings.accounts.run`, shared/signIn ACCOUNT_ACTIONS); the host opens the
// provider's page in the app's browser pane, the code goes on the clipboard and shows in the row,
// and the row turns into the signed-in account by itself. Drawn only when the host lists the
// accounts (`accounts.signInAccounts`); an older host keeps the terminal sign-in (Agents >
// Harnesses), and a host that answers a start without a sign-in gets the same terminal gesture.
// The code lives in this component's state only: never the store, a log or a data attribute.
import { useCallback, useEffect, useRef, useState } from "react";
import { copyTextResult } from "../../../agent-session/acpmux/conversation/clipboard";
import { useSettingsState, useStore } from "../context";
import type { AccountsRunReply } from "../ops";
import type { Reply } from "../store";
import {
  ACCOUNT_ACTIONS,
  failedView,
  parseAccountRow,
  parseSignInFinish,
  parseSignInStart,
  signInFailure,
  type AccountFamily,
  type AccountRowWire,
  type SignInStarted,
} from "../../shared/signIn/accountSignIn";
import { AccountSwitcher, type ActiveSignIn } from "../../shared/signIn/AccountSwitcher";

/** A finished sign-in's "Signed in as" stays this long, then the row is just the account. */
const SIGNED_IN_SHOWN_MS = 4000;

type Running = ActiveSignIn & { loginId: string | null; started: SignInStarted | null };

export function AccountSignInSection() {
  const store = useStore();
  const listed = useSettingsState().accounts?.signInAccounts;
  const [running, setRunning] = useState<Running | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  // The login the card belongs to: an answer for an older one (cancelled, retried) is dropped.
  const current = useRef<string | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const clearTimer = () => {
    if (timer.current) clearTimeout(timer.current);
    timer.current = null;
  };
  useEffect(() => clearTimer, []);

  const failed = useCallback((family: AccountFamily, account: string | null, reply: Reply<AccountsRunReply>) => {
    const failure = reply.ok ? signInFailure({ reason: reply.value.reason }) : signInFailure(reply.error);
    setRunning({ family, account, loginId: null, started: null, view: failedView(failure) });
  }, []);

  const finish = useCallback(
    async (run: Running, code?: string) => {
      if (!run.loginId) return;
      const loginId = run.loginId;
      const reply = await store.runAccountSignIn({
        action: ACCOUNT_ACTIONS.finish,
        loginId,
        ...(code ? { code } : {}),
      });
      if (current.current !== loginId) return;
      clearTimer();
      current.current = null;
      const finished = reply.ok ? parseSignInFinish(reply.value.finished) : undefined;
      if (!reply.ok || !finished || !finished.signedIn || reply.value.reason) {
        failed(run.family, run.account, reply);
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
    [store, failed],
  );

  const start = useCallback(
    async (family: AccountFamily, account: string | null) => {
      clearTimer();
      const previous = current.current;
      current.current = null;
      if (previous) void store.runAccountSignIn({ action: ACCOUNT_ACTIONS.cancel, loginId: previous });
      setRunning({ family, account, loginId: null, started: null, view: { state: "starting" } });
      const reply = await store.runAccountSignIn({
        action: ACCOUNT_ACTIONS.start,
        provider: family,
        family,
        ...(account ? { account } : {}),
      });
      if (!reply.ok || reply.value.reason) {
        failed(family, account, reply);
        return;
      }
      const started = parseSignInStart(reply.value.signIn);
      if (!started) {
        // A host that does not sign in in place: the terminal sign-in, as Agents > Harnesses runs it.
        setRunning(null);
        if (family !== "github")
          void store.runHarnesses(
            account ? { action: "accountSignIn", account } : { action: "accountAdd", family, way: "new" },
          );
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
        view: { state: "waiting", way: started.way, copied, url: started.url },
      };
      setRunning(run);
      if (Number.isFinite(started.expiresAtMs)) {
        timer.current = setTimeout(
          () => {
            if (current.current !== started.loginId) return;
            current.current = null;
            void store.runAccountSignIn({ action: ACCOUNT_ACTIONS.cancel, loginId: started.loginId });
            setRunning({ ...run, loginId: null, started: null, view: { state: "expired" } });
          },
          Math.max(0, started.expiresAtMs - Date.now()),
        );
      }
      // Approve-in-page and device codes finish by themselves; a pasted code waits for Continue.
      if (started.way.kind !== "paste") void finish(run);
    },
    [store, failed, finish],
  );

  const cancel = useCallback(() => {
    clearTimer();
    const loginId = current.current;
    current.current = null;
    setRunning(null);
    if (loginId) void store.runAccountSignIn({ action: ACCOUNT_ACTIONS.cancel, loginId });
  }, [store]);

  const gesture = useCallback(
    async (action: string, account: AccountRowWire) => {
      setBusy(account.id);
      await store.runAccountSignIn({ action, account: account.id, provider: account.family });
      setBusy(null);
    },
    [store],
  );

  if (!Array.isArray(listed)) return null;
  const accounts = listed.flatMap((raw) => parseAccountRow(raw) ?? []);
  return (
    <div className="accounts-sign-in" data-card="account-sign-in">
      <AccountSwitcher
        accounts={accounts}
        signIn={running}
        busy={busy}
        look="inline"
        onAdd={(family) => void start(family, null)}
        onSignIn={(account) => void start(account.family, account.id)}
        onUse={(account) => void gesture(ACCOUNT_ACTIONS.switch, account)}
        onSignOut={(account) => void gesture(ACCOUNT_ACTIONS.signOut, account)}
        onRemove={(account) => void gesture(ACCOUNT_ACTIONS.remove, account)}
        card={{
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
          onRetry: () => running && void start(running.family, running.account),
          onDone: () => {
            clearTimer();
            setRunning(null);
          },
          onSubmitCode: (code) => {
            if (!running || running.view.state !== "waiting") return;
            setRunning({ ...running, view: { ...running.view, busy: true } });
            void finish(running, code);
          },
        }}
      />
    </div>
  );
}
