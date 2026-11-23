"use client";

import { Button } from "@base-ui-components/react/button";
import { Field } from "@base-ui-components/react/field";
import { Tabs } from "@base-ui-components/react/tabs";
import { useHexclaveApp, useUser, type CurrentUser } from "@hexclave/next";
import { KnownErrors } from "@hexclave/shared";
import { getPasswordError } from "@hexclave/shared/dist/helpers/password";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { createContext, use, useEffect, useEffectEvent, useId, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore, type ComponentProps, type FormEvent, type ReactNode } from "react";
import { forgetSession, saveCurrentSession, signedInAccounts, switchSession, tokenSignIn } from "./account-sessions-client";
import {
  ACCOUNT_HISTORY_KEY,
  PENDING_OAUTH_KEY,
  accountInitials,
  authErrorHref,
  demoteRememberedMethod,
  emailCodeRefusal,
  forgetAccount,
  handlerHref,
  isReturningFromOAuth,
  oauthLoginHint,
  oauthReturnTo,
  otherAccounts,
  parseAccountHistory,
  parsePendingOAuth,
  rememberAccount,
  rememberedMethodFor,
  rememberedSignInProvider,
  serializePendingOAuth,
  signInEntry,
  signInIsForApp,
  signUpPendingHref,
  signUpRefusal,
  withRefusalCode,
  type EmailCodeRefusal,
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
  orContinueWith: string;
  emailLabel: string;
  emailPlaceholder: string;
  continueWithEmail: string;
  emailCodeTab: string;
  emailPasswordTab: string;
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
  errorEmailUnverified: string;
  useEmailPasswordInstead: string;
  errorPasskey: string;
  errorGeneric: string;
};

type Mode = "sign-in" | "sign-up";

/** `{name}` placeholders, the same shape the message catalogs use. */
function format(template: string, values: Record<string, string | number>): string {
  return template.replace(/\{(\w+)\}/g, (match, key: string) => (key in values ? String(values[key]) : match));
}

/** Whether this deployment offers Sign in with ChatGPT (cmux.com runs that flow, not Hexclave). */
const ChatGPTSignInContext = createContext(false);

export function CmuxSignIn({ mode, messages, chatgpt = false }: { mode: Mode; messages: CmuxSignInMessages; chatgpt?: boolean }) {
  return (
    <ChatGPTSignInContext value={chatgpt}>
      <CmuxSignInScreens mode={mode} messages={messages} />
    </ChatGPTSignInContext>
  );
}

function CmuxSignInScreens({ mode, messages }: { mode: Mode; messages: CmuxSignInMessages }) {
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
  const [openedSignedIn] = useState(() => user !== null);
  // Back from a provider can restore this page from the browser's cache just
  // as it was left: mid sign-in, a spinner waiting on a page that's gone. The
  // trip was abandoned, so its marker goes and the screens start over.
  const restores = useBackForwardRestores(() => {
    writePendingOAuth(null);
    setSwitching(false);
  });
  const remembered = otherAccounts(useAccountHistory(), user?.id ?? "");
  const entry = signInEntry({
    hasUser: user !== null,
    isRestricted: user?.isRestricted === true,
    prompt: params.get("prompt"),
    returningFromOAuth: isReturningFromOAuth(params),
    hasRememberedAccounts: mode === "sign-in" && remembered.length > 0,
    signedInHere: user !== null && !openedSignedIn,
    forApp: signInIsForApp(returnTo),
  });

  // Always in this slot (null when signed out), so the screen next to it
  // keeps its state when a switch signs the browser in.
  const remember = user ? <RememberThisAccount user={user} returningFromOAuth={isReturningFromOAuth(params)} /> : null;

  if (switching || (entry === "choose-account" && !inlineSignIn)) {
    return (
      <>
        {remember}
        <ChooseAccount
          key={restores}
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
        <AutomaticRedirect key={restores} mode={mode} onboarding={entry === "onboarding"} messages={messages} />
      </>
    );
  }
  // Signing in on top of the current session replaces it, so a switch never
  // needs a sign-out first.
  return (
    <>
      {remember}
      <SignInForm
        key={restores}
        mode={inlineSignIn ? "sign-in" : mode}
        messages={messages}
        returnTo={returnTo}
        {...inlineFormProps(inlineSignIn, messages, () => setInlineSignIn(null))}
      />
    </>
  );
}

