// A Cloud chat's sign-in on its own machine (Leo 2026-11-01, on the one-click sign-in: "yes those
// are important"): inline in the failed turn's card, never a modal. Sign in to Claude (or Codex)
// starts that agent's login on the machine (cloudAgentLogin.ts), and Open sign-in page opens its
// page here on its own click (the host lets only a click start a login); Claude's
// page gives a code to paste back, Codex's asks for the code the card shows. Use an API key saves
// one on the machine instead. Once signed in, the failed prompt goes again on the person's click.
// The code and the key live only in this component's state while it is up: never in a row, a
// log or anything kept.
import { useEffect, useRef, useState } from "react";
import { useT, type StringKey } from "../i18n";
import { copyText } from "./clipboard";
import { LoginStepError, type CloudSignIn as SignIn, type LoginFailure, type LoginStart } from "../cloudAgentLogin";

type Stage =
  | { at: "idle" }
  | { at: "starting" }
  | { at: "code"; login: LoginStart; busy?: boolean }
  | { at: "device"; login: LoginStart }
  | { at: "key"; busy?: boolean }
  | { at: "signedIn" }
  | { at: "sending" }
  | { at: "sent" }
  | { at: "failed"; failure: LoginFailure; login?: LoginStart; key?: true };

/// What the card's lead says: the agent's own name, as the person knows it.
const SIGN_IN_LABEL = { claude: "turn.signIn.claude", codex: "turn.signIn.codex" } as const;

const FAILURE_COPY: Record<LoginFailure, StringKey> = {
  bad_code: "turn.signIn.error.badCode",
  expired: "turn.signIn.error.expired",
  shared_machine: "turn.signIn.error.sharedMachine",
  cli_missing: "turn.signIn.error.cliMissing",
  busy: "turn.signIn.error.busy",
  remote_refused: "turn.signIn.error.remoteRefused",
  unknown_session: "turn.signIn.error.unknownSession",
  unsupported: "turn.signIn.error.failed",
  failed: "turn.signIn.error.failed",
};

function failureOf(error: unknown): LoginFailure {
  return error instanceof LoginStepError ? error.failure : "failed";
}

