// A Cloud chat's sign-in on its own machine (Leo 2026-11-01, on the one-click sign-in: "yes those
// are important"; 2026-11-02: one "Sign in to Claude" button): inline in the failed turn's card,
// never a modal. One click on Sign in to Claude (or Codex) starts that agent's login on the machine
// (cloudAgentLogin.ts) and opens its page: the host lets the start that took the click open the
// page it names, once. Open sign-in page stays as a quiet way back to it. Claude's automatic page
// opens in a Chromium tab whose localhost is the chat's machine (Leo 2026-11-02: one click plus the
// provider's approve page, with nothing else): its approve redirects to Claude's own listener there,
// so Claude signs in with no code (cmux only carries the bytes; it never reads the code or keeps a
// token). Where the host cannot open that tab (WebKit, a machine without remote localhost), and on
// "Paste a code instead", Claude's other page gives a code to paste back. Codex's page asks for the
// code the card shows, copied on the start. Use an API key, a link
// beside it, saves one on the machine instead. Grok signs in like Codex (a page and a code) and takes
// no saved key, so it has no Use an API key; Gemini takes a key only, so Use an API key is its one
// button. Use cmux's gateway, a third link shown only when the machine's team has the gateway (acpmux
// names it in the failure), runs Claude or Codex on the team's own account instead (Leo 2026-11-10:
// "the stuff does of course go through our gateway"). Once signed in, the failed prompt goes again
// on the person's click.
// The code and the key live only in this component's state while it is up: never in a row, a
// log or anything kept.
import { useEffect, useLayoutEffect, useRef, useState, type RefObject } from "react";
import { useT, type StringKey } from "../i18n";
import { copyText, copyTextResult } from "./clipboard";
import {
  LoginStepError,
  signsInByPage,
  takesApiKey,
  usesGateway,
  type CloudSignIn as SignIn,
  type LoginFailure,
  type LoginStart,
} from "../cloudAgentLogin";
import { cancelResize, playResize } from "./fold";
import { motionMode } from "../../../ui/motion/motionMode";

type Stage =
  | { at: "idle" }
  | { at: "starting" }
  | { at: "approve"; login: LoginStart }
  | { at: "code"; login: LoginStart; busy?: boolean }
  | { at: "device"; login: LoginStart }
  | { at: "key"; busy?: boolean }
  | { at: "gateway" }
  | { at: "signedIn" }
  | { at: "sending" }
  | { at: "sent" }
  | { at: "failed"; failure: LoginFailure; login?: LoginStart; key?: true; gateway?: true };

/// What the card's lead says: the agent's own name, as the person knows it. Gemini has no sign-in
/// page here (a key only).
const SIGN_IN_LABEL = {
  claude: "turn.signIn.claude",
  codex: "turn.signIn.codex",
  grok: "turn.signIn.grok",
  cursor: "turn.signIn.cursor",
} as const satisfies Partial<Record<SignIn["agent"], StringKey>>;

