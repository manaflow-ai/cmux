"use client";

import { Button } from "@base-ui-components/react/button";
import { Field } from "@base-ui-components/react/field";
import { useHexclaveApp, useUser, type CurrentUser } from "@hexclave/next";
import { KnownErrors } from "@hexclave/shared";
import { getPasswordError } from "@hexclave/shared/dist/helpers/password";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { useEffect, useId, useMemo, useRef, useState, useSyncExternalStore, type ComponentProps, type FormEvent, type ReactNode } from "react";
import { forgetSession, saveCurrentSession, signedInAccounts, switchSession, tokenSignIn } from "./account-sessions-client";
import {
  ACCOUNT_HISTORY_KEY,
  PENDING_OAUTH_KEY,
  accountInitials,
  demoteRememberedMethod,
  forgetAccount,
  handlerHref,
  isReturningFromOAuth,
  oauthLoginHint,
  otherAccounts,
  parseAccountHistory,
  parsePendingOAuth,
  rememberAccount,
  rememberedMethodFor,
  rememberedSignInProvider,
  serializePendingOAuth,
  signInEntry,
  signUpPendingHref,
  withContinueMarker,
  withoutContinueMarker,
  type RememberedAccount,
} from "./sign-in-entry";
import { SignInSpinner } from "./sign-in-spinner";

export type CmuxSignInMessages = {
  signInTitle: string;
  signInSubtitle: string;
  signUpTitle: string;
  signUpSubtitle: string;
  continueWithProvider: string;
  signInWithPasskey: string;
  or: string;
  emailLabel: string;
  emailPlaceholder: string;
  continueWithEmail: string;
  usePasswordInstead: string;
  useEmailCodeInstead: string;
  passwordLabel: string;
  repeatPasswordLabel: string;
  signInButton: string;
  createAccountButton: string;
  forgotPassword: string;
  noAccount: string;
  signUpLink: string;
  haveAccount: string;
  signInLink: string;
  checkEmailTitle: string;
  checkEmailBody: string;
  codeLabel: string;
  back: string;
  resendCode: string;
  chooseAccountTitle: string;
  chooseAccountSubtitle: string;
  useAnotherAccount: string;
  forgetAccount: string;
  signedOut: string;
  signingInAs: string;
  sessionEnded: string;
  redirecting: string;
  lastUsed: string;
  legal: string;
  termsOfService: string;
  privacyPolicy: string;
  signUpDisabled: string;
  noMethods: string;
  embeddedDisabled: string;
  errorInvalidEmail: string;
  errorPasswordRequired: string;
  errorPasswordTooShort: string;
  errorPasswordTooLong: string;
  errorPasswordsDontMatch: string;
  errorWrongPassword: string;
  errorInvalidCode: string;
  errorInvalidTotp: string;
  errorSignUpNotAllowed: string;
  errorPasskey: string;
  errorGeneric: string;
};

type Mode = "sign-in" | "sign-up";

/** `{name}` placeholders, the same shape the message catalogs use. */
function format(template: string, values: Record<string, string | number>): string {
  return template.replace(/\{(\w+)\}/g, (match, key: string) => (key in values ? String(values[key]) : match));
}

export function CmuxSignIn({ mode, messages }: { mode: Mode; messages: CmuxSignInMessages }) {
  const app = useHexclaveApp();
  const user = useUser({ includeRestricted: true });
  const params = useSearchParams();
  const returnTo = params.get("after_auth_return_to");
  // Set when the chooser opens the form on this page ("use another account",
  // or a remembered account that has to sign in again).
  const [inlineSignIn, setInlineSignIn] = useState<InlineSignIn | null>(null);
  // A switch signs the browser in before it leaves. Until it has, the chooser
  // stays: the entry would otherwise turn to "continue" and redirect a
  // second time, ahead of the switch's own account check.
  const [switching, setSwitching] = useState(false);
  const remembered = otherAccounts(useAccountHistory(), user?.id ?? "");
  const entry = signInEntry({
    hasUser: user !== null,
    isRestricted: user?.isRestricted === true,
    prompt: params.get("prompt"),
    returningFromOAuth: isReturningFromOAuth(params),
    hasRememberedAccounts: mode === "sign-in" && remembered.length > 0,
  });

  // Always in this slot (null when signed out), so the screen next to it
  // keeps its state when a switch signs the browser in.
  const remember = user ? <RememberThisAccount user={user} /> : null;

  if (switching || (entry === "choose-account" && !inlineSignIn)) {
    return (
      <>
        {remember}
        <ChooseAccount
          messages={messages}
          current={accountRowFor(user)}
          onContinue={() => app.redirectToAfterSignIn({ replace: true })}
          onSignInHere={setInlineSignIn}
          onSwitching={setSwitching}
        />
      </>
    );
  }
  if (entry === "continue" || entry === "onboarding") {
    return (
      <>
        {remember}
        <AutomaticRedirect mode={mode} onboarding={entry === "onboarding"} messages={messages} />
      </>
    );
  }
  // Signing in on top of the current session replaces it, so a switch never
  // needs a sign-out first.
  return (
    <>
      {remember}
      <SignInForm
        mode={inlineSignIn ? "sign-in" : mode}
        messages={messages}
        returnTo={returnTo}
        {...inlineFormProps(inlineSignIn, messages, () => setInlineSignIn(null))}
      />
    </>
  );
}

function accountRowFor(user: CurrentUser | null): AccountRow | null {
  return user ? { id: user.id, email: user.primaryEmail, displayName: user.displayName, profileImageUrl: user.profileImageUrl } : null;
}

/** The form's account-specific props when the chooser opened it; none otherwise. */
function inlineFormProps(inline: InlineSignIn | null, messages: CmuxSignInMessages, back: () => void) {
  if (!inline) return {};
  return {
    prefillEmail: inline.email,
    lastUsedMethod: inline.method,
    startWithPassword: inline.password,
    notice: inline.sessionEnded ? messages.sessionEnded : null,
    onBack: back,
  };
}

/** The form opened from the chooser, for one account or for a new one. */
type InlineSignIn = {
  email: string | null;
  method: string | null;
  password: boolean;
  /** The account's saved session had ended: say why it asks again. */
  sessionEnded: boolean;
};

// MARK: Layout

function Page({ children }: { children: ReactNode }) {
  return (
    <main className="flex min-h-screen items-center justify-center bg-background px-4 py-12 text-foreground">
      <div className="w-full max-w-[340px]">{children}</div>
    </main>
  );
}

