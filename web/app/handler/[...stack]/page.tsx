import { MagicLinkSignIn, StackHandler } from "@stackframe/stack";
import { headers } from "next/headers";
import { notFound, redirect } from "next/navigation";
import { connection } from "next/server";
import { Suspense } from "react";
import { stackServerApp } from "../../lib/stack";
import { CliAuthConfirmation, type CliAuthIdentityMessages } from "../cli-auth-confirmation";
import { preferredLocaleFromAcceptLanguage } from "../../../i18n/accept-language";
import { loadMessages } from "../../../i18n/messages";

// Stack Auth owns this catch-all route and reads its URL before it can render.
// Keep authentication reliable instead of withholding it behind an empty
// instant-navigation boundary.
export const instant = false;

export default async function StackHandlerPage(
  props: {
    params: Promise<{ stack: string[] }>;
    searchParams: Promise<Record<string, string | string[] | undefined>>;
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

  if (stack.length === 1 && stack[0] === "cli-auth-confirm") {
    const user = await stackServerApp.getUser({ or: "return-null" });
    if (!user || user.isAnonymous) {
      const searchParams = await props.searchParams;
      redirect(cliAuthSignInHref(firstSearchParam(searchParams.login_code)));
    }
  }

  const isCoderouterSignIn =
    coderouterHost(requestHeaders.get("host")) &&
    stack.length === 1 &&
    stack[0] === "sign-in";

  const handlerContent = stack.length === 1 && stack[0] === "cli-auth-confirm" ? (
    <CliAuthConfirmation
      fullPage
      identityMessages={(await loadMessages(preferredLocaleFromAcceptLanguage(
        requestHeaders.get("accept-language") ?? "",
      ))).cliAuthIdentity as CliAuthIdentityMessages}
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
  ) : (
    <StackHandler fullPage app={stackServerApp} params={props.params} />
  );

  // Stack handler pages use client hooks for session and query state. Keep the
  // complete handler, including custom host variants, behind one boundary so
  // every current and future auth path can opt into client rendering without
  // a missing-boundary error.
  return (
    <Suspense fallback={<StackHandlerLoading />}>
      {handlerContent}
    </Suspense>
  );
}

function StackHandlerLoading() {
  return (
    <main
      aria-busy="true"
      className="flex min-h-screen items-center justify-center"
    >
      <div
        aria-hidden="true"
        className="h-5 w-5 animate-spin rounded-full border-2 border-current border-t-transparent"
      />
    </main>
  );
}

function coderouterHost(host: string | null): boolean {
  const hostname = host?.split(":", 1)[0]?.toLowerCase();
  return hostname === "coderouter.dev" ||
    hostname?.endsWith(".coderouter.dev") === true;
}

function cliAuthSignInHref(loginCode: string | null): string {
  const confirmation = new URL("/handler/cli-auth-confirm", "https://cmux.com");
  if (loginCode) confirmation.searchParams.set("login_code", loginCode);

  const signIn = new URL("/handler/sign-in", "https://cmux.com");
  signIn.searchParams.set(
    "after_auth_return_to",
    `${confirmation.pathname}${confirmation.search}`,
  );
  return `${signIn.pathname}${signIn.search}`;
}

function firstSearchParam(value: string | string[] | undefined): string | null {
  return Array.isArray(value) ? value[0] ?? null : value ?? null;
}
