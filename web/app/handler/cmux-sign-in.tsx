"use client";

import { useHexclaveApp, useUser, type CurrentUser } from "@hexclave/next";
import { KnownErrors } from "@hexclave/shared";
import { getPasswordError } from "@hexclave/shared/dist/helpers/password";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { useEffect, useMemo, useRef, useState, useSyncExternalStore, type FormEvent, type ReactNode } from "react";
import {
  ACCOUNT_HISTORY_KEY,
  PENDING_OAUTH_KEY,
  accountInitials,
  demoteRememberedMethod,
  forgetAccount,
  handlerHref,
  isReturningFromOAuth,
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
  // or a remembered account that signs in by email).
  const [inlineSignIn, setInlineSignIn] = useState<{ email: string | null; method: string | null; password: boolean } | null>(null);
  const entry = signInEntry({
    hasUser: user !== null,
    isRestricted: user?.isRestricted === true,
    prompt: params.get("prompt"),
    returningFromOAuth: isReturningFromOAuth(params),
  });

  if (entry === "continue" || entry === "onboarding") {
    return (
      <>
        {user && <RememberThisAccount user={user} />}
        <AutomaticRedirect mode={mode} onboarding={entry === "onboarding"} messages={messages} />
      </>
    );
  }
  if (entry === "choose-account" && user && !inlineSignIn) {
    return (
      <>
        <RememberThisAccount user={user} />
        <ChooseAccount
          messages={messages}
          current={{ id: user.id, email: user.primaryEmail, displayName: user.displayName, profileImageUrl: user.profileImageUrl }}
          onContinue={() => app.redirectToAfterSignIn({ replace: true })}
          onSignInHere={(email, method, password) => setInlineSignIn({ email, method, password })}
        />
      </>
    );
  }
  // Signing in on top of the current session replaces it, so a switch never
  // needs a sign-out first.
  return (
    <SignInForm
      mode={inlineSignIn ? "sign-in" : mode}
      messages={messages}
      returnTo={returnTo}
      prefillEmail={inlineSignIn?.email ?? null}
      lastUsedMethod={inlineSignIn?.method ?? null}
      startWithPassword={inlineSignIn?.password ?? false}
      onBack={inlineSignIn ? () => setInlineSignIn(null) : undefined}
    />
  );
}

// MARK: Layout

function Page({ children }: { children: ReactNode }) {
  return (
    <main className="flex min-h-screen items-center justify-center bg-background px-4 py-12 text-foreground">
      <div className="w-full max-w-[340px]">{children}</div>
    </main>
  );
}

function Heading({ title, subtitle }: { title: string; subtitle?: string }) {
  return (
    <header className="mb-6">
      <h1 className="text-[22px] font-semibold tracking-[-0.02em]">{title}</h1>
      {subtitle && <p className="mt-1.5 text-sm text-muted">{subtitle}</p>}
    </header>
  );
}

const buttonClass =
  "flex h-[38px] w-full cursor-pointer items-center gap-2.5 border border-border bg-background px-3 text-left text-sm text-foreground transition-colors hover:bg-foreground/[0.05] active:bg-foreground/[0.08] focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground disabled:cursor-not-allowed disabled:opacity-50";
const primaryButtonClass =
  "flex h-[38px] w-full cursor-pointer items-center justify-center border border-foreground bg-foreground px-3 text-sm font-medium text-background transition-opacity hover:opacity-85 active:opacity-75 focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground disabled:cursor-not-allowed disabled:opacity-50";
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

