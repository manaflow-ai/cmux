import { StackHandler } from "@stackframe/stack";
import { notFound } from "next/navigation";
import { connection } from "next/server";
import { Suspense } from "react";
import { stackServerApp } from "../../lib/stack";

// Stack Auth owns this catch-all route and reads its URL before it can render.
// Keep authentication reliable instead of withholding it behind an empty
// instant-navigation boundary.
export const instant = false;

/**
 * The auth screens cmux has not rebuilt yet: MFA, team invitations, CLI
 * confirmation, and account settings. Sign-in, sign-up, the one-time code
 * form, password reset, email verification, and both callbacks are now
 * cmux-owned routes whose static segments take precedence over this catch-all.
 */
export default async function StackHandlerPage(
  props: { params: Promise<{ stack: string[] }> },
) {
  // Stack consumes one-time query parameters from the actual request URL.
  // Keep everything below this boundary out of the prerender cache.
  await connection();
  if (!stackServerApp) notFound();

  // Stack handler pages use client hooks for session and query state. Keep the
  // complete handler behind one boundary so every current and future auth path
  // can opt into client rendering without a missing-boundary error.
  return (
    <Suspense fallback={<StackHandlerLoading />}>
      <StackHandler fullPage app={stackServerApp} params={props.params} />
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
