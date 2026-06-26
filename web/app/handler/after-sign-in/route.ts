import { cookies } from "next/headers";
import { stackServerApp } from "../../lib/stack";
import { env } from "../../env";
import { makeAfterSignInHandler } from "./handler";

export const dynamic = "force-dynamic";

export const GET = makeAfterSignInHandler({
  projectId: env.NEXT_PUBLIC_STACK_PROJECT_ID,
  stackServerApp,
  getCookieStore: cookies,
});
