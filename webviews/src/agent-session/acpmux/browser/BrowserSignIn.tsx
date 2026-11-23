// The browser's sign-in screen: what a tab at `/app/` shows before the pane connects, until the
// person's emailed code proves the account that owns the machine (BrowserSignIn.md). The daemon
// decides everything (owner, deployment, origin); this screen only collects the email and code
// and names each refusal in words.
import { useId, useState, type FormEvent } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { useT, type StringKey } from "../i18n";
import type { SignInError, SignInTransport } from "./signInWire";
import "./browserSignIn.css";

/** card: a centered card. pane: the empty chat pane, with the form where the composer sits.
 * split: the machine named on the left, the form on the right (a wide window). */
export type BrowserSignInLook = "card" | "pane" | "split";

/** Why the screen cannot offer a sign-in at all: the page is not a secure context, or the tab has
 * no link from the daemon. */
export type BrowserSignInBlock = "insecure" | "noLink";

type Step = { at: "email" } | { at: "code"; email: string };

const REASONS: Record<string, StringKey> = {
  "signin.unconfigured": "browserSignIn.error.unconfigured",
  "signin.unreachable": "browserSignIn.error.unreachable",
  "signin.timeout": "browserSignIn.error.unreachable",
  "browser.sign_in.code_refused": "browserSignIn.error.code",
  "browser.sign_in.expired": "browserSignIn.error.code",
  "browser.sign_in.rate_limited": "browserSignIn.error.rateLimited",
  "browser.sign_in.account_mismatch": "browserSignIn.error.account",
  "browser.sign_in.origin_mismatch": "browserSignIn.error.insecure",
};

export function signInReasonKey(reason: string | undefined): StringKey {
  return (reason && Object.hasOwn(REASONS, reason) && REASONS[reason]) || "browserSignIn.error.generic";
}

export function BrowserSignIn({
  transport,
  host,
  look = "card",
  block,
  initial,
  onSignedIn,
}: {
  transport?: SignInTransport;
  /** The machine this tab opens, as its address bar names it. */
  host: string;
  look?: BrowserSignInLook;
  block?: BrowserSignInBlock;
  /** Gallery and tests: the step and refusal to draw first. */
  initial?: { step?: Step; reason?: string };
  onSignedIn(enrollment: { accessToken: string; publicKey: string }): void;
}) {
  const t = useT();
  const id = useId();
  const [step, setStep] = useState<Step>(initial?.step ?? { at: "email" });
  const [email, setEmail] = useState(initial?.step?.at === "code" ? initial.step.email : "");
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [reason, setReason] = useState<string | undefined>(initial?.reason);

  const run = async (work: () => Promise<void>) => {
    setBusy(true);
    setReason(undefined);
    try {
      await work();
    } catch (error) {
      setReason((error as Partial<SignInError>)?.reason ?? "signin.refused");
    } finally {
      setBusy(false);
    }
  };
  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (busy || !transport) return;
    if (step.at === "email") {
      const address = email.trim();
      if (!address) return;
      void run(async () => {
        await transport.start(address);
        setCode("");
        setStep({ at: "code", email: address });
      });
    } else {
      const typed = code.trim();
      if (!typed) return;
      void run(async () => {
        const enrollment = await transport.complete(typed);
        transport.close();
        onSignedIn(enrollment);
      });
    }
  };
  // A refused or expired code is used up on the daemon: only a new code can finish.
  const codeSpent = step.at === "code" && reason !== undefined && reason !== "signin.unreachable";

  const heading = <h1 className="browser-sign-in-title">{t("browserSignIn.title")}</h1>;
  const lead = (
    <p className="browser-sign-in-lead">
      {block === "insecure"
        ? t("browserSignIn.error.insecure")
        : block === "noLink"
          ? t("browserSignIn.error.noLink")
          : step.at === "email"
            ? t("browserSignIn.body", { host })
            : t("browserSignIn.codeSent", { email: step.email })}
    </p>
  );
  const form = block ? null : (
    <form className="browser-sign-in-form" onSubmit={submit} noValidate>
      {step.at === "email" ? (
        <>
          <label className="browser-sign-in-label" htmlFor={`${id}-email`}>
            {t("browserSignIn.email")}
          </label>
          <Input
            id={`${id}-email`}
            type="email"
            autoComplete="email"
            autoFocus
            size="lg"
            variant="outline"
            value={email}
            disabled={busy}
            onChange={(event) => setEmail(event.currentTarget.value)}
          />
        </>
      ) : (
        <>
          <label className="browser-sign-in-label" htmlFor={`${id}-code`}>
            {t("browserSignIn.code")}
          </label>
          <Input
            id={`${id}-code`}
            autoComplete="one-time-code"
            inputMode="text"
            autoFocus
            size="lg"
            variant="outline"
            value={code}
            disabled={busy || codeSpent}
            onChange={(event) => setCode(event.currentTarget.value)}
          />
        </>
      )}
      {reason !== undefined && (
        <p className="browser-sign-in-error" role="alert">
          {t(signInReasonKey(reason))}
        </p>
      )}
      <div className="browser-sign-in-actions">
        {codeSpent ? (
          <Button
            variant="solid"
            size="lg"
            disabled={busy}
            onClick={() => {
              if (step.at !== "code" || !transport) return;
              const address = step.email;
              void run(async () => {
                await transport.start(address);
                setCode("");
              });
            }}
          >
            {t("browserSignIn.sendNew")}
          </Button>
        ) : (
          <Button type="submit" variant="solid" size="lg" disabled={busy || !transport}>
            {busy
              ? t("browserSignIn.working")
              : step.at === "email"
                ? t("browserSignIn.sendCode")
                : t("browserSignIn.signIn")}
          </Button>
        )}
        {step.at === "code" && (
          <Button
            variant="ghost"
            size="lg"
            disabled={busy}
            onClick={() => {
              setReason(undefined);
              setStep({ at: "email" });
            }}
          >
            {t("browserSignIn.useAnother")}
          </Button>
        )}
      </div>
    </form>
  );

  return (
    <main className="browser-sign-in" data-look={look}>
      {look === "split" ? (
        <>
          <section className="browser-sign-in-side">
            <span className="browser-sign-in-host">{host}</span>
            {heading}
          </section>
          <section className="browser-sign-in-body">
            {lead}
            {form}
          </section>
        </>
      ) : (
        <section className="browser-sign-in-body">
          {heading}
          {lead}
          {form}
        </section>
      )}
    </main>
  );
}