function ChooseAccount({ messages, current, onContinue, onSignInHere }: {
  messages: CmuxSignInMessages;
  current: { id: string; email: string | null; displayName: string | null; profileImageUrl: string | null };
  onContinue: () => Promise<void>;
  onSignInHere: (email: string | null, method: string | null, password: boolean) => void;
}) {
  const app = useHexclaveApp();
  const enabledProviders = app.useProject().config.oauthProviders.map(({ id }) => id);
  // The row that was picked, so only it shows progress; the rest just wait.
  const [pending, setPending] = useState<string | null>(null);
  const busy = pending !== null;
  // Rows other than the picked one fade while it works.
  const rowClass = (row: string) => `${accountRowClass} transition-opacity ${busy && pending !== row ? "opacity-50" : ""}`;
  const [error, setError] = useState<string | null>(null);
  const others = otherAccounts(useAccountHistory(), current.id);

  // Like Gmail, nothing is signed out. An account that signs in only with a
  // provider goes straight there; any other opens the options here with its
  // email filled in.
  function pickRemembered(account: RememberedAccount) {
    const provider = rememberedSignInProvider(account, enabledProviders);
    if (!provider) {
      onSignInHere(account.email, null, account.hasPassword === true);
      return;
    }
    setPending(account.id);
    setError(null);
    writeStored(PENDING_OAUTH_KEY, serializePendingOAuth(account.id));
    startOAuth(app, provider).catch(() => {
      writeStored(PENDING_OAUTH_KEY, null);
      setPending(null);
      setError(messages.errorGeneric);
    });
  }

  return (
    <Page>
      <Heading title={messages.chooseAccountTitle} subtitle={messages.chooseAccountSubtitle} />
      <ul className="divide-y divide-border border border-border bg-background">
        <li>
          <button
            type="button"
            disabled={busy}
            className={rowClass("current")}
            onClick={() => {
              setPending("current");
              setError(null);
              onContinue().catch(() => {
                setPending(null);
                setError(messages.errorGeneric);
              });
            }}
          >
            <AccountAvatar account={current} />
            <AccountLabel account={current} />
            <span
              className={`ml-auto grid h-4 w-4 flex-none place-items-center text-muted transition-[color,transform] duration-150 ${
                pending === "current" ? "" : "group-hover:translate-x-0.5 group-hover:text-foreground"
              }`}
            >
              {pending === "current" ? <Spinner /> : <ChevronIcon />}
            </span>
          </button>
        </li>
        {others.map((account) => (
          <li key={account.id} className="group/row relative">
            <button type="button" disabled={busy} className={`${rowClass(account.id)} pr-11`} onClick={() => pickRemembered(account)}>
              <AccountAvatar account={account} />
              <AccountLabel account={account} />
              {pending === account.id && <span className="ml-auto grid h-4 w-4 flex-none place-items-center"><Spinner /></span>}
            </button>
            <button
              type="button"
              disabled={busy}
              aria-label={format(messages.forgetAccount, { account: account.email ?? account.displayName ?? "" })}
              title={format(messages.forgetAccount, { account: account.email ?? account.displayName ?? "" })}
              onClick={() => writeStored(ACCOUNT_HISTORY_KEY, JSON.stringify(forgetAccount(readHistory(), account.id)))}
              className="group/x absolute inset-y-0 right-1.5 my-auto grid h-7 w-7 cursor-pointer place-items-center text-muted opacity-0 transition-[opacity,background-color,color,transform] duration-150 hover:bg-foreground/[0.08] hover:text-foreground active:scale-90 active:bg-foreground/[0.12] focus-visible:opacity-100 focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground group-hover/row:opacity-100 disabled:opacity-0"
            >
              <CloseIcon />
            </button>
          </li>
        ))}
        <li>
          <button type="button" disabled={busy} className={rowClass("another")} onClick={() => onSignInHere(null, null, false)}>
            <span aria-hidden="true" className="grid h-7 w-7 flex-none place-items-center text-muted transition-colors group-hover:text-foreground">
              <PlusIcon />
            </span>
            <span className="text-sm">{messages.useAnotherAccount}</span>
          </button>
        </li>
      </ul>
      <div className="mt-2">
        <FieldError id="choose-account-error" text={error} />
      </div>
    </Page>
  );
}