function Heading({ id, title, subtitle }: { id?: string; title: string; subtitle?: string }) {
  return (
    <header className="mb-6">
      <h1 id={id} className="text-[22px] font-semibold tracking-[-0.02em]">{title}</h1>
      {subtitle && <p className="mt-1.5 text-sm text-muted">{subtitle}</p>}
    </header>
  );
}

// Buttons are Base UI's: a busy button stays focusable (aria-disabled), so
// focus and the screen reader stay on what was pressed. Disabled styles key
// off its data-disabled attribute.
const buttonClass =
  "flex h-[38px] w-full cursor-pointer items-center gap-2.5 border border-border bg-background px-3 text-left text-sm text-foreground transition-colors hover:bg-foreground/[0.05] active:bg-foreground/[0.08] focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground data-[disabled]:cursor-not-allowed data-[disabled]:opacity-50 data-[disabled]:hover:bg-background";
const primaryButtonClass =
  "flex h-[38px] w-full cursor-pointer items-center justify-center border border-foreground bg-foreground px-3 text-sm font-medium text-background transition-opacity hover:opacity-85 active:opacity-75 focus-visible:outline focus-visible:outline-1 focus-visible:outline-offset-2 focus-visible:outline-foreground data-[disabled]:cursor-not-allowed data-[disabled]:opacity-50";
const inputClass =
  "h-[38px] w-full min-w-0 border border-border bg-background px-3 text-sm text-foreground outline-none placeholder:text-muted focus:border-foreground disabled:opacity-50";
const linkClass =
  "cursor-pointer text-foreground underline decoration-border underline-offset-2 transition-colors hover:decoration-foreground";

function FieldError({ id, text }: { id: string; text: string | null }) {
  if (!text) return null;
  return (
    <p id={id} role="alert" className="text-xs text-red-600 dark:text-red-400">
      {text}
    </p>
  );
}

function Spinner() {
  return <SignInSpinner />;
}

/** A button's label while it works: the spinner shows, the name stays for screen readers. */
function BusyLabel({ busy, children }: { busy: boolean; children: string }) {
  return busy ? <><Spinner /><span className="sr-only">{children}</span></> : <>{children}</>;
}

/** Spoken, not shown: progress a screen reader would otherwise miss. */
function Announce({ text }: { text: string | null }) {
  return <p role="status" aria-live="polite" className="sr-only">{text ?? ""}</p>;
}

// MARK: Signed-in states

function AutomaticRedirect({ mode, onboarding, messages }: { mode: Mode; onboarding: boolean; messages: CmuxSignInMessages }) {
  const app = useHexclaveApp();
  const [failed, setFailed] = useState(false);
  const started = useRef(false);
  useEffect(() => {
    if (started.current) return;
    started.current = true;
    const redirect = onboarding
      ? app.redirectToOnboarding({ replace: true })
      : mode === "sign-up"
        ? app.redirectToAfterSignUp({ replace: true })
        : app.redirectToAfterSignIn({ replace: true });
    redirect.catch((error: unknown) => {
      console.error("[cmux sign-in] redirect after sign-in failed", error);
      setFailed(true);
    });
  }, [app, mode, onboarding]);

  return (
    <Page>
      <div aria-busy={!failed} className="flex items-center justify-center gap-2.5 text-center text-sm text-muted">
        {failed ? <span className="text-red-600 dark:text-red-400">{messages.errorGeneric}</span> : <><Spinner />{messages.redirecting}</>}
      </div>
    </Page>
  );
}

