import type { Metadata } from "next";
import { MagicLinkSignIn, StackHandler } from "@hexclave/next";
import { headers } from "next/headers";
import { notFound } from "next/navigation";
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

export async function generateMetadata(): Promise<Metadata> {
  const locale = preferredLocaleFromAcceptLanguage(
    (await headers()).get("accept-language") ?? "",
  );
  const messages = await loadMessages(locale) as {
    cloudPublicationAccess: { signIn: string };
  };
  return { title: messages.cloudPublicationAccess.signIn };
}

export default async function StackHandlerPage(
  props: { params: Promise<{ stack: string[] }> },
) {
  // Stack consumes one-time query parameters from the actual request URL.
  // Keep everything below this boundary out of the prerender cache.
  await connection();
  if (!stackServerApp) notFound();
  const [{ stack }, requestHeaders] = await Promise.all([
    props.params,
    headers(),
  ]);

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
        className="size-5 animate-spin rounded-full border-2 border-current border-t-transparent"
      />
    </main>
  );
}

function coderouterHost(host: string | null): boolean {
  const hostname = host?.split(":", 1)[0]?.toLowerCase();
  return hostname === "coderouter.dev" ||
    hostname?.endsWith(".coderouter.dev") === true;
}