const accountRowClass =
  "group flex w-full cursor-pointer items-center gap-3 px-3 py-2.5 text-left transition-colors hover:bg-foreground/[0.05] active:bg-foreground/[0.08] focus-visible:bg-foreground/[0.05] focus-visible:outline-none disabled:cursor-default disabled:hover:bg-transparent";

type AccountView = { email: string | null; displayName: string | null; profileImageUrl?: string | null };

function AccountAvatar({ account }: { account: AccountView }) {
  if (account.profileImageUrl?.startsWith("https://")) {
    // eslint-disable-next-line @next/next/no-img-element -- a remote avatar of any host; next/image needs each host configured.
    return <img src={account.profileImageUrl} alt="" referrerPolicy="no-referrer" className="h-7 w-7 flex-none border border-border object-cover" />;
  }
  return (
    <span aria-hidden="true" className="grid h-7 w-7 flex-none place-items-center bg-foreground font-mono text-[11px] font-medium text-background">
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
 * React state). Its sign-in method is looked up afterwards so the redirect
 * never waits on it.
 */
function RememberThisAccount({ user }: { user: CurrentUser }) {
  const { id, primaryEmail: email, displayName, profileImageUrl } = user;
  useEffect(() => {
    writeStored(ACCOUNT_HISTORY_KEY, JSON.stringify(rememberAccount(readHistory(), { id, email, displayName, profileImageUrl, hasPassword: user.hasPassword })));
    writeStored(PENDING_OAUTH_KEY, null);
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

function SignInForm({ mode, messages, returnTo, prefillEmail = null, lastUsedMethod = null, startWithPassword = false, onBack }: {
  mode: Mode;
  messages: CmuxSignInMessages;
  returnTo: string | null;
  prefillEmail?: string | null;
  /** The picked account's method, shown as "last used" instead of this browser's. */
  lastUsedMethod?: string | null;
  /** Open the email methods on email and password (a remembered password account). */
  startWithPassword?: boolean;
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
      {onBack && (
        <button
          type="button"
          onClick={onBack}
          className="group mb-5 -ml-1 inline-flex cursor-pointer items-center gap-1 px-1 py-0.5 text-sm text-muted transition-colors hover:text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
        >
          <BackIcon />
          {messages.back}
        </button>
      )}
      <Heading
        title={mode === "sign-in" ? messages.signInTitle : messages.signUpTitle}
        subtitle={mode === "sign-in" ? messages.signInSubtitle : messages.signUpSubtitle}
      />
      <div className="grid gap-2">
        {config.oauthProviders.map(({ id }) => (
          <OAuthProviderButton key={id} provider={id} disabled={inIframe} messages={messages} lastUsedOverride={onBack ? lastUsedMethod : undefined} />
        ))}
        {passkeyAvailable && <PasskeyButton messages={messages} />}
        {inIframe && hasOAuth && <p className="text-xs text-muted">{messages.embeddedDisabled}</p>}
        {hasEmail && (hasOAuth || passkeyAvailable) && (
          <div className="my-2 flex items-center gap-2.5 font-mono text-[11px] text-muted" role="separator">
            <span className="h-px flex-1 bg-border" />
            {messages.or}
            <span className="h-px flex-1 bg-border" />
          </div>
        )}
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
      <div className="mt-6 grid gap-3 text-sm text-muted">
        {onBack ? null : mode === "sign-in" ? (
          config.signUpEnabled && (
            <p>
              {messages.noAccount}{" "}
              <a className={linkClass} href={handlerHref("sign-up", returnTo)}>{messages.signUpLink}</a>
            </p>
          )
        ) : (
          <p>
            {messages.haveAccount}{" "}
            <a className={linkClass} href={handlerHref("sign-in", returnTo)}>{messages.signInLink}</a>
          </p>
        )}
        <LegalLine messages={messages} />
      </div>
    </Page>
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

function OAuthProviderButton({ provider, disabled, messages, lastUsedOverride }: {
  provider: string;
  disabled: boolean;
  messages: CmuxSignInMessages;
  /** When set (even to null), replaces this browser's "last used" hint. */
  lastUsedOverride?: string | null;
}) {
  const app = useHexclaveApp();
  const browserLastUsed = useLastUsedProvider();
  const lastUsed = lastUsedOverride === undefined ? browserLastUsed : lastUsedOverride;
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const name = providerNames[provider] ?? provider;

  return (
    <>
      <button
        type="button"
        className={buttonClass}
        disabled={disabled || busy}
        onClick={() => {
          setBusy(true);
          setError(null);
          startOAuth(app, provider).catch(() => {
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
      </button>
      <FieldError id={`oauth-${provider}-error`} text={error} />
    </>
  );
}

/** Leaves for a provider. Its callback returns here with the continue marker. */
function startOAuth(app: ReturnType<typeof useHexclaveApp>, provider: string): Promise<void> {
  try {
    window.localStorage.setItem(LAST_USED_KEY, provider);
  } catch {
    // The "last used" hint is a convenience only.
  }
  // The provider returns to this exact URL; the marker makes that landing
  // continue instead of asking which account to use.
  window.history.replaceState(window.history.state, "", withContinueMarker(window.location.href));
  return app.signInWithOAuth(provider).catch((caught: unknown) => {
    console.error("[cmux sign-in] OAuth start failed", caught);
    window.history.replaceState(window.history.state, "", withoutContinueMarker(window.location.href));
    throw caught;
  });
}

function PasskeyButton({ messages }: { messages: CmuxSignInMessages }) {
  const app = useHexclaveApp();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <>
      <button
        type="button"
        className={buttonClass}
        disabled={busy}
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
      </button>
      <FieldError id="passkey-error" text={error} />
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
        <PasswordSignIn messages={messages} returnTo={returnTo} email={email} onEmailChange={setEmail} />
      ) : (
        <PasswordSignUp messages={messages} email={email} onEmailChange={setEmail} />
      )}
      {canSwitch && (
        <button
          type="button"
          className={`justify-self-start text-sm ${linkClass}`}
          onClick={() => setMethod(method === "code" ? "password" : "code")}
        >
          {method === "code" ? messages.usePasswordInstead : messages.useEmailCodeInstead}
        </button>
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
    <>
      <label htmlFor="cmux-sign-in-email" className="sr-only">{messages.emailLabel}</label>
      <input
        id="cmux-sign-in-email"
        className={inputClass}
        name={forPassword ? "username" : "email"}
        type="email"
        autoComplete={forPassword ? "username" : "email"}
        placeholder={messages.emailPlaceholder}
        value={value}
        disabled={disabled}
        autoFocus={autoFocus}
        aria-invalid={error ? true : undefined}
        aria-describedby={error ? "cmux-sign-in-email-error" : undefined}
        onChange={(event) => onChange(event.target.value)}
      />
      <FieldError id="cmux-sign-in-email-error" text={error} />
    </>
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
    <form className="grid gap-2" noValidate onSubmit={send}>
      <EmailField messages={messages} value={email} onChange={onEmailChange} error={error} disabled={busy} />
      <button type="submit" className={primaryButtonClass} disabled={busy}>
        {busy ? <Spinner /> : messages.continueWithEmail}
      </button>
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
      <label htmlFor="cmux-sign-in-code" className="sr-only">{messages.codeLabel}</label>
      <input
        id="cmux-sign-in-code"
        className={`${inputClass} h-12 text-center font-mono text-lg uppercase tracking-[0.5em]`}
        inputMode="text"
        autoComplete="one-time-code"
        autoCapitalize="characters"
        spellCheck={false}
        maxLength={6}
        autoFocus
        value={code}
        disabled={busy}
        aria-invalid={error ? true : undefined}
        aria-describedby={error ? "cmux-sign-in-code-error" : undefined}
        onChange={(event) => {
          // Codes are six letters or digits; submit as soon as they are in.
          const next = event.target.value.replace(/[^a-zA-Z0-9]/g, "").toUpperCase().slice(0, 6);
          setCode(next);
          if (next.length > 0 && next.length < 6) setError(null);
          if (next.length === 6 && !busy) void submit(next);
        }}
      />
      <FieldError id="cmux-sign-in-code-error" text={error} />
      <p className="text-sm text-muted">
        <button type="button" className={linkClass} onClick={onBack}>{messages.back}</button>
        <span aria-hidden="true">{" · "}</span>
        <button type="button" className={linkClass} onClick={onResend}>{messages.resendCode}</button>
      </p>
    </div>
  );
}

function PasswordSignIn({ messages, returnTo, email, onEmailChange }: {
  messages: CmuxSignInMessages;
  returnTo: string | null;
  email: string;
  onEmailChange: (value: string) => void;
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
    <form className="grid gap-2" noValidate onSubmit={submit}>
      <EmailField messages={messages} value={email} onChange={onEmailChange} error={emailError} disabled={busy} forPassword />
      <label htmlFor="cmux-sign-in-password" className="sr-only">{messages.passwordLabel}</label>
      <input
        id="cmux-sign-in-password"
        name="password"
        className={inputClass}
        type="password"
        autoComplete="current-password"
        placeholder={messages.passwordLabel}
        value={password}
        disabled={busy}
        aria-invalid={passwordError ? true : undefined}
        aria-describedby={passwordError ? "cmux-sign-in-password-error" : undefined}
        onChange={(event) => setPassword(event.target.value)}
      />
      <FieldError id="cmux-sign-in-password-error" text={passwordError} />
      <button type="submit" className={primaryButtonClass} disabled={busy}>
        {busy ? <Spinner /> : messages.signInButton}
      </button>
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
    <form className="grid gap-2" noValidate onSubmit={submit}>
      <EmailField messages={messages} value={email} onChange={onEmailChange} error={emailError} disabled={busy} forPassword />
      <label htmlFor="cmux-sign-up-password" className="sr-only">{messages.passwordLabel}</label>
      <input
        id="cmux-sign-up-password"
        name="new-password"
        className={inputClass}
        type="password"
        autoComplete="new-password"
        placeholder={messages.passwordLabel}
        value={password}
        disabled={busy}
        aria-invalid={passwordError ? true : undefined}
        aria-describedby={passwordError ? "cmux-sign-up-password-error" : undefined}
        onChange={(event) => {
          setPassword(event.target.value);
          setPasswordError(null);
          setRepeatError(null);
        }}
      />
      <FieldError id="cmux-sign-up-password-error" text={passwordError} />
      <label htmlFor="cmux-sign-up-repeat" className="sr-only">{messages.repeatPasswordLabel}</label>
      <input
        id="cmux-sign-up-repeat"
        name="confirm-password"
        className={inputClass}
        type="password"
        autoComplete="new-password"
        placeholder={messages.repeatPasswordLabel}
        value={repeat}
        disabled={busy}
        aria-invalid={repeatError ? true : undefined}
        aria-describedby={repeatError ? "cmux-sign-up-repeat-error" : undefined}
        onChange={(event) => {
          setRepeat(event.target.value);
          setRepeatError(null);
        }}
      />
      <FieldError id="cmux-sign-up-repeat-error" text={repeatError} />
      <button type="submit" className={primaryButtonClass} disabled={busy}>
        {busy ? <Spinner /> : messages.createAccountButton}
      </button>
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
        const failedAccount = parsePendingOAuth(readStored(PENDING_OAUTH_KEY));
        if (failedAccount) {
          writeStored(ACCOUNT_HISTORY_KEY, JSON.stringify(demoteRememberedMethod(readHistory(), failedAccount)));
          writeStored(PENDING_OAUTH_KEY, null);
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
