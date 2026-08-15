import { MagicLinkSignIn, StackHandler } from "@stackframe/stack";
import { headers } from "next/headers";
import { notFound } from "next/navigation";
import { connection } from "next/server";
import { Suspense } from "react";
import { stackServerApp } from "../../lib/stack";

// Stack Auth owns this catch-all route and reads its URL before it can render.
// Keep authentication reliable instead of withholding it behind an empty
// instant-navigation boundary.
export const instant = false;

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

  if (
    coderouterHost(requestHeaders.get("host")) &&
    stack.length === 1 &&
    stack[0] === "sign-in"
  ) {
    // The shared cmux Google connector requests Drive, Gmail, and Calendar
    // scopes for optional integrations. Those scopes are inappropriate for
    // coderouter authentication, so coderouter deliberately offers
    // passwordless email only.
    return (
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
    );
  }

  const stackHandler = (
    <StackHandler fullPage app={stackServerApp} params={props.params} />
  );

  // Stack's email-verification page calls useUser() while rendering its
  // client component. Next requires that CSR bailout to have a boundary on
  // this route, otherwise a real verification link returns HTTP 500.
  if (stack[0] === "email-verification") {
    return <Suspense fallback={null}>{stackHandler}</Suspense>;
  }

  return stackHandler;
}

function coderouterHost(host: string | null): boolean {
  const hostname = host?.split(":", 1)[0]?.toLowerCase();
  return hostname === "coderouter.dev" ||
    hostname?.endsWith(".coderouter.dev") === true;
}