function ChooseAccount({ messages, current, onContinue, onSignInHere, onSwitching }: {
  messages: CmuxSignInMessages;
  /** The signed-in account, or null on a signed-out browser. */
  current: AccountRow | null;
  onContinue: () => Promise<void>;
  onSignInHere: (form: InlineSignIn) => void;
  /** True from the moment a saved session is made this browser's until the switch leaves or fails. */
  onSwitching: (switching: boolean) => void;
}) {
  const app = useHexclaveApp();
  const enabledProviders = app.useProject().config.oauthProviders.map(({ id }) => id);
  const headingId = useId();
  const errorId = useId();
  const history = useAccountHistory();
  const live = { current, others: otherAccounts(history, current?.id ?? "") };
  // While a row works, the list holds still: a switch signs the browser in
  // before it leaves, which would otherwise reshuffle the rows under it.
  const [pending, setPending] = useState<{ row: string; label: string; rows: typeof live } | null>(null);
  const { current: shownCurrent, others } = pending?.rows ?? live;
  const busy = pending !== null;
  const [error, setError] = useState<string | null>(null);
  // Accounts the server still holds a session for (null until it answers),
  // and accounts a pick found signed out since.
  const [signedIn, setSignedIn] = useState<ReadonlySet<string> | null>(null);
  const [ended, setEnded] = useState<ReadonlySet<string>>(() => new Set());
  const isSignedOut = (id: string) => ended.has(id) || (signedIn !== null && !signedIn.has(id));

  useEffect(() => {
    let cancelled = false;
    void signedInAccounts().then((ids) => {
      if (!cancelled && ids) setSignedIn(new Set(ids));
    });
    return () => {
      cancelled = true;
    };
  }, []);

  function start(row: string, label: string) {
    setPending({ row, label, rows: live });
    setError(null);
  }

  function fail() {
    setPending(null);
    setError(messages.errorGeneric);
  }

  // Like Gmail: a signed-in account switches straight in and nothing is
  // signed out. One whose session ended signs in again through its own
  // method: a provider-only account goes straight there, any other opens the
  // form here with its email filled in.
  async function pickRemembered(account: RememberedAccount) {
    start(account.id, account.email ?? account.displayName ?? "");
    let sessionEnded = isSignedOut(account.id);
    if (!sessionEnded) {
      const activate = tokenSignIn(app);
      if (!activate) {
        console.error("[cmux sign-in] saved sessions are unavailable: the SDK's token sign-in step is missing");
      } else {
        const result = await switchSession(account.id);
        if (result.status === "error") return fail();
        if (result.status === "ok") {
          onSwitching(true);
          try {
            await activate(result.tokens);
            // The server already matched the tokens to this account; this
            // confirms the browser really is that account before leaving
            // (allowing the SDK a moment to publish the new session).
            let now = await app.getUser({ includeRestricted: true });
            for (let attempt = 0; now?.id !== account.id && attempt < 5; attempt += 1) {
              await new Promise((resolve) => setTimeout(resolve, 200));
              now = await app.getUser({ includeRestricted: true });
            }
            if (now?.id !== account.id) throw new Error(`the switch landed on ${now ? "a different account" : "no account"}`);
            await app.redirectToAfterSignIn({ replace: true });
          } catch (caught) {
            console.error("[cmux sign-in] switching accounts failed", caught);
            onSwitching(false);
            fail();
          }
          return;
        }
        sessionEnded = true;
        setEnded((previous) => new Set(previous).add(account.id));
      }
    }
    const provider = rememberedSignInProvider(account, enabledProviders);
    if (!provider) {
      setPending(null);
      onSignInHere({ email: account.email, method: null, password: account.hasPassword === true, sessionEnded });
      return;
    }
    writePendingOAuth(serializePendingOAuth(account.id));
    startOAuth(app, provider, oauthLoginHint(provider, account.email)).catch(() => {
      writePendingOAuth(null);
      fail();
    });
  }

  const listRef = useRef<HTMLUListElement>(null);

  function forget(account: RememberedAccount, index: number) {
    writeStored(ACCOUNT_HISTORY_KEY, JSON.stringify(forgetAccount(readHistory(), account.id)));
    void forgetSession(account.id);
    // The focused button just went away with its row: focus the row that
    // took its place (or "use a different account") instead of the page.
    requestAnimationFrame(() => {
      const rows = listRef.current?.querySelectorAll<HTMLElement>(":scope > li > button:first-child");
      if (!rows?.length) return;
      rows[Math.min(index + (shownCurrent ? 1 : 0), rows.length - 1)].focus();
    });
  }

  const rowClass = (row: string) => `${accountRowClass} transition-opacity ${busy && pending.row !== row ? "opacity-50" : ""}`;
  const name = (account: AccountView) => account.email ?? account.displayName ?? "";

  return (
    <Page>
      <Heading id={headingId} title={messages.chooseAccountTitle} subtitle={messages.chooseAccountSubtitle} />
      <ul ref={listRef} aria-labelledby={headingId} aria-busy={busy} className="divide-y divide-border border border-border bg-background">
        {shownCurrent && (
          <li>
            <Button
              focusableWhenDisabled
              disabled={busy}
              className={rowClass("current")}
              onClick={() => {
                start("current", name(shownCurrent));
                onContinue().catch(fail);
              }}
            >
              <AccountAvatar account={shownCurrent} />
              <AccountLabel account={shownCurrent} />
              <span
                className={`ml-auto grid h-4 w-4 flex-none place-items-center text-muted transition-[color,transform] duration-150 ${
                  pending?.row === "current" ? "" : "group-hover:translate-x-0.5 group-hover:text-foreground"
                }`}
              >
                {pending?.row === "current" ? <Spinner /> : <ChevronIcon />}
              </span>
            </Button>
          </li>
        )}
        {others.map((account, index) => {
          const signedOut = isSignedOut(account.id);
          return (
            <li key={account.id} className="group/row relative">
              <Button
                focusableWhenDisabled
                disabled={busy}
                className={rowClass(account.id)}
                onClick={() => void pickRemembered(account)}
              >
                <AccountAvatar account={account} dimmed={signedOut} />
                <AccountLabel account={account} />
                {/* The right edge lines up with the current row's chevron. It
                    always keeps room for the remove button, which takes the
                    status's place on hover. */}
                <span className="ml-auto flex min-w-7 flex-none items-center justify-end">
                  {pending?.row === account.id ? (
                    <span className="grid h-4 w-4 place-items-center"><Spinner /></span>
                  ) : signedOut ? (
                    <span className="text-xs italic text-muted transition-opacity duration-150 group-hover/row:opacity-0 group-has-[:focus-visible]/row:opacity-0 [@media(hover:none)]:pr-8 [@media(hover:none)]:group-hover/row:opacity-100">
                      {messages.signedOut}
                    </span>
                  ) : null}
                </span>
              </Button>
              <Button
                disabled={busy}
                aria-label={format(messages.forgetAccount, { account: name(account) })}
                title={format(messages.forgetAccount, { account: name(account) })}
                onClick={() => forget(account, index)}
                className="group/x absolute inset-y-0 right-1.5 my-auto grid h-7 w-7 cursor-pointer place-items-center text-muted opacity-0 transition-[opacity,background-color,color,transform] duration-150 hover:bg-foreground/[0.08] hover:text-foreground active:scale-90 active:bg-foreground/[0.12] focus-visible:opacity-100 focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground group-hover/row:opacity-100 data-[disabled]:opacity-0 [@media(hover:none)]:opacity-100"
              >
                <CloseIcon />
              </Button>
            </li>
          );
        })}
        <li>
          <Button
            focusableWhenDisabled
            disabled={busy}
            className={rowClass("another")}
            onClick={() => onSignInHere({ email: null, method: null, password: false, sessionEnded: false })}
          >
            <span aria-hidden="true" className="grid h-7 w-7 flex-none place-items-center text-muted transition-colors group-hover:text-foreground">
              <PlusIcon />
            </span>
            <span className="text-sm">{messages.useAnotherAccount}</span>
          </Button>
        </li>
      </ul>
      <div className="mt-2">
        <FieldError id={errorId} text={error} />
      </div>
      <Announce text={pending && pending.row !== "another" ? format(messages.signingInAs, { account: pending.label }) : null} />
    </Page>
  );
}

const accountRowClass =
  "group flex w-full cursor-pointer items-center gap-3 px-3 py-2.5 text-left transition-colors hover:bg-foreground/[0.05] active:bg-foreground/[0.08] focus-visible:bg-foreground/[0.05] focus-visible:outline-none data-[disabled]:cursor-default data-[disabled]:hover:bg-transparent";

type AccountView = { email: string | null; displayName: string | null; profileImageUrl?: string | null };
type AccountRow = AccountView & { id: string };

function AccountAvatar({ account, dimmed = false }: { account: AccountView; dimmed?: boolean }) {
  const fade = dimmed ? "opacity-60 grayscale" : "";
  if (account.profileImageUrl?.startsWith("https://")) {
    // eslint-disable-next-line @next/next/no-img-element -- a remote avatar of any host; next/image needs each host configured.
    return <img src={account.profileImageUrl} alt="" referrerPolicy="no-referrer" className={`h-7 w-7 flex-none border border-border object-cover ${fade}`} />;
  }
  return (
    <span aria-hidden="true" className={`grid h-7 w-7 flex-none place-items-center bg-foreground font-mono text-[11px] font-medium text-background ${fade}`}>
      {accountInitials(account.displayName, account.email)}
    </span>
  );
}

function AccountLabel({ account }: { account: AccountView }) {
  const name = account.displayName?.trim();
  return (
    <span className="grid min-w-0">
      <span className="truncate text-sm font-medium"><bdi>{name || account.email}</bdi></span>
      {name && account.email && <span className="truncate text-xs text-muted"><bdi>{account.email}</bdi></span>}
    </span>
  );
}