/**
 * Counts restores from the back/forward cache, after running `onRestore`.
 * Keying the screens on it remounts them, so no button stays busy; what
 * this page holds (the form "use another account" opened) stays.
 */
function useBackForwardRestores(onRestore: () => void): number {
  const [restores, setRestores] = useState(0);
  const restored = useEffectEvent(onRestore);
  useEffect(() => {
    function onPageShow(event: PageTransitionEvent) {
      if (!event.persisted) return;
      restored();
      setRestores((count) => count + 1);
    }
    window.addEventListener("pageshow", onPageShow);
    return () => window.removeEventListener("pageshow", onPageShow);
  }, []);
  return restores;
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
  const contentRef = useCenteredOnce();
  return (
    <main className="flex min-h-screen items-center justify-center bg-background px-4 py-12 text-foreground">
      <div ref={contentRef} className="w-full max-w-[340px]">{children}</div>
    </main>
  );
}

/**
 * Centers the screen at the height it opened with, then holds it there: what
 * a screen adds later (the password field, an error, the code step) grows
 * downward instead of re-centering everything above it. A window resize
 * centers it again.
 */
function useCenteredOnce() {
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const content = ref.current;
    if (!content) return;
    function hold() {
      if (!content) return;
      content.style.height = "";
      content.style.height = `${content.offsetHeight}px`;
    }
    hold();
    window.addEventListener("resize", hold);
    return () => window.removeEventListener("resize", hold);
  }, []);
  return ref;
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
    startOAuth(app, provider, oauthLoginHint(provider, account.email)).then(
      () => {
        writePendingOAuth(null);
        setPending(null);
      },
      () => {
        writePendingOAuth(null);
        fail();
      },
    );
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
 * never waits on it; back from a provider, that provider is the method.
 */
