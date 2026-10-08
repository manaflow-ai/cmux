import { MagicLinkSignIn, StackHandler } from "@hexclave/next";
import { headers } from "next/headers";
import { notFound, redirect } from "next/navigation";
import { connection } from "next/server";
import { Suspense } from "react";
import { stackServerApp } from "../../lib/stack";
import { CliAuthConfirmation, type CliAuthIdentityMessages } from "../cli-auth-confirmation";
import { CmuxOAuthCallback, CmuxSignIn, type CmuxSignInMessages } from "../cmux-sign-in";
import { EndSavedSessions } from "../end-saved-sessions";
import { SignInSpinner } from "../sign-in-spinner";
import { hostedAuthErrorRedirect } from "../sign-in-entry";
import hosted from "../hosted.module.css";
import { preferredLocaleFromAcceptLanguage } from "../../../i18n/accept-language";
import { loadMessages } from "../../../i18n/messages";

// Stack Auth owns this catch-all route and reads its URL before it can render.
// Keep authentication reliable instead of withholding it behind an empty
// instant-navigation boundary.
export const instant = false;

export default async function StackHandlerPage(
  props: {
    params: Promise<{ stack: string[] }>;
    searchParams?: Promise<Record<string, string | string[] | undefined>>;
  },
) {
  // Stack consumes one-time query parameters from the actual request URL.
  // Keep everything below this boundary out of the prerender cache.
  await connection();
  if (!stackServerApp) notFound();
  const [{ stack }, requestHeaders] = await Promise.all([
    props.params,
    headers(),
  ]);

  // The handler page when the path is a single segment, as every page cmux
  // replaces is.
  const page = stack.length === 1 ? stack[0] : null;

  // A failed OAuth return goes to cmux's own recovery page rather than the
  // hosted one, which shows raw service codes.
  const errorTarget = page ? hostedAuthErrorRedirect(page, firstValues(await props.searchParams)) : null;
  if (errorTarget) redirect(errorTarget);

  const isCoderouterSignIn = coderouterHost(requestHeaders.get("host")) && page === "sign-in";
  const messages = () => loadMessages(preferredLocaleFromAcceptLanguage(requestHeaders.get("accept-language") ?? ""));

  const handlerContent = page === "cli-auth-confirm" ? (
    <CliAuthConfirmation
      fullPage
      identityMessages={(await messages()).cliAuthIdentity as CliAuthIdentityMessages}
    />
  ) : isCoderouterSignIn ? (
    // The shared cmux Google connector requests Drive, Gmail, and Calendar
    // scopes for optional integrations. Those scopes are inappropriate for
    // coderouter authentication, so coderouter deliberately offers
    // passwordless email only.
    <main className="flex min-h-screen items-center justify-center bg-[#faf9f6] px-6 text-[#25231f]">
      <section className="w-full max-w-sm border border-[#ded9cf] bg-white p-7 shadow-[4px_4px_0_#eee8dc]">
        <p className="mb-2 font-mono text-xs lowercase tracking-[0.16em] text-[#9a5b22]">
          coderouter
        </p>
        <h1 className="mb-2 text-xl font-medium">sign in</h1>
        <p className="mb-6 text-sm leading-6 text-[#6f6a61]">
          use your cmux account email. we’ll send a one-time code.
        </p>
        <MagicLinkSignIn />
      </section>
    </main>
  ) : page === "oauth-callback" ? (
    <CmuxOAuthCallback messages={(await messages()).cmuxSignIn as CmuxSignInMessages} />
  ) : page === "sign-in" || page === "sign-up" ? (
    // cmux's own sign-in and sign-up screens. Every callback, reset and
    // verification route below stays with the hosted handler.
    <CmuxSignIn mode={page} messages={(await messages()).cmuxSignIn as CmuxSignInMessages} />
  ) : (
    // The hosted pages spin a circular-arrow icon; the stylesheet redraws it
    // in place as cmux's spinner so every loading state matches.
    <div className={hosted.hosted}>
      <StackHandler fullPage app={stackServerApp} params={props.params} />
    </div>
  );

  // Stack handler pages use client hooks for session and query state. Keep the
  // complete handler, including custom host variants, behind one boundary so
  // every current and future auth path can opt into client rendering without
  // a missing-boundary error.
  return (
    <>
      {page === "sign-out" && <EndSavedSessions />}
      <Suspense fallback={<StackHandlerLoading />}>
        {handlerContent}
      </Suspense>
    </>
  );
}

/** The first value of each query parameter. */
function firstValues(searchParams: Record<string, string | string[] | undefined> | undefined): URLSearchParams {
  const query = new URLSearchParams();
  for (const [name, value] of Object.entries(searchParams ?? {})) {
    const first = Array.isArray(value) ? value[0] : value;
    if (first !== undefined) query.set(name, first);
  }
  return query;
}

function StackHandlerLoading() {
  return (
    <main
      aria-busy="true"
      className="flex min-h-screen items-center justify-center"
    >
      <SignInSpinner className="h-5 w-5" />
    </main>
  );
}

function coderouterHost(host: string | null): boolean {
  const hostname = host?.split(":", 1)[0]?.toLowerCase();
  return hostname === "coderouter.dev" ||
    hostname?.endsWith(".coderouter.dev") === true;
}
