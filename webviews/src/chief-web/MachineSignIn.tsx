import { useCallback, useEffect, useRef, useState } from "react";
import type { LoginAgent, LoginStart } from "../agent-session/acpmux/cloudAgentLogin";
import { Spinner } from "../agent-session/acpmux/conversation/icons";
import { useT } from "../agent-session/acpmux/i18n";
import { MachineLoginError, type MachineLoginApi, type MachineLoginStatus } from "./machineLogin";
import { ExpiredSession } from "./wire";

type State = {
  phase: "checking" | "ready" | "starting" | "finishing" | "hidden";
  harness?: LoginAgent;
  login?: LoginStart;
  error?: "failed" | "expired" | "badCode" | "busy";
  recover?: boolean;
};
/** This card resumes its existing run at the server; it never submits a chat message. */
export function MachineSignIn({ run, api, onExpired }: { run: string; api: MachineLoginApi; onExpired(): void }) {
  const t = useT();
  const [state, setState] = useState<State>({ phase: "checking" });
  const [code, setCode] = useState("");
  const active = useRef<AbortController | undefined>(undefined);
  const alive = useRef(true);
  const expired = useRef(onExpired);
  expired.current = onExpired;
  const begin = () => {
    active.current?.abort();
    const controller = new AbortController();
    active.current = controller;
    return controller;
  };
  const current = useCallback((controller: AbortController) => alive.current && !controller.signal.aborted, []);
  const failure = useCallback(
    (error: unknown, controller: AbortController, recover = false) => {
      if (!current(controller)) return;
      setCode("");
      if (error instanceof ExpiredSession) {
        setState({ phase: "hidden" });
        expired.current();
      } else if (error instanceof MachineLoginError && error.status === 404) setState({ phase: "hidden" });
      else if (
        error instanceof MachineLoginError &&
        (error.status === 410 || error.code === "chief.machine.login_changed")
      )
        setState((old) => ({ ...old, phase: "ready", login: undefined, error: "expired", recover: false }));
      else
        setState((old) => ({
          ...old,
          phase: "ready",
          recover,
          error: error instanceof MachineLoginError && error.status === 409 ? "busy" : "failed",
        }));
    },
    [current],
  );
  const status = useCallback(
    (value: MachineLoginStatus, controller: AbortController) => {
      if (!current(controller)) return;
      if ("resumed" in value) setState({ phase: "hidden" });
      else setState({ phase: "ready", harness: value.harness, login: value.login ?? undefined });
    },
    [current],
  );
  const refresh = () => {
    const controller = begin();
    setState((old) => ({ ...old, phase: "checking", error: undefined }));
    void api.status(run, controller.signal).then(
      (value) => status(value, controller),
      (error) => failure(error, controller),
    );
  };
  useEffect(() => {
    alive.current = true;
    const controller = new AbortController();
    active.current = controller;
    void api.status(run, controller.signal).then(
      (value) => status(value, controller),
      (error) => failure(error, controller),
    );
    return () => {
      alive.current = false;
      active.current?.abort();
    };
  }, [api, run, status, failure]);
  const expiry = state.login?.expiresAtMs;
  useEffect(() => {
    if (expiry === undefined || state.phase === "finishing") return;
    const timer = setTimeout(
      () => {
        active.current?.abort();
        setCode("");
        setState((old) => ({
          ...old,
          phase: "ready",
          login: undefined,
          error: "expired",
          recover: false,
        }));
      },
      Math.max(0, Math.min(2_147_483_647, expiry - Date.now())),
    );
    return () => clearTimeout(timer);
  }, [expiry, state.phase]);
  const start = () => {
    const controller = begin();
    setCode("");
    setState((old) => ({ ...old, phase: "starting", error: undefined, recover: false }));
    void api.start(run, controller.signal).then(
      (login) => {
        if (!current(controller)) return;
        setState((old) => ({ ...old, phase: "ready", login }));
        // Browsers may block a popup after the request; the same validated link stays visible.
        window.open(login.url, "_blank", "noopener,noreferrer");
      },
      (error) => failure(error, controller),
    );
  };
  const finish = () => {
    if (!state.login) return;
    const controller = begin();
    const submitted = state.recover ? undefined : code.trim() || undefined;
    setCode("");
    setState((old) => ({ ...old, phase: "finishing", error: undefined }));
    void api.finish(run, state.login.loginId, submitted, controller.signal).then(
      (value) => {
        if (!current(controller)) return;
        if (value.signedIn) setState({ phase: "hidden" });
        else setState((old) => ({ ...old, phase: "ready", error: "badCode", recover: false }));
      },
      (error) => failure(error, controller, true),
    );
  };
  const cancel = () => {
    if (!state.login) return;
    const loginId = state.login.loginId;
    const controller = begin();
    setCode("");
    setState((old) => ({ ...old, phase: "starting", error: undefined }));
    void api.cancel(run, loginId, controller.signal).then(
      () => {
        if (current(controller)) setState((old) => ({ phase: "ready", harness: old.harness }));
      },
      (error) => failure(error, controller),
    );
  };
  if (state.phase === "hidden") return null;
  const busy = state.phase !== "ready";
  const title =
    state.harness === "codex"
      ? t("turn.signIn.codex")
      : state.harness === "claude"
        ? t("turn.signIn.claude")
        : t("needsYou.chief");
  return (
    <section className="chief-machine-login" aria-label={title} data-testid="chief-machine-login" aria-busy={busy}>
      <div className="chief-machine-login__heading">
        <strong>{title}</strong>
        {busy && <Spinner size={16} />}
      </div>
      {state.error && <p role="alert">{t(`turn.signIn.error.${state.error}`)}</p>}
      {state.login && (
        <>
          <a href={state.login.url} target="_blank" rel="noopener noreferrer" referrerPolicy="no-referrer">
            {t("turn.signIn.openPage")}
          </a>
          <p>{state.login.needsCode ? t("turn.signIn.pasteCode") : t("turn.signIn.enterCode")}</p>
          {state.login.userCode && (
            <div className="chief-machine-login__device">
              <code>{state.login.userCode}</code>
              <button
                type="button"
                onClick={() => {
                  void navigator.clipboard?.writeText(state.login!.userCode!).catch(() => undefined);
                }}
              >
                {t("turn.signIn.copyCode")}
              </button>
            </div>
          )}
          {state.login.needsCode && !state.recover && (
            <label>
              {t("turn.signIn.codeLabel")}
              <input
                type="text"
                aria-label={t("turn.signIn.codeLabel")}
                autoComplete="off"
                autoCapitalize="none"
                spellCheck={false}
                value={code}
                onChange={(event) => setCode(event.target.value)}
                disabled={busy}
                placeholder={t("turn.signIn.codeLabel")}
              />
            </label>
          )}
          <div className="chief-machine-login__actions">
            <button
              type="button"
              className="chief-web__action"
              onClick={finish}
              disabled={busy || (!!state.login.needsCode && !state.recover && !code.trim())}
            >
              {t("turn.continue")}
            </button>
            <button type="button" onClick={cancel} disabled={state.phase === "starting" || state.phase === "checking"}>
              {t("turn.signIn.cancel")}
            </button>
          </div>
        </>
      )}
      {!state.login && (
        <button type="button" className="chief-web__action" disabled={busy} onClick={state.harness ? start : refresh}>
          {state.harness ? title : t("turn.retry")}
        </button>
      )}
    </section>
  );
}