/**
 * Adds the signed-in account to this browser's list (an external store, not
 * React state) and keeps its session, so a later switch away and back needs
 * no new sign-in. Its sign-in method is looked up afterwards so the redirect
 * never waits on it.
 */
function RememberThisAccount({ user }: { user: CurrentUser }) {
  const { id, primaryEmail: email, displayName, profileImageUrl, isRestricted } = user;
  useEffect(() => {
    // An account still finishing onboarding has no session worth keeping.
    if (!isRestricted) void saveCurrentSession();
  }, [id, isRestricted]);
  useEffect(() => {
    writeStored(ACCOUNT_HISTORY_KEY, JSON.stringify(rememberAccount(readHistory(), { id, email, displayName, profileImageUrl, hasPassword: user.hasPassword })));
    writePendingOAuth(null);
    let cancelled = false;
    user.listOAuthProviders().then((linked) => {
      if (cancelled) return;
      const signInMethod = rememberedMethodFor({ hasPassword: user.hasPassword, linked, preference: PROVIDER_PREFERENCE });
      writeStored(ACCOUNT_HISTORY_KEY, JSON.stringify(rememberAccount(readHistory(), { id, email, displayName, profileImageUrl, signInMethod, hasPassword: user.hasPassword })));
    }).catch(() => {
      // Without the method the account still lists; picking it opens the form.
    });
    return () => {
      cancelled = true;
    };
  }, [user, id, email, displayName, profileImageUrl]);
  return null;
}

/** Which linked provider to remember when an account has several. */
const PROVIDER_PREFERENCE = ["google", "github", "apple", "microsoft", "gitlab", "discord"];

// MARK: Sign-in form

type EmailStep = { kind: "enter" } | { kind: "code"; email: string; nonce: string };

function SignInForm({ mode, messages, returnTo, prefillEmail = null, lastUsedMethod = null, startWithPassword = false, notice = null, onBack }: {
  mode: Mode;
  messages: CmuxSignInMessages;
  returnTo: string | null;
  prefillEmail?: string | null;
  /** The picked account's method, shown as "last used" instead of this browser's. */
  lastUsedMethod?: string | null;
  /** Open the email methods on email and password (a remembered password account). */
  startWithPassword?: boolean;
  /** Why the form opened, shown under the heading. */
  notice?: string | null;
  onBack?: () => void;
}) {
  const app = useHexclaveApp();
  const project = app.useProject();
  const config = project.config;
  const inIframe = useInIframe();

  const passkeyAvailable = mode === "sign-in" && config.passkeyEnabled === true;
  const hasOAuth = config.oauthProviders.length > 0;
  const hasEmail = config.credentialEnabled || config.magicLinkEnabled;

  if (mode === "sign-up" && !config.signUpEnabled) {
    return (
      <Page>
        <Heading title={messages.signUpTitle} />
        <p className="text-sm text-muted">{messages.signUpDisabled}</p>
        <p className="mt-6 text-sm text-muted">
          {messages.haveAccount}{" "}
          <a className={linkClass} href={handlerHref("sign-in", returnTo)}>{messages.signInLink}</a>
        </p>
      </Page>
    );
  }
  if (!hasOAuth && !passkeyAvailable && !hasEmail) {
    return (
      <Page>
        <Heading title={mode === "sign-in" ? messages.signInTitle : messages.signUpTitle} />
        <p className="text-sm text-muted">{messages.noMethods}</p>
      </Page>
    );
  }

  return (
    <Page>
      <FormHeader mode={mode} messages={messages} notice={notice} onBack={onBack} />
      <div className="grid gap-2">
        {config.oauthProviders.map(({ id }) => (
          <OAuthProviderButton
            key={id}
            provider={id}
            disabled={inIframe}
            messages={messages}
            lastUsedOverride={onBack ? lastUsedMethod : undefined}
            loginHint={oauthLoginHint(id, prefillEmail)}
          />
        ))}
        {passkeyAvailable && <PasskeyButton messages={messages} />}
        {inIframe && hasOAuth && <p className="text-xs text-muted">{messages.embeddedDisabled}</p>}
        {hasEmail && (hasOAuth || passkeyAvailable) && <OrDivider text={messages.or} />}
        {hasEmail && (
          <EmailMethods
            mode={mode}
            messages={messages}
            returnTo={returnTo}
            magicLinkEnabled={config.magicLinkEnabled}
            credentialEnabled={config.credentialEnabled}
            prefillEmail={prefillEmail}
            startWithPassword={startWithPassword}
          />
        )}
      </div>
      <FormFooter mode={mode} messages={messages} returnTo={returnTo} signUpEnabled={config.signUpEnabled} showModeSwitch={!onBack} />
    </Page>
  );
}

function FormHeader({ mode, messages, notice, onBack }: {
  mode: Mode;
  messages: CmuxSignInMessages;
  notice: string | null;
  onBack?: () => void;
}) {
  const signIn = mode === "sign-in";
  return (
    <>
      {onBack && (
        <Button
          onClick={onBack}
          className="group mb-5 -ml-1 inline-flex cursor-pointer items-center gap-1 px-1 py-0.5 text-sm text-muted transition-colors hover:text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
        >
          <BackIcon />
          {messages.back}
        </Button>
      )}
      <Heading
        title={signIn ? messages.signInTitle : messages.signUpTitle}
        subtitle={signIn ? messages.signInSubtitle : messages.signUpSubtitle}
      />
      {notice && (
        <p className="-mt-3 mb-5 border border-border px-3 py-2 text-sm text-muted">
          {notice}
        </p>
      )}
    </>
  );
}

function OrDivider({ text }: { text: string }) {
  return (
    <div className="my-2 flex items-center gap-2.5 font-mono text-[11px] text-muted">
      <span aria-hidden="true" className="h-px flex-1 bg-border" />
      {text}
      <span aria-hidden="true" className="h-px flex-1 bg-border" />
    </div>
  );
}

/** The sign-in / sign-up switch (not on a form opened from the chooser) and the legal line. */
function FormFooter({ mode, messages, returnTo, signUpEnabled, showModeSwitch }: {
  mode: Mode;
  messages: CmuxSignInMessages;
  returnTo: string | null;
  signUpEnabled: boolean;
  showModeSwitch: boolean;
}) {
  const toSignUp = mode === "sign-in";
  return (
    <div className="mt-6 grid gap-3 text-sm text-muted">
      {showModeSwitch && (!toSignUp || signUpEnabled) && (
        <p>
          {toSignUp ? messages.noAccount : messages.haveAccount}{" "}
          <a className={linkClass} href={handlerHref(toSignUp ? "sign-up" : "sign-in", returnTo)}>
            {toSignUp ? messages.signUpLink : messages.signInLink}
          </a>
        </p>
      )}
      <LegalLine messages={messages} />
    </div>
  );
}