const FAILURE_COPY: Record<LoginFailure, StringKey> = {
  bad_code: "turn.signIn.error.badCode",
  expired: "turn.signIn.error.expired",
  shared_machine: "turn.signIn.error.sharedMachine",
  cli_missing: "turn.signIn.error.cliMissing",
  busy: "turn.signIn.error.busy",
  remote_refused: "turn.signIn.error.remoteRefused",
  unknown_session: "turn.signIn.error.unknownSession",
  unsupported: "turn.signIn.error.failed",
  no_gateway: "turn.signIn.error.noGateway",
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
  keyOnly = false,
  gateway = false,
  actionsRef,
}: {
  signIn: SignIn;
  rowId: string | undefined;
  prompt: string | undefined;
  /// Only Use an API key: a team Cloud machine, where the agent's own sign-in is not offered.
  keyOnly?: boolean;
  /// The machine's team has cmux's gateway (cloudAgentLogin.ts `offersGateway`): Use cmux's gateway
  /// is offered beside the others.
  gateway?: boolean;
  actionsRef?: RefObject<HTMLElement | null>;
}) {
  const t = useT();
  const [stage, commitStage] = useState<Stage>({ at: "idle" });
  const previousHeight = useRef<number | undefined>(undefined);
  const resizingNode = useRef<HTMLElement | null>(null);
  // Read before changing the step, including when another step interrupts a resize. The same
  // transcript fold places following rows before paint; no observer, timer or idle work is needed.
  const setStage = (next: Stage) => {
    previousHeight.current ??= actionsRef?.current?.getBoundingClientRect().height;
    commitStage(next);
  };
  useLayoutEffect(() => {
    const from = previousHeight.current;
    previousHeight.current = undefined;
    const node = actionsRef?.current;
    resizingNode.current = node ?? null;
    if (node && from !== undefined && motionMode(node.ownerDocument) === "full") playResize(node, from);
    else if (node) cancelResize(node);
  }, [stage, actionsRef]);
  useLayoutEffect(
    () => () => {
      if (resizingNode.current) cancelResize(resizingNode.current);
    },
    [],
  );
  const [code, setCode] = useState("");
  const [key, setKey] = useState("");
  const [copied, setCopied] = useState(false);
  // The login this card started and has not finished: cancelled when the card goes away.
  const open = useRef<string | undefined>(undefined);
  // A step that lands after the person moved on (Cancel, another try) is dropped.
  const generation = useRef(0);
  // The generation whose pasted code signed in: the approve's wait, ending after it, changes nothing.
  const pastedIn = useRef(-1);
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
        return signIn.resend(rowId, prompt, held, () => mine === generation.current);
      })
      .then(
        () => mine === generation.current && setStage({ at: "sent" }),
        () => mine === generation.current && setStage({ at: "signedIn" }),
      );
  };

  /// Finishes a login that ends by itself: Codex's approval, or Claude's approve on its automatic
  /// page. A code pasted meanwhile (Paste a code instead) reaches the same login and ends this too.
  const waitFor = (login: LoginStart, mine: number) => {
    void signIn.finish(login.loginId).then(
      (done) => {
        // A pasted code that already signed in (and maybe sent again) is the end: never back to Send again.
        if (mine !== generation.current || pastedIn.current === mine) return;
        if (done) signedIn();
        else setStage({ at: "failed", failure: "failed" });
      },
      (error) => {
        if (mine !== generation.current || pastedIn.current === mine) return;
        open.current = undefined;
        setStage({ at: "failed", failure: failureOf(error) });
      },
    );
  };

  /// The approve page did not work out (or the person prefers it): Claude's other page, on this click,
  /// and the code field. The wait for the approve goes on.
  const pasteInstead = (login: LoginStart) => {
    signIn.open(login.url);
    setStage({ at: "code", login });
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
        setCopied(false);
        const auto = login.autoUrl;
        if (auto) {
          // The Sign in click opens Claude's automatic page on the machine; a host that cannot opens
          // the page that gives a code instead (the same click's page credit either way).
          void signIn.openOnMachine(auto).then((opened) => {
            if (mine !== generation.current) return;
            if (!opened) {
              signIn.open(login.url);
              setStage({ at: "code", login });
              return;
            }
            setStage({ at: "approve", login });
            waitFor(login, mine);
          });
          return;
        }
        // The Sign in click opens the page too (the host lets its start open it, once).
        signIn.open(login.url);
        if (login.needsCode) {
          setStage({ at: "code", login });
          return;
        }
        setStage({ at: "device", login });
        // Codex's page asks for the code the card shows: it is on the clipboard already.
        if (login.userCode)
          void copyTextResult(login.userCode).then((done) => mine === generation.current && setCopied(done));
        waitFor(login, mine);
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
        pastedIn.current = mine;
        signedIn();
        if (ticket) sendAgain(ticket);
      },
      (error) => {
        if (mine !== generation.current) return;
        const failure = failureOf(error);
        // acpmux ends the login on any refused step, a wrong code too: Retry starts a new one.
        open.current = undefined;
        setCode("");
        setStage({ at: "failed", failure });
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

  const switchToGateway = () => {
    const mine = ++generation.current;
    setStage({ at: "gateway" });
    void signIn.gateway().then(
      (switched) => {
        if (mine !== generation.current) return;
        if (switched) signedIn();
        else setStage({ at: "failed", failure: "failed", gateway: true });
      },
      (error) => {
        if (mine === generation.current) setStage({ at: "failed", failure: failureOf(error), gateway: true });
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
    if (stage.at === "failed" && stage.gateway) {
      switchToGateway();
      return;
    }
    start();
  };

  // The page opened with the Sign in click; this opens it again (a closed tab, or a host that did
  // not open it), on its own click.
  const pageButton = (login: LoginStart) => (
    <button type="button" className="cv-turn-auth-action" onClick={() => signIn.open(login.url)}>
      {t("turn.signIn.openPage")}
    </button>
  );
  const machinePageButton = (login: LoginStart) => (
    <button
      type="button"
      className="cv-turn-auth-action"
      onClick={() => login.autoUrl && void signIn.openOnMachine(login.autoUrl)}
    >
      {t("turn.signIn.openPage")}
    </button>
  );
  const cancelButton = (
    <button type="button" className="cv-turn-auth-action" onClick={cancel}>
      {t("turn.signIn.cancel")}
    </button>
  );

  // Each agent's ways in: its own sign-in page (all but Gemini) and a saved key (all but Grok and
  // Cursor).
  const agent = signIn.agent;
  const pageLabel = agent === "gemini" ? undefined : SIGN_IN_LABEL[agent];
  const offersPage = !keyOnly && signsInByPage(agent) && pageLabel !== undefined;
  const offersKey = takesApiKey(agent);
  const offersGateway = gateway && usesGateway(agent);
  switch (stage.at) {
    case "idle":
    case "starting":
    case "gateway":
      if (!offersPage && !offersKey && !offersGateway) return null;
      return (
        <>
          {offersPage && pageLabel && (
            <button
              type="button"
              className="cv-turn-auth-action cv-turn-error__primary"
              disabled={stage.at !== "idle"}
              onClick={start}
            >
              {t(pageLabel)}
            </button>
          )}
          {offersKey && (
            <button
              type="button"
              // Beside Sign in it is a link, so the sign-in stays the one button; alone it is the button,
              // filled when it leads the card (Gemini), outlined on a team machine (Switch model leads).
              className={
                offersPage
                  ? "cv-turn-error__offer-link"
                  : keyOnly
                    ? "cv-turn-auth-action"
                    : "cv-turn-auth-action cv-turn-error__primary"
              }
              disabled={stage.at !== "idle"}
              onClick={() => setStage({ at: "key" })}
            >
              {t("turn.signIn.apiKey")}
            </button>
          )}
          {offersGateway && (
            <button
              type="button"
              // A link beside the others, as Use an API key is: the sign-in stays the one button.
              className={offersPage || offersKey ? "cv-turn-error__offer-link" : "cv-turn-auth-action"}
              disabled={stage.at !== "idle"}
              onClick={switchToGateway}
            >
              {t("turn.signIn.gateway")}
            </button>
          )}
        </>
      );
    case "approve":
      return (
        <div className="cv-turn-signin">
          <span className="cv-turn-signin__row">
            {machinePageButton(stage.login)}
            {cancelButton}
          </span>
          <span className="cv-turn-signin__text">{t("turn.signIn.approve")}</span>
          <button type="button" className="cv-turn-error__offer-link" onClick={() => pasteInstead(stage.login)}>
            {t("turn.signIn.pasteInstead")}
          </button>
        </div>
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
              className="cv-turn-auth-action cv-turn-error__primary"
              disabled={stage.busy || !code.trim()}
            >
              {t("turn.continue")}
            </button>
          </span>
        </form>
      );
    case "device":
      // A sign-in with no code to type (Cursor's): its page is open and it finishes on the approve.
      if (!stage.login.userCode)
        return (
          <div className="cv-turn-signin">
            <span className="cv-turn-signin__row">
              {pageButton(stage.login)}
              {cancelButton}
            </span>
            <span className="cv-turn-signin__text">{t("turn.signIn.approve")}</span>
          </div>
        );
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