/// The sign-in's part of the failed turn's card. `rowId` and `prompt` are the failed prompt's, which
/// goes again once the agent is signed in.
export function CloudSignIn({
  signIn,
  rowId,
  prompt,
}: {
  signIn: SignIn;
  rowId: string | undefined;
  prompt: string | undefined;
}) {
  const t = useT();
  const [stage, setStage] = useState<Stage>({ at: "idle" });
  const [code, setCode] = useState("");
  const [key, setKey] = useState("");
  const [copied, setCopied] = useState(false);
  const [opened, setOpened] = useState(false);
  // The login this card started and has not finished: cancelled when the card goes away.
  const open = useRef<string | undefined>(undefined);
  // A step that lands after the person moved on (Cancel, another try) is dropped.
  const generation = useRef(0);
  // The chat's actions are rebuilt as it changes; the card cancels through the newest, and only when
  // it goes away (a rebuilt `signIn` is the same login).
  const latest = useRef(signIn);
  useEffect(() => {
    latest.current = signIn;
  }, [signIn]);
  // Going away ends every step in flight: none opens, finishes or sends after it.
  useEffect(
    () => () => {
      generation.current++;
      if (open.current) latest.current.cancel(open.current);
      open.current = undefined;
    },
    [],
  );
  const resendable = rowId !== undefined && prompt !== undefined;

  const signedIn = () => {
    open.current = undefined;
    setCode("");
    setKey("");
    setStage({ at: "signedIn" });
  };

  /// Sends the failed prompt again under the ticket the click reserved (never without one).
  const sendAgain = (ticket: ReturnType<SignIn["reserve"]>) => {
    if (!resendable) return;
    const mine = generation.current;
    setStage({ at: "sending" });
    void ticket
      .then((held) => {
        if (!held || mine !== generation.current) throw new LoginStepError("failed");
        return signIn.resend(rowId, prompt, held);
      })
      .then(
        () => mine === generation.current && setStage({ at: "sent" }),
        () => mine === generation.current && setStage({ at: "signedIn" }),
      );
  };

  const start = () => {
    const mine = ++generation.current;
    setStage({ at: "starting" });
    void signIn.start().then(
      (login) => {
        if (mine !== generation.current) {
          signIn.cancel(login.loginId);
          return;
        }
        open.current = login.loginId;
        setOpened(false);
        if (login.needsCode) {
          setStage({ at: "code", login });
          return;
        }
        setStage({ at: "device", login });
        void signIn.finish(login.loginId).then(
          (done) => {
            if (mine !== generation.current) return;
            if (done) signedIn();
            else setStage({ at: "failed", failure: "failed" });
          },
          (error) => {
            if (mine !== generation.current) return;
            open.current = undefined;
            setStage({ at: "failed", failure: failureOf(error) });
          },
        );
      },
      (error) => {
        if (mine === generation.current) setStage({ at: "failed", failure: failureOf(error) });
      },
    );
  };

  const submitCode = (login: LoginStart) => {
    const pasted = code.trim();
    if (!pasted) return;
    const mine = generation.current;
    // The Continue click is the resend's gesture: reserved now, spent once the agent is signed in.
    const ticket = resendable ? signIn.reserve() : undefined;
    setStage({ at: "code", login, busy: true });
    void signIn.finish(login.loginId, pasted).then(
      (done) => {
        if (mine !== generation.current) return;
        if (!done) {
          setStage({ at: "failed", failure: "failed", login });
          return;
        }
        signedIn();
        if (ticket) sendAgain(ticket);
      },
      (error) => {
        if (mine !== generation.current) return;
        const failure = failureOf(error);
        // A wrong code keeps the login: paste again. Anything else starts over.
        if (failure !== "bad_code") open.current = undefined;
        setCode("");
        setStage({ at: "failed", failure, ...(failure === "bad_code" ? { login } : {}) });
      },
    );
  };

  const saveKey = () => {
    const typed = key.trim();
    if (!typed) return;
    const mine = ++generation.current;
    // The key leaves the page's state as soon as it is sent.
    setKey("");
    setStage({ at: "key", busy: true });
    void signIn.apiKey(typed).then(
      (saved) => {
        if (mine !== generation.current) return;
        if (saved) signedIn();
        else setStage({ at: "failed", failure: "failed", key: true });
      },
      (error) => {
        if (mine === generation.current) setStage({ at: "failed", failure: failureOf(error), key: true });
      },
    );
  };

  const cancel = () => {
    generation.current++;
    if (open.current) signIn.cancel(open.current);
    open.current = undefined;
    setCode("");
    setKey("");
    setStage({ at: "idle" });
  };

  const retry = () => {
    // A key that was not saved asks for the key again, not for a sign-in.
    if (stage.at === "failed" && stage.key) {
      setStage({ at: "key" });
      return;
    }
    if (stage.at === "failed" && stage.failure === "bad_code" && stage.login) {
      setStage({ at: "code", login: stage.login });
      return;
    }
    start();
  };

  // The page opens on its own click: the Sign in click's gesture went to the login's start, which
  // the host lets only a click begin. It leads until the person opened it; it stays for another try.
  const pageButton = (login: LoginStart) => (
    <button
      type="button"
      className={`cv-turn-auth-action${opened ? "" : " cv-turn-error__primary"}`}
      onClick={() => {
        setOpened(true);
        signIn.open(login.url);
      }}
    >
      {t("turn.signIn.openPage")}
    </button>
  );
  const cancelButton = (
    <button type="button" className="cv-turn-auth-action" onClick={cancel}>
      {t("turn.signIn.cancel")}
    </button>
  );

  switch (stage.at) {
    case "idle":
    case "starting":
      return (
        <>
          <button
            type="button"
            className="cv-turn-auth-action cv-turn-error__primary"
            disabled={stage.at === "starting"}
            onClick={start}
          >
            {t(SIGN_IN_LABEL[signIn.agent])}
          </button>
          <button
            type="button"
            className="cv-turn-auth-action"
            disabled={stage.at === "starting"}
            onClick={() => setStage({ at: "key" })}
          >
            {t("turn.signIn.apiKey")}
          </button>
        </>
      );
    case "code":
      return (
        <form
          className="cv-turn-signin"
          onSubmit={(event) => {
            event.preventDefault();
            submitCode(stage.login);
          }}
        >
          <span className="cv-turn-signin__row">
            {pageButton(stage.login)}
            {cancelButton}
          </span>
          <span className="cv-turn-signin__text">{t("turn.signIn.pasteCode")}</span>
          <span className="cv-turn-signin__row">
            <input
              className="cv-turn-signin__input"
              aria-label={t("turn.signIn.codeLabel")}
              autoComplete="off"
              autoCorrect="off"
              autoCapitalize="off"
              spellCheck={false}
              value={code}
              disabled={stage.busy}
              onChange={(event) => setCode(event.currentTarget.value)}
            />
            <button
              type="submit"
              className={`cv-turn-auth-action${opened ? " cv-turn-error__primary" : ""}`}
              disabled={stage.busy || !code.trim()}
            >
              {t("turn.continue")}
            </button>
          </span>
        </form>
      );
    case "device":
      return (
        <div className="cv-turn-signin">
          <span className="cv-turn-signin__row">
            {pageButton(stage.login)}
            {cancelButton}
          </span>
          <span className="cv-turn-signin__row">
            <span className="cv-turn-signin__code" data-testid="cloud-signin-code">
              {stage.login.userCode}
            </span>
            {stage.login.userCode && (
              <button
                type="button"
                className="cv-turn-auth-action"
                onClick={() =>
                  void copyText(stage.login.userCode!).then(
                    () => setCopied(true),
                    () => setCopied(false),
                  )
                }
              >
                {copied ? t("turn.copied") : t("turn.signIn.copyCode")}
              </button>
            )}
          </span>
          <span className="cv-turn-signin__text">{t("turn.signIn.enterCode")}</span>
        </div>
      );
    case "key":
      return (
        <form
          className="cv-turn-signin"
          onSubmit={(event) => {
            event.preventDefault();
            saveKey();
          }}
        >
          <span className="cv-turn-signin__row">
            <input
              className="cv-turn-signin__input"
              type="password"
              aria-label={t("turn.signIn.keyLabel")}
              autoComplete="off"
              spellCheck={false}
              value={key}
              disabled={stage.busy}
              onChange={(event) => setKey(event.currentTarget.value)}
            />
            <button
              type="submit"
              className="cv-turn-auth-action cv-turn-error__primary"
              disabled={stage.busy || !key.trim()}
            >
              {t("turn.signIn.save")}
            </button>
            {cancelButton}
          </span>
          <span className="cv-turn-signin__text">{t("turn.signIn.keyStored")}</span>
        </form>
      );
    case "signedIn":
    case "sending":
      return (
        <span className="cv-turn-signin cv-turn-signin__row">
          <span className="cv-turn-signin__text">{t("turn.signIn.done")}</span>
          {resendable && (
            <button
              type="button"
              className="cv-turn-auth-action cv-turn-error__primary"
              disabled={stage.at === "sending"}
              onClick={() => sendAgain(signIn.reserve())}
            >
              {t("turn.signIn.sendAgain")}
            </button>
          )}
        </span>
      );
    case "sent":
      return <span className="cv-turn-signin cv-turn-signin__text">{t("turn.signIn.done")}</span>;
    case "failed":
      // An acpmux (or host) without the methods: the card stays as it was without the sign-in.
      if (stage.failure === "unsupported") return null;
      return (
        <span className="cv-turn-signin cv-turn-signin__row">
          <output className="cv-turn-signin__error">{t(FAILURE_COPY[stage.failure])}</output>
          {stage.failure !== "shared_machine" && stage.failure !== "remote_refused" && (
            <button type="button" className="cv-turn-auth-action cv-turn-error__primary" onClick={retry}>
              {t("turn.retry")}
            </button>
          )}
          {cancelButton}
        </span>
      );
  }
}