function LegalLine({ messages }: { messages: CmuxSignInMessages }) {
  const [before, rest = ""] = messages.legal.split("{terms}");
  const [middle, after = ""] = rest.split("{privacy}");
  return (
    <p className="text-xs leading-5">
      {before}
      <Link className={linkClass} href="/terms-of-service">{messages.termsOfService}</Link>
      {middle}
      <Link className={linkClass} href="/privacy-policy">{messages.privacyPolicy}</Link>
      {after}
    </p>
  );
}

// MARK: Browser-only reads

// Read through useSyncExternalStore so the server render (no window) and the
// first browser render agree, with no effect or extra state.
const subscribeNever = () => () => {};

function useInIframe(): boolean {
  return useSyncExternalStore(subscribeNever, () => window.self !== window.top, () => false);
}

function readLastUsedProvider(): string | null {
  try {
    return window.localStorage.getItem(LAST_USED_KEY);
  } catch {
    return null;
  }
}

function useLastUsedProvider(): string | null {
  return useSyncExternalStore(subscribeNever, readLastUsedProvider, () => null);
}

// Same-tab writes do not fire "storage", so writes announce themselves too.
const STORAGE_EVENT = "cmux-sign-in-storage";

function subscribeStorage(onChange: () => void) {
  window.addEventListener("storage", onChange);
  window.addEventListener(STORAGE_EVENT, onChange);
  return () => {
    window.removeEventListener("storage", onChange);
    window.removeEventListener(STORAGE_EVENT, onChange);
  };
}

function readStored(key: string): string | null {
  try {
    return window.localStorage.getItem(key);
  } catch {
    return null;
  }
}

function writeStored(key: string, value: string | null) {
  try {
    if (value === null) window.localStorage.removeItem(key);
    else window.localStorage.setItem(key, value);
  } catch {
    // The list and the hint are conveniences; sign-in works without them.
  }
  window.dispatchEvent(new Event(STORAGE_EVENT));
}

/**
 * The pending-provider marker lives in this tab only: an OAuth trip returns
 * to the tab that started it, so another tab's sign-in can't be mistaken for
 * this one.
 */
function readPendingOAuth(): string | null {
  try {
    return window.sessionStorage.getItem(PENDING_OAUTH_KEY);
  } catch {
    return null;
  }
}

function writePendingOAuth(value: string | null) {
  try {
    if (value === null) window.sessionStorage.removeItem(PENDING_OAUTH_KEY);
    else window.sessionStorage.setItem(PENDING_OAUTH_KEY, value);
  } catch {
    // A convenience only: without it a failed provider is simply tried again.
  }
}

function readHistory(): RememberedAccount[] {
  return parseAccountHistory(readStored(ACCOUNT_HISTORY_KEY));
}

function useAccountHistory(): RememberedAccount[] {
  const raw = useSyncExternalStore(subscribeStorage, () => readStored(ACCOUNT_HISTORY_KEY), () => null);
  return useMemo(() => parseAccountHistory(raw), [raw]);
}


// MARK: OAuth and passkey

const LAST_USED_KEY = "_HEXCLAVE.lastUsed";

const providerNames: Record<string, string> = {
  google: "Google",
  github: "GitHub",
  apple: "Apple",
  microsoft: "Microsoft",
  gitlab: "GitLab",
  discord: "Discord",
};

function OAuthProviderButton({ provider, disabled, messages, lastUsedOverride, loginHint = null }: {
  provider: string;
  disabled: boolean;
  messages: CmuxSignInMessages;
  /** When set (even to null), replaces this browser's "last used" hint. */
  lastUsedOverride?: string | null;
  /** The account the form was opened for: the provider goes straight to it. */
  loginHint?: string | null;
}) {
  const app = useHexclaveApp();
  const browserLastUsed = useLastUsedProvider();
  const lastUsed = lastUsedOverride === undefined ? browserLastUsed : lastUsedOverride;
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const errorId = useId();
  const name = providerNames[provider] ?? provider;

  return (
    <>
      <Button
        focusableWhenDisabled={busy}
        className={buttonClass}
        disabled={disabled || busy}
        aria-describedby={error ? errorId : undefined}
        onClick={() => {
          setBusy(true);
          setError(null);
          startOAuth(app, provider, loginHint).catch(() => {
            setBusy(false);
            setError(messages.errorGeneric);
          });
        }}
      >
        <ProviderIcon provider={provider} />
        <span>{format(messages.continueWithProvider, { provider: name })}</span>
        {busy ? <span className="ml-auto"><Spinner /></span> : lastUsed === provider && (
          <span className="ml-auto border border-border px-1.5 font-mono text-[11px] leading-[18px] text-muted">{messages.lastUsed}</span>
        )}
      </Button>
      <FieldError id={errorId} text={error} />
    </>
  );
}

/**
 * Leaves for a provider. Its callback returns here with the continue marker.
 * With a login hint the provider opens on that account, not its chooser.
 */
function startOAuth(app: ReturnType<typeof useHexclaveApp>, provider: string, loginHint: string | null = null): Promise<void> {
  try {
    window.localStorage.setItem(LAST_USED_KEY, provider);
  } catch {
    // The "last used" hint is a convenience only.
  }
  // The provider returns to this exact URL; the marker makes that landing
  // continue instead of asking which account to use.
  window.history.replaceState(window.history.state, "", withContinueMarker(window.location.href));
  return app.signInWithOAuth(provider, loginHint ? { loginHint } : undefined).catch((caught: unknown) => {
    console.error("[cmux sign-in] OAuth start failed", caught);
    window.history.replaceState(window.history.state, "", withoutContinueMarker(window.location.href));
    throw caught;
  });
}

function PasskeyButton({ messages }: { messages: CmuxSignInMessages }) {
  const app = useHexclaveApp();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const errorId = useId();
  return (
    <>
      <Button
        focusableWhenDisabled
        className={buttonClass}
        disabled={busy}
        aria-describedby={error ? errorId : undefined}
        onClick={async () => {
          setBusy(true);
          setError(null);
          try {
            const result = await app.signInWithPasskey();
            if (result.status === "error") {
              setError(KnownErrors.InvalidTotpCode.isInstance(result.error) ? messages.errorInvalidTotp : messages.errorPasskey);
            }
          } catch (caught) {
            console.error("[cmux sign-in] passkey sign-in failed", caught);
            setError(messages.errorPasskey);
          } finally {
            setBusy(false);
          }
        }}
      >
        <KeyIcon />
        <span>{messages.signInWithPasskey}</span>
        {busy && <span className="ml-auto"><Spinner /></span>}
      </Button>
      <FieldError id={errorId} text={error} />
    </>
  );
}