function RememberThisAccount({ user, returningFromOAuth }: { user: CurrentUser; returningFromOAuth: boolean }) {
  const { id, primaryEmail: email, displayName, profileImageUrl, isRestricted } = user;
  useEffect(() => {
    // An account still finishing onboarding has no session worth keeping.
    if (!isRestricted) void saveCurrentSession();
  }, [id, isRestricted]);
  useEffect(() => {
    const usedProvider = returningFromOAuth ? readLastUsedProvider() : null;
    const startedAt = Date.now();
    writeStored(ACCOUNT_HISTORY_KEY, JSON.stringify(rememberAccount(readHistory(), { id, email, displayName, profileImageUrl, signInMethod: returningFromOAuth ? usedProvider : null, hasPassword: user.hasPassword }, startedAt)));
    writePendingOAuth(null);
    let cancelled = false;
    user.listOAuthProviders().then((linked) => {
      if (cancelled) return;
      // Another tab can finish this account while this lookup is pending. Do
      // not let this stale result overwrite its newer provider choice.
      const current = readHistory().find((entry) => entry.id === id);
      if (!current || current.lastSeenAt !== startedAt) return;
      const signInMethod = rememberedMethodFor({ linked, preference: PROVIDER_PREFERENCE, usedProvider });
      writeStored(ACCOUNT_HISTORY_KEY, JSON.stringify(rememberAccount(readHistory(), { id, email, displayName, profileImageUrl, signInMethod, hasPassword: user.hasPassword })));
    }).catch(() => {
      // Without the method the account still lists; picking it opens the form.
    });
    return () => {
      cancelled = true;
    };
  }, [user, id, email, displayName, profileImageUrl, returningFromOAuth]);
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
  const chatgpt = use(ChatGPTSignInContext);
  const hasOAuth = offersProviders(config.oauthProviders.length, chatgpt);
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
        <ProviderButtons
          providers={config.oauthProviders.map(({ id }) => id)}
          chatgpt={chatgpt}
          disabled={inIframe}
          messages={messages}
          lastUsedOverride={chooserLastUsed(onBack, lastUsedMethod)}
          prefillEmail={prefillEmail}
        />
        {passkeyAvailable && <PasskeyButton messages={messages} />}
        {inIframe && hasOAuth && <p className="text-xs text-muted">{messages.embeddedDisabled}</p>}
        {hasEmail && (hasOAuth || passkeyAvailable) && <OrDivider text={messages.orContinueWith} />}
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

/** Whether the form shows any provider button. */
function offersProviders(hexclaveProviders: number, chatgpt: boolean): boolean {
  return hexclaveProviders > 0 || chatgpt;
}

/** The chooser's account method replaces this browser's "last used" only when the chooser opened the form. */
function chooserLastUsed(onBack: (() => void) | undefined, lastUsedMethod: string | null): string | null | undefined {
  return onBack ? lastUsedMethod : undefined;
}

/** One button per Hexclave provider, then ChatGPT when this deployment offers it. */
function ProviderButtons({ providers, chatgpt, disabled, messages, lastUsedOverride, prefillEmail }: {
  providers: string[];
  chatgpt: boolean;
  disabled: boolean;
  messages: CmuxSignInMessages;
  lastUsedOverride?: string | null;
  prefillEmail: string | null;
}) {
  return (
    <>
      {providers.map((id) => (
        <OAuthProviderButton
          key={id}
          provider={id}
          disabled={disabled}
          messages={messages}
          lastUsedOverride={lastUsedOverride}
          loginHint={oauthLoginHint(id, prefillEmail)}
        />
      ))}
      {chatgpt && <ChatGPTButton disabled={disabled} messages={messages} lastUsedOverride={lastUsedOverride} />}
    </>
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
    <div className="my-2 flex items-center gap-2.5 text-xs text-muted">
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
    // OAuth returns to the tab that started it; keep this marker tab-local so
    // another tab cannot overwrite the provider for this callback.
    return window.sessionStorage.getItem(LAST_USED_KEY);
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

/** The provider id ChatGPT uses for "last used" (matches CHATGPT_PROVIDER_ID on the server). */
const CHATGPT_PROVIDER = "chatgpt";

const providerNames: Record<string, string> = {
  google: "Google",
  github: "GitHub",
  apple: "Apple",
  microsoft: "Microsoft",
  gitlab: "GitLab",
  discord: "Discord",
  [CHATGPT_PROVIDER]: "ChatGPT",
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
          startOAuth(app, provider, loginHint).then(
            () => setBusy(false),
            () => {
              setBusy(false);
              setError(messages.errorGeneric);
            },
          );
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
 * Continue with ChatGPT. Hexclave has no OpenAI provider, so this leaves for
 * cmux.com's own OpenID Connect route, which comes back here with the same
 * continue marker as the other providers. `data-oai-siwc-button` lets OpenAI
 * verify the integration (developers.openai.com/siwc/website).
 */
function ChatGPTButton({ disabled, messages, lastUsedOverride }: {
  disabled: boolean;
  messages: CmuxSignInMessages;
  lastUsedOverride?: string | null;
}) {
  const browserLastUsed = useLastUsedProvider();
  const lastUsed = lastUsedOverride === undefined ? browserLastUsed : lastUsedOverride;
  const [busy, setBusy] = useState(false);
  return (
    <Button
      data-oai-siwc-button=""
      focusableWhenDisabled={busy}
      className={buttonClass}
      disabled={disabled || busy}
      onClick={() => {
        setBusy(true);
        try {
          window.localStorage.setItem(LAST_USED_KEY, CHATGPT_PROVIDER);
        } catch {
          // The "last used" hint is a convenience only.
        }
        const start = new URL("/handler/chatgpt/start", window.location.origin);
        start.searchParams.set("return_to", oauthReturnTo(window.location.href) ?? window.location.href);
        window.location.assign(start.toString());
      }}
    >
      <ProviderIcon provider={CHATGPT_PROVIDER} />
      <span>{format(messages.continueWithProvider, { provider: providerNames[CHATGPT_PROVIDER] ?? "ChatGPT" })}</span>
      {busy ? <span className="ml-auto"><Spinner /></span> : lastUsed === CHATGPT_PROVIDER && (
        <span className="ml-auto border border-border px-1.5 font-mono text-[11px] leading-[18px] text-muted">{messages.lastUsed}</span>
      )}
    </Button>
  );
}

/**
 * Leaves for a provider. Its callback returns here with the continue marker.
 * With a login hint the provider opens on that account, not its chooser.
 */
function startOAuth(app: ReturnType<typeof useHexclaveApp>, provider: string, loginHint: string | null = null): Promise<void> {
  try {
    // The callback reads this marker after returning to this tab. A shared
    // localStorage key lets another OAuth tab win the race.
    window.sessionStorage.setItem(LAST_USED_KEY, provider);
  } catch {
    // The "last used" hint is a convenience only.
  }
  // The provider returns to this page with a marker that makes the landing
  // continue instead of asking which account to use.
  const returnTo = oauthReturnTo(window.location.href);
  // Leaving never resolves, so resolving means the page stayed (a cancelled
  // bot check) and the caller resets.
  return app.signInWithOAuth(provider, { returnTo, loginHint: loginHint ?? undefined }).catch((caught: unknown) => {
    console.error("[cmux sign-in] OAuth start failed", caught);
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

/** The emailed code and email-and-password methods, as tabs when both are enabled; both share one email. */
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
  // The code was refused for an unverified account: its password form opens
  // on the password, the email kept. Once only: picking a tab by hand clears it.
  const [switchedToPassword, setSwitchedToPassword] = useState(false);
  /** Opens email and password after the code was refused; absent when that form can't sign in. */
  const openPassword = mode === "sign-in" && credentialEnabled
    ? () => {
      setSwitchedToPassword(true);
      setMethod("password");
    }
    : undefined;

  const form = (shown: "code" | "password") =>
    shown === "code" ? (
      <EmailCode messages={messages} email={email} onEmailChange={setEmail} onUsePassword={openPassword} />
    ) : mode === "sign-in" ? (
      <PasswordSignIn messages={messages} returnTo={returnTo} email={email} onEmailChange={setEmail} focusPassword={prefillEmail !== null || switchedToPassword} />
    ) : (
      <PasswordSignUp messages={messages} email={email} onEmailChange={setEmail} />
    );
  if (!(magicLinkEnabled && credentialEnabled)) return form(method);

  // Both enabled: the hosted screen's segmented control, the code first.
  return (
    <Tabs.Root
      value={method}
      onValueChange={(value) => {
        setSwitchedToPassword(false);
        setMethod(value === "password" ? "password" : "code");
      }}
      className="grid gap-2"
    >
      <Tabs.List className="grid grid-cols-2 border border-border p-0.5">
        <Tabs.Tab value="code" className={segmentClass}>{messages.emailCodeTab}</Tabs.Tab>
        <Tabs.Tab value="password" className={segmentClass}>{messages.emailPasswordTab}</Tabs.Tab>
      </Tabs.List>
      <Tabs.Panel value="code" className="grid gap-2">{method === "code" && form("code")}</Tabs.Panel>
      <Tabs.Panel value="password" className="grid gap-2">{method === "password" && form("password")}</Tabs.Panel>
    </Tabs.Root>
  );
}

const segmentClass =
  "h-[30px] cursor-pointer px-2 text-sm text-muted transition-colors hover:text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground data-[active]:bg-foreground/[0.08] data-[active]:text-foreground";

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

/** Sends a one-time code to the email, then takes the code; a refusal says why. */
function EmailCode({ messages, email, onEmailChange, onUsePassword }: {
  messages: CmuxSignInMessages;
  email: string;
  onEmailChange: (value: string) => void;
  /** Opens email and password with this email; absent when that form can't sign in. */
  onUsePassword?: () => void;
}) {
  const app = useHexclaveApp();
  const [step, setStep] = useState<EmailStep>({ kind: "enter" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [unverified, setUnverified] = useState(false);

  /** A refusal was for the address as it was; editing it clears the refusal. */
  function changeEmail(value: string) {
    setError(null);
    setUnverified(false);
    onEmailChange(value);
  }

  async function send(event?: FormEvent) {
    event?.preventDefault();
    if (!isValidEmail(email)) {
      setError(messages.errorInvalidEmail);
      return;
    }
    setBusy(true);
    setError(null);
    setUnverified(false);
    try {
      const result = await app.sendMagicLinkEmail(email.trim());
      if (result.status === "error") {
        console.error("[cmux sign-in] sending the code was refused", result.error);
        setError(withRefusalCode(messages.errorGeneric, result.error));
        return;
      }
      setStep({ kind: "code", email: email.trim(), nonce: result.data.nonce });
    } catch (caught) {
      const refusal = emailCodeRefusal(caught);
      setUnverified(refusal === "unverified-account");
      setError(refusal === "generic" ? withRefusalCode(messages.errorGeneric, caught) : emailCodeRefusalMessage[refusal](messages));
      if (refusal === "generic") console.error("[cmux sign-in] sending the code failed", caught);
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
      <EmailField messages={messages} value={email} onChange={changeEmail} error={error} disabled={busy} />
      <Button type="submit" focusableWhenDisabled className={primaryButtonClass} disabled={busy}>
        <BusyLabel busy={busy}>{messages.continueWithEmail}</BusyLabel>
      </Button>
      {unverified && onUsePassword && (
        <Button type="button" className={`justify-self-start text-sm ${linkClass}`} onClick={onUsePassword}>
          {messages.useEmailPasswordInstead}
        </Button>
      )}
    </form>
  );
}

const emailCodeRefusalMessage: Record<EmailCodeRefusal, (messages: CmuxSignInMessages) => string> = {
  "unverified-account": (messages) => messages.errorEmailUnverified,
  "sign-up-disabled": (messages) => messages.errorSignUpNotAllowed,
  generic: (messages) => messages.errorGeneric,
};

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
      setEmailError(withRefusalCode(messages.errorGeneric, caught));
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

  function showRefusal(error: unknown, pending: string) {
    const refusal = signUpRefusal(error);
    if (refusal === "account-exists") {
      // Same page as a successful sign-up: never reveal that the account exists.
      window.location.assign(pending);
      return;
    }
    if (refusal === "sign-up-disabled") {
      setEmailError(messages.errorSignUpNotAllowed);
      return;
    }
    console.error("[cmux sign-in] password sign-up failed", error);
    setEmailError(withRefusalCode(messages.errorGeneric, error));
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
      showRefusal(result.error, pending);
    } catch (caught) {
      showRefusal(caught, signUpPendingHref(new URL(window.location.href)));
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
  if (provider === CHATGPT_PROVIDER) {
    // OpenAI's approved ChatGPT mark (developers.openai.com/assets/siwc), in the
    // text color: black on the light page, white on the dark one.
    return (
      <svg aria-hidden="true" viewBox="0 0 21 21" className="h-4 w-4 flex-none">
        <path fill="currentColor" d="M11.8102 19.1625C11.2327 19.1625 10.6841 19.0528 10.1643 18.8334C9.64459 18.6139 9.18259 18.3078 8.77834 17.9151C8.33944 18.0653 7.88322 18.1404 7.40967 18.1404C6.63582 18.1404 5.91972 17.9498 5.26137 17.5686C4.60302 17.1875 4.07172 16.6677 3.66747 16.0094C3.27477 15.351 3.07842 14.6176 3.07842 13.8091C3.07842 13.4742 3.12462 13.1103 3.21702 12.7176C2.75502 12.2903 2.39697 11.7994 2.14287 11.245C1.88877 10.679 1.76172 10.09 1.76172 9.47785C1.76172 8.85415 1.89454 8.25355 2.16019 7.67605C2.42584 7.09855 2.79544 6.6019 3.26899 6.1861C3.75409 5.75875 4.31427 5.46422 4.94952 5.30252C5.07657 4.64417 5.34222 4.05512 5.74647 3.53537C6.16227 3.00407 6.67047 2.58827 7.27107 2.28797C7.87167 1.98767 8.51269 1.83752 9.19414 1.83752C9.77164 1.83752 10.3203 1.94725 10.84 2.1667C11.3598 2.38615 11.8218 2.69222 12.226 3.08492C12.6649 2.93477 13.1211 2.8597 13.5947 2.8597C14.3685 2.8597 15.0846 3.05027 15.743 3.43142C16.4013 3.81257 16.9269 4.33232 17.3196 4.99067C17.7238 5.64902 17.9259 6.38245 17.9259 7.19095C17.9259 7.5259 17.8797 7.88973 17.7873 8.28242C18.2493 8.70977 18.6074 9.20643 18.8615 9.77238C19.1156 10.3268 19.2426 10.91 19.2426 11.5222C19.2426 12.1459 19.1098 12.7465 18.8442 13.324C18.5785 13.9015 18.2031 14.4039 17.718 14.8313C17.2445 15.2471 16.6901 15.5358 16.0548 15.6975C15.9278 16.3559 15.6564 16.9449 15.2406 17.4647C14.8363 17.996 14.3339 18.4118 13.7333 18.7121C13.1327 19.0124 12.4917 19.1625 11.8102 19.1625ZM7.53094 16.9969C8.10844 16.9969 8.61087 16.8756 9.03822 16.6331L12.2953 14.762C12.4108 14.6811 12.4686 14.5714 12.4686 14.4328V12.9429L8.27592 15.351C8.02182 15.5012 7.76772 15.5012 7.51362 15.351L4.23919 13.4626C4.23919 13.4973 4.23342 13.5377 4.22187 13.5839C4.22187 13.6301 4.22187 13.6994 4.22187 13.7918C4.22187 14.3808 4.36047 14.9237 4.63767 15.4203C4.92642 15.9054 5.32489 16.2866 5.83309 16.5638C6.34129 16.8525 6.90724 16.9969 7.53094 16.9969ZM7.70419 14.1729C7.77349 14.2076 7.83702 14.2249 7.89477 14.2249C7.95252 14.2249 8.01027 14.2076 8.06802 14.1729L9.36739 13.4279L5.19207 11.0024C4.93797 10.8523 4.81092 10.6271 4.81092 10.3268V6.56725C4.23342 6.82135 3.77142 7.21405 3.42492 7.74535C3.07842 8.2651 2.90517 8.8426 2.90517 9.47785C2.90517 10.0438 3.04954 10.5866 3.33829 11.1064C3.62704 11.6261 4.00242 12.0189 4.46442 12.2845L7.70419 14.1729ZM11.8102 18.0191C12.4224 18.0191 12.9768 17.8805 13.4734 17.6033C13.9701 17.3261 14.3628 16.9449 14.6515 16.4598C14.9403 15.9747 15.0846 15.4319 15.0846 14.8313V11.0891C15.0846 10.9505 15.0269 10.8465 14.9114 10.7772L13.5947 10.0149V14.8486C13.5947 15.1489 13.4676 15.3741 13.2135 15.5243L9.93912 17.4127C10.5051 17.817 11.1288 18.0191 11.8102 18.0191ZM12.4686 11.6781V9.32192L10.5108 8.21312L8.53579 9.32192V11.6781L10.5108 12.7869L12.4686 11.6781ZM7.40967 6.15145C7.40967 5.85115 7.53672 5.62592 7.79082 5.47577L11.0652 3.58735C10.4993 3.1831 9.87559 2.98097 9.19414 2.98097C8.58199 2.98097 8.02759 3.11957 7.53094 3.39677C7.03429 3.67397 6.64159 4.05512 6.35284 4.54022C6.07564 5.02532 5.93704 5.56817 5.93704 6.16878V9.89365C5.93704 10.0323 5.99479 10.142 6.11029 10.2228L7.40967 10.9851V6.15145ZM16.2108 14.4328C16.7883 14.1787 17.2445 13.786 17.5794 13.2547C17.9259 12.7234 18.0992 12.1459 18.0992 11.5222C18.0992 10.9562 17.9548 10.4134 17.6661 9.89365C17.3773 9.3739 17.0019 8.9812 16.5399 8.71555L13.3002 6.84445C13.2309 6.79825 13.1673 6.78092 13.1096 6.79248C13.0518 6.79248 12.9941 6.8098 12.9363 6.84445L11.637 7.5721L15.8296 10.0149C15.9567 10.0842 16.0491 10.1766 16.1068 10.2921C16.1761 10.3961 16.2108 10.5231 16.2108 10.6733V14.4328ZM12.7284 5.6317C12.9825 5.47 13.2366 5.47 13.4907 5.6317L16.7825 7.55477C16.7825 7.47393 16.7825 7.36997 16.7825 7.24292C16.7825 6.68852 16.6439 6.163 16.3667 5.66635C16.101 5.15815 15.7141 4.7539 15.2059 4.4536C14.7093 4.1533 14.1318 4.00315 13.4734 4.00315C12.8959 4.00315 12.3935 4.12442 11.9661 4.36697L8.70904 6.23808C8.59354 6.31892 8.53579 6.42865 8.53579 6.56725V8.0572L12.7284 5.6317Z" />
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
        window.location.replace(authErrorHref(code, new URLSearchParams(window.location.search)));
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
