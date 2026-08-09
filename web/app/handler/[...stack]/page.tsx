import { Suspense } from "react";
import { MagicLinkSignIn, StackHandler } from "@stackframe/stack";
import { headers } from "next/headers";
import { notFound } from "next/navigation";
import { stackServerApp } from "../../lib/stack";

export default async function StackHandlerPage(
  props: { params: Promise<{ stack: string[] }> },
) {
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

  return (
    <Suspense>
      <StackHandler fullPage app={stackServerApp} params={props.params} />
    </Suspense>
  );
}

function coderouterHost(host: string | null): boolean {
  const hostname = host?.split(":", 1)[0]?.toLowerCase();
  return hostname === "coderouter.dev" ||
    hostname?.endsWith(".coderouter.dev") === true;
}