// MARK: Email: code and password

function EmailMethods({ mode, messages, returnTo, magicLinkEnabled, credentialEnabled, prefillEmail, startWithPassword }: {
  mode: Mode;
  messages: CmuxSignInMessages;
  returnTo: string | null;
  magicLinkEnabled: boolean;
  credentialEnabled: boolean;
  prefillEmail: string | null;
  startWithPassword: boolean;
}) {
  // The emailed code is the default, as on the hosted screen; a remembered
  // password account opens on its password.
  const [method, setMethod] = useState<"code" | "password">(
    (startWithPassword && credentialEnabled) || !magicLinkEnabled ? "password" : "code",
  );
  const [email, setEmail] = useState(prefillEmail ?? "");
  const canSwitch = magicLinkEnabled && credentialEnabled;

  return (
    <div className="grid gap-2">
      {method === "code" ? (
        <EmailCode messages={messages} email={email} onEmailChange={setEmail} />
      ) : mode === "sign-in" ? (
        <PasswordSignIn messages={messages} returnTo={returnTo} email={email} onEmailChange={setEmail} focusPassword={prefillEmail !== null} />
      ) : (
        <PasswordSignUp messages={messages} email={email} onEmailChange={setEmail} />
      )}
      {canSwitch && (
        <Button
          className={`justify-self-start text-sm ${linkClass}`}
          onClick={() => setMethod(method === "code" ? "password" : "code")}
        >
          {method === "code" ? messages.usePasswordInstead : messages.useEmailCodeInstead}
        </Button>
      )}
    </div>
  );
}

function isValidEmail(value: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value.trim());
}

function EmailField({ messages, value, onChange, error, disabled, autoFocus, forPassword = false }: {
  messages: CmuxSignInMessages;
  value: string;
  onChange: (value: string) => void;
  error: string | null;
  disabled?: boolean;
  autoFocus?: boolean;
  /** Paired with a password: password managers file the login under it. */
  forPassword?: boolean;
}) {
  return (
    <TextField
      label={messages.emailLabel}
      error={error}
      disabled={disabled}
      name={forPassword ? "username" : "email"}
      type="email"
      autoComplete={forPassword ? "username" : "email"}
      placeholder={messages.emailPlaceholder}
      value={value}
      autoFocus={autoFocus}
      onChange={onChange}
    />
  );
}

/**
 * One labelled input on Base UI's Field: the label, the invalid state and the
 * error message are tied to the input for assistive tech. The label is
 * visually hidden; the placeholder says the same thing on screen.
 */
function TextField({ label, error, disabled, className = inputClass, onChange, ...input }: {
  label: string;
  error: string | null;
  disabled?: boolean;
  className?: string;
  onChange: (value: string) => void;
} & Pick<ComponentProps<"input">, "name" | "type" | "autoComplete" | "placeholder" | "value" | "autoFocus" | "inputMode" | "autoCapitalize" | "spellCheck" | "maxLength">) {
  return (
    <Field.Root invalid={error !== null} disabled={disabled} className="grid gap-2">
      <Field.Label className="sr-only">{label}</Field.Label>
      <Field.Control {...input} className={className} onValueChange={(next) => onChange(next)} />
      <Field.Error match={error !== null} role="alert" className="text-xs text-red-600 dark:text-red-400">
        {error}
      </Field.Error>
    </Field.Root>
  );
}

function EmailCode({ messages, email, onEmailChange }: {
  messages: CmuxSignInMessages;
  email: string;
  onEmailChange: (value: string) => void;
}) {
  const app = useHexclaveApp();
  const [step, setStep] = useState<EmailStep>({ kind: "enter" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function send(event?: FormEvent) {
    event?.preventDefault();
    if (!isValidEmail(email)) {
      setError(messages.errorInvalidEmail);
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const result = await app.sendMagicLinkEmail(email.trim());
      if (result.status === "error") {
        console.error("[cmux sign-in] sending the code was refused", result.error);
        setError(messages.errorGeneric);
        return;
      }
      setStep({ kind: "code", email: email.trim(), nonce: result.data.nonce });
    } catch (caught) {
      setError(KnownErrors.SignUpNotEnabled.isInstance(caught) ? messages.errorSignUpNotAllowed : messages.errorGeneric);
      if (!KnownErrors.SignUpNotEnabled.isInstance(caught)) console.error("[cmux sign-in] sending the code failed", caught);
    } finally {
      setBusy(false);
    }
  }

  if (step.kind === "code") {
    return (
      <CodeEntry
        messages={messages}
        email={step.email}
        nonce={step.nonce}
        onBack={() => setStep({ kind: "enter" })}
        onResend={() => send()}
      />
    );
  }
  return (
    <form className="grid gap-2" noValidate aria-busy={busy} onSubmit={send}>
      <EmailField messages={messages} value={email} onChange={onEmailChange} error={error} disabled={busy} />
      <Button type="submit" focusableWhenDisabled className={primaryButtonClass} disabled={busy}>
        <BusyLabel busy={busy}>{messages.continueWithEmail}</BusyLabel>
      </Button>
    </form>
  );
}

function CodeEntry({ messages, email, nonce, onBack, onResend }: {
  messages: CmuxSignInMessages;
  email: string;
  nonce: string;
  onBack: () => void;
  onResend: () => void;
}) {
  const app = useHexclaveApp();
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(value: string) {
    setBusy(true);
    setError(null);
    try {
      // Success redirects; only failures return here.
      const result = await app.signInWithMagicLink(value + nonce);
      if (result.status === "error") {
        console.error("[cmux sign-in] code sign-in was refused", result.error);
        setError(KnownErrors.InvalidTotpCode.isInstance(result.error) ? messages.errorInvalidTotp : messages.errorInvalidCode);
      }
    } catch (caught) {
      console.error("[cmux sign-in] code sign-in failed", caught);
      setError(messages.errorGeneric);
    } finally {
      setBusy(false);
      setCode("");
    }
  }

  const [lead, tail = ""] = messages.checkEmailBody.split("{email}");
  return (
    <div className="grid gap-2">
      <p className="text-sm font-medium">{messages.checkEmailTitle}</p>
      <p className="text-sm text-muted">{lead}<bdi className="text-foreground">{email}</bdi>{tail}</p>
      <TextField
        label={messages.codeLabel}
        error={error}
        disabled={busy}
        className={`${inputClass} h-12 text-center font-mono text-lg uppercase tracking-[0.5em]`}
        inputMode="text"
        autoComplete="one-time-code"
        autoCapitalize="characters"
        spellCheck={false}
        maxLength={6}
        autoFocus
        value={code}
        onChange={(value) => {
          // Codes are six letters or digits; submit as soon as they are in.
          const next = value.replace(/[^a-zA-Z0-9]/g, "").toUpperCase().slice(0, 6);
          setCode(next);
          if (next.length > 0 && next.length < 6) setError(null);
          if (next.length === 6 && !busy) void submit(next);
        }}
      />
      <Announce text={busy ? messages.redirecting : null} />
      <p className="text-sm text-muted">
        <Button className={linkClass} onClick={onBack}>{messages.back}</Button>
        <span aria-hidden="true">{" · "}</span>
        <Button className={linkClass} onClick={onResend}>{messages.resendCode}</Button>
      </p>
    </div>
  );
}

function PasswordSignIn({ messages, returnTo, email, onEmailChange, focusPassword = false }: {
  messages: CmuxSignInMessages;
  returnTo: string | null;
  email: string;
  onEmailChange: (value: string) => void;
  /** The email is already filled in (a remembered account): start on the password. */
  focusPassword?: boolean;
}) {
  const app = useHexclaveApp();
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [emailError, setEmailError] = useState<string | null>(null);
  const [passwordError, setPasswordError] = useState<string | null>(null);

  async function submit(event: FormEvent) {
    event.preventDefault();
    const badEmail = isValidEmail(email) ? null : messages.errorInvalidEmail;
    const badPassword = password ? null : messages.errorPasswordRequired;
    setEmailError(badEmail);
    setPasswordError(badPassword);
    if (badEmail || badPassword) return;
    setBusy(true);
    try {
      // Success redirects, including the two-factor step when it applies.
      const result = await app.signInWithCredential({ email: email.trim(), password });
      if (result.status === "error") {
        console.error("[cmux sign-in] password sign-in was refused", result.error);
        setEmailError(KnownErrors.InvalidTotpCode.isInstance(result.error) ? messages.errorInvalidTotp : messages.errorWrongPassword);
      }
    } catch (caught) {
      console.error("[cmux sign-in] password sign-in failed", caught);
      setEmailError(messages.errorGeneric);
    } finally {
      setBusy(false);
    }
  }

  return (
    <form className="grid gap-2" noValidate aria-busy={busy} onSubmit={submit}>
      <EmailField messages={messages} value={email} onChange={onEmailChange} error={emailError} disabled={busy} forPassword />
      <TextField
        label={messages.passwordLabel}
        error={passwordError}
        disabled={busy}
        name="password"
        type="password"
        autoComplete="current-password"
        placeholder={messages.passwordLabel}
        value={password}
        autoFocus={focusPassword}
        onChange={setPassword}
      />
      <Button type="submit" focusableWhenDisabled className={primaryButtonClass} disabled={busy}>
        <BusyLabel busy={busy}>{messages.signInButton}</BusyLabel>
      </Button>
      <a className={`justify-self-start text-sm ${linkClass}`} href={handlerHref("forgot-password", returnTo)}>
        {messages.forgotPassword}
      </a>
    </form>
  );
}

function PasswordSignUp({ messages, email, onEmailChange }: {
  messages: CmuxSignInMessages;
  email: string;
  onEmailChange: (value: string) => void;
}) {
  const app = useHexclaveApp();
  const [password, setPassword] = useState("");
  const [repeat, setRepeat] = useState("");
  const [busy, setBusy] = useState(false);
  const [emailError, setEmailError] = useState<string | null>(null);
  const [passwordError, setPasswordError] = useState<string | null>(null);
  const [repeatError, setRepeatError] = useState<string | null>(null);

  function passwordProblem(value: string): string | null {
    if (!value) return messages.errorPasswordRequired;
    const problem = getPasswordError(value);
    if (!problem) return null;
    // The two errors spell their detail field differently (`min_length`, `maxLength`).
    if (KnownErrors.PasswordTooShort.isInstance(problem)) {
      return format(messages.errorPasswordTooShort, { min: numberDetail(problem.details, "min_length") ?? 8 });
    }
    if (KnownErrors.PasswordTooLong.isInstance(problem)) {
      return format(messages.errorPasswordTooLong, { max: numberDetail(problem.details, "maxLength") ?? 256 });
    }
    return messages.errorGeneric;
  }

  async function submit(event: FormEvent) {
    event.preventDefault();
    const badEmail = isValidEmail(email) ? null : messages.errorInvalidEmail;
    const badPassword = passwordProblem(password);
    const badRepeat = !badPassword && repeat !== password ? messages.errorPasswordsDontMatch : null;
    setEmailError(badEmail);
    setPasswordError(badPassword);
    setRepeatError(badRepeat);
    if (badEmail || badPassword || badRepeat) return;
    setBusy(true);
    try {
      const result = await app.signUpWithCredential({ email: email.trim(), password, noRedirect: true });
      const pending = signUpPendingHref(new URL(window.location.href));
      if (result.status === "ok") {
        // The new account must verify its email before it can sign in, so
        // the session the sign-up created is dropped on the way out.
        await app.signOut({ redirectUrl: pending });
        return;
      }
      if (result.error.errorCode === "USER_EMAIL_ALREADY_EXISTS") {
        // Same page as a successful sign-up: never reveal that the account exists.
        window.location.assign(pending);
        return;
      }
      setEmailError(messages.errorGeneric);
    } catch (caught) {
      console.error("[cmux sign-in] password sign-up failed", caught);
      setEmailError(messages.errorGeneric);
    } finally {
      setBusy(false);
    }
  }

  return (
    <form className="grid gap-2" noValidate aria-busy={busy} onSubmit={submit}>
      <EmailField messages={messages} value={email} onChange={onEmailChange} error={emailError} disabled={busy} forPassword />
      <TextField
        label={messages.passwordLabel}
        error={passwordError}
        disabled={busy}
        name="new-password"
        type="password"
        autoComplete="new-password"
        placeholder={messages.passwordLabel}
        value={password}
        onChange={(value) => {
          setPassword(value);
          setPasswordError(null);
          setRepeatError(null);
        }}
      />
      <TextField
        label={messages.repeatPasswordLabel}
        error={repeatError}
        disabled={busy}
        name="confirm-password"
        type="password"
        autoComplete="new-password"
        placeholder={messages.repeatPasswordLabel}
        value={repeat}
        onChange={(value) => {
          setRepeat(value);
          setRepeatError(null);
        }}
      />
      <Button type="submit" focusableWhenDisabled className={primaryButtonClass} disabled={busy}>
        <BusyLabel busy={busy}>{messages.createAccountButton}</BusyLabel>
      </Button>
    </form>
  );
}

function numberDetail(details: unknown, key: string): number | null {
  if (typeof details !== "object" || details === null || Array.isArray(details)) return null;
  const value = (details as Record<string, unknown>)[key];
  return typeof value === "number" ? value : null;
}

// MARK: Icons

function ProviderIcon({ provider }: { provider: string }) {
  if (provider === "google") {
    return (
      <svg aria-hidden="true" viewBox="0 0 24 24" className="h-4 w-4 flex-none">
        <path fill="#4285F4" d="M23.5 12.3c0-.8-.1-1.6-.2-2.3H12v4.4h6.5a5.6 5.6 0 0 1-2.4 3.6v3h3.9c2.2-2.1 3.5-5.1 3.5-8.7z" />
        <path fill="#34A853" d="M12 24c3.2 0 6-1.1 8-2.9l-3.9-3c-1.1.7-2.5 1.2-4.1 1.2-3.1 0-5.8-2.1-6.7-5H1.3v3.1A12 12 0 0 0 12 24z" />
        <path fill="#FBBC05" d="M5.3 14.3a7.2 7.2 0 0 1 0-4.6V6.6H1.3a12 12 0 0 0 0 10.8l4-3.1z" />
        <path fill="#EA4335" d="M12 4.8c1.8 0 3.3.6 4.6 1.8l3.4-3.4A12 12 0 0 0 1.3 6.6l4 3.1c.9-2.9 3.6-4.9 6.7-4.9z" />
      </svg>
    );
  }
  if (provider === "github") {
    return (
      <svg aria-hidden="true" viewBox="0 0 24 24" className="h-4 w-4 flex-none">
        <path fill="currentColor" d="M12 .5a11.5 11.5 0 0 0-3.6 22.4c.6.1.8-.3.8-.6v-2c-3.2.7-3.9-1.5-3.9-1.5-.5-1.3-1.3-1.7-1.3-1.7-1-.7.1-.7.1-.7 1.2.1 1.8 1.2 1.8 1.2 1 1.8 2.8 1.3 3.5 1 .1-.8.4-1.3.7-1.6-2.6-.3-5.3-1.3-5.3-5.7 0-1.3.5-2.3 1.2-3.1-.1-.3-.5-1.5.1-3.1 0 0 1-.3 3.2 1.2a11 11 0 0 1 5.8 0c2.2-1.5 3.2-1.2 3.2-1.2.6 1.6.2 2.8.1 3.1.7.8 1.2 1.8 1.2 3.1 0 4.4-2.7 5.4-5.3 5.7.4.4.8 1.1.8 2.2v3.3c0 .3.2.7.8.6A11.5 11.5 0 0 0 12 .5z" />
      </svg>
    );
  }
  if (provider === "apple") {
    return (
      <svg aria-hidden="true" viewBox="0 0 24 24" className="h-4 w-4 flex-none">
        <path fill="currentColor" d="M16.4 12.6c0-2.6 2.1-3.8 2.2-3.9a4.8 4.8 0 0 0-3.8-2c-1.6-.2-3.1.9-3.9.9-.8 0-2-.9-3.4-.9a5 5 0 0 0-4.2 2.6c-1.8 3.1-.5 7.7 1.3 10.2.9 1.2 1.9 2.6 3.2 2.6 1.3-.1 1.8-.8 3.3-.8s2 .8 3.4.8c1.4 0 2.3-1.3 3.1-2.5a11 11 0 0 0 1.4-2.9 4.5 4.5 0 0 1-2.6-4.1zM13.9 5.1A4.4 4.4 0 0 0 14.9 2a4.5 4.5 0 0 0-2.9 1.5 4.2 4.2 0 0 0-1.1 3 3.7 3.7 0 0 0 3-1.4z" />
      </svg>
    );
  }
  return <span aria-hidden="true" className="h-4 w-4 flex-none border border-border" />;
}

function ChevronIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.5">
      <path d="m6 3.5 4.5 4.5L6 12.5" />
    </svg>
  );
}

function BackIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 16 16" className="h-3.5 w-3.5 transition-transform duration-150 group-hover:-translate-x-0.5" fill="none" stroke="currentColor" strokeWidth="1.5">
      <path d="M13 8H3.5M7.5 4 3.5 8l4 4" />
    </svg>
  );
}

function PlusIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.5">
      <path d="M8 3v10M3 8h10" />
    </svg>
  );
}

function CloseIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="1.5">
      <path d="m4 4 8 8M12 4l-8 8" />
    </svg>
  );
}

function KeyIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" className="h-4 w-4 flex-none" fill="none" stroke="currentColor" strokeWidth="1.6">
      <path d="M14.5 9.5a4.5 4.5 0 1 1-9 0 4.5 4.5 0 0 1 9 0zM13.5 12.5 21 20m-3.5-3.5L19 15m-4 1.5 1.5-1.5" />
    </svg>
  );
}

// MARK: OAuth callback

/**
 * cmux's OAuth return page. The public callback does the code exchange and,
 * on success, redirects onward exactly as the hosted page does. A refused
 * exchange lands on cmux's recovery page instead of printing raw service
 * codes; only a cmux code is passed, never the service's text.
 */
export function CmuxOAuthCallback({ messages }: { messages: CmuxSignInMessages }) {
  const app = useHexclaveApp();
  const started = useRef(false);
  useEffect(() => {
    if (started.current) return;
    started.current = true;
    app.callOAuthCallback()
      .then(async (handled) => {
        // Not an OAuth return at all: back to a plain sign-in, as before.
        if (!handled) await app.redirectToSignIn({ noRedirectBack: true });
      })
      .catch((caught: unknown) => {
        // A remembered account sent straight to its provider failed: open the
        // form for it next time instead of repeating this.
        const failedAccount = parsePendingOAuth(readPendingOAuth());
        if (failedAccount) {
          writeStored(ACCOUNT_HISTORY_KEY, JSON.stringify(demoteRememberedMethod(readHistory(), failedAccount)));
          writePendingOAuth(null);
        }
        const code = KnownErrors.ContactChannelAlreadyUsedForAuthBySomeoneElse.isInstance(caught) ? "email-unverified" : null;
        if (!code) console.error("[cmux sign-in] OAuth callback failed", caught);
        window.location.replace(code ? `/handler/auth-error?code=${code}` : "/handler/auth-error");
      });
  }, [app]);

  return (
    <Page>
      <div aria-busy="true" className="flex items-center justify-center gap-2.5 text-center text-sm text-muted">
        <Spinner />
        {messages.redirecting}
      </div>
    </Page>
  );
}
